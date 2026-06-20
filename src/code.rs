//! Code generation and key derivation for the croc-style ticket handoff
//! (`zuko share` / `zuko claim`).
//!
//! ## Threat model
//!
//! The memorable code is a **one-time symmetric secret** for the handoff (the
//! croc model), never the host's identity. Both sides derive the same throwaway
//! Iroh [`SecretKey`] from the code, so the host serves it on a per-handoff
//! endpoint and the claimer dials the derived public key.
//!
//! The code has ~52 bits of entropy (4 × CVCV words) — far beyond reach for
//! **online** guessing during the minutes-long window before `zuko share` exits.
//! To also resist **offline** brute-force (in case the ephemeral `NodeId` is
//! observed via network capture, a DNS-resolver log, or journald), the key is
//! derived through memory-hard Argon2id rather than a single SHA-256. That
//! raises the per-guess cost by orders of magnitude at the price of a few
//! hundred milliseconds per derivation — cheap for a one-time handoff.
//!
//! ## Determinism
//!
//! Both sides run exactly [`derive_key`], so they converge on the same key
//! (and thus the same node id) without ever exchanging secret material. The
//! salt is a fixed, non-secret application constant: it isn't a defence
//! against an attacker who knows the algorithm (Kerckhoff's principle), only
//! a guard against precomputed tables built for *generic* Argon2 hashes being
//! reused against zuko specifically.

use anyhow::Result;
use argon2::{Algorithm, Argon2, Params, Version};
use iroh::SecretKey;

/// Letters used to build pronounceable code words. Dropped: q/x/y (ambiguous
/// and rarely useful), and the CVCV shape structurally avoids the common
/// 4-letter offensive words (which are CVCC/CCVC, not CVCV).
pub const CONSONANTS: &[u8] = b"bcdfghjklmnprstvwz";
pub const VOWELS: &[u8] = b"aeiou";

/// Number of CVCV words in a code. 4 words × ~13 bits = ~52 bits of entropy —
/// vast overkill for a one-time, minutes-long handoff, and short enough to
/// read aloud or type once.
pub const WORDS_IN_CODE: usize = 4;

/// Fixed, non-secret Argon2 salt. Tied to the protocol version so a future
/// `zuko/handoff/2` can rotate the KDF without colliding with handoff-1 keys.
const KDF_SALT: &[u8] = b"zuko-share-handoff-v1";

/// Argon2id parameters: ~19 MiB, 2 passes, 1 lane, 32-byte output. Matches the
/// OWASP minimum (April 2023) and the `argon2` crate's `Params::DEFAULT`. Built
/// once and reused so a `derive_key` call doesn't re-validate the params.
fn kdf() -> Argon2<'static> {
    // `new` only errors on impossible params; ours are the documented defaults.
    let params = Params::new(
        Params::DEFAULT.m_cost(),
        Params::DEFAULT.t_cost(),
        Params::DEFAULT.p_cost(),
        Some(32),
    )
    .expect("valid Argon2 params");
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
}

/// Normalise a typed code into its canonical letter sequence: lowercased, with
/// everything except a–z stripped. Separators are only for readability, so
/// `Tofa-Mive`, `tofa mive`, and `tofamive` all derive the same key.
pub fn normalize_code(code: &str) -> String {
    code.trim()
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_lowercase())
        .collect()
}

/// Derive the throwaway [`SecretKey`] deterministically from a code. Both sides
/// run exactly this, so they converge on the same key (and thus the same node
/// id) without ever exchanging secret material.
///
/// Memory-hard (Argon2id, ~19 MiB) so the ~52-bit code resists offline
/// brute-force even if the ephemeral `NodeId` is observed.
pub fn derive_key(code: &str) -> Result<SecretKey> {
    let material = normalize_code(code);
    let mut seed = [0u8; 32];
    // With our const-constructed Argon2 + a 32-byte output buffer the only
    // failure mode is an OS allocation error mid-hash; surface it rather than
    // panic so the caller can report a clean error.
    kdf()
        .hash_password_into(material.as_bytes(), KDF_SALT, &mut seed)
        .map_err(|e| anyhow::anyhow!("argon2 derivation failed: {e}"))?;
    Ok(SecretKey::from_bytes(&seed))
}

/// Generate a fresh, memorable code: `WORD-WORD-WORD-WORD`, each word a
/// pronounceable CVCV (e.g. `tofa-mive-laru-bedo`). Entropy comes from
/// [`SecretKey::generate`] (OsRng).
pub fn generate_code() -> String {
    let rand = SecretKey::generate().to_bytes();
    let mut idx = 0usize;
    let mut out = Vec::with_capacity(WORDS_IN_CODE * 5 - 1);
    for w in 0..WORDS_IN_CODE {
        if w > 0 {
            out.push(b'-');
        }
        out.push(pick(CONSONANTS, rand[idx]));
        idx += 1;
        out.push(pick(VOWELS, rand[idx]));
        idx += 1;
        out.push(pick(CONSONANTS, rand[idx]));
        idx += 1;
        out.push(pick(VOWELS, rand[idx]));
        idx += 1;
    }
    // idx == 4*WORDS_IN_CODE == 16 <= 32 bytes available; no wraparound.
    String::from_utf8(out).expect("code is ascii-only")
}

/// Heuristic: does this string look like a pairing code? Used by the
/// bare-`zuko <input>` shortcut to tell a one-time code apart from a saved
/// host name without making the user remember which subcommand to type.
///
/// A code normalises to exactly `WORDS_IN_CODE * 4` lowercase letters (16)
/// in strict CVCV-×-4 position: even indices in `CONSONANTS`, odd indices in
/// `VOWELS`. Real saved-host names effectively never match this — the
/// position-constrained alphabet makes a false positive astronomically
/// unlikely — so the disambiguation is safe in both directions.
pub fn looks_like_code(s: &str) -> bool {
    let normalized = normalize_code(s);
    if normalized.len() != WORDS_IN_CODE * 4 {
        return false;
    }
    let bytes = normalized.as_bytes();
    // The code is CVCV CVCV CVCV CVCV — so even byte positions are consonants
    // and odd positions are vowels. One pass, no allocations.
    bytes.iter().enumerate().all(|(i, b)| {
        if i % 2 == 0 {
            CONSONANTS.contains(b)
        } else {
            VOWELS.contains(b)
        }
    })
}

fn pick(alphabet: &[u8], byte: u8) -> u8 {
    alphabet[(byte as usize) % alphabet.len()]
}

/// Default handoff label: the system hostname if we can find it cheaply,
/// otherwise the boring-but-honest `"host"`.
pub fn default_label() -> String {
    if let Ok(h) = std::env::var("HOSTNAME") {
        let h = h.trim().to_string();
        if !h.is_empty() {
            return h;
        }
    }
    if let Ok(h) = std::fs::read_to_string("/etc/hostname") {
        let h = h.trim().to_string();
        if !h.is_empty() {
            return h;
        }
    }
    "host".to_string()
}

/// Collapse a user-supplied label to a single safe line: trim, turn whitespace
/// into `-` (so it round-trips through the newline-delimited payload and the
/// saved-hosts file). Falls back to `"host"` if empty or comment-like.
pub fn sanitize_label(s: &str) -> String {
    let cleaned: String = s
        .trim()
        .chars()
        .map(|c| if c.is_whitespace() { '-' } else { c })
        .collect();
    let cleaned = cleaned.trim_matches('-');
    if cleaned.is_empty() || cleaned.starts_with('#') {
        "host".to_string()
    } else {
        cleaned.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_is_separator_and_case_agnostic() {
        assert_eq!(normalize_code("tofa-mive-laru-bedo"), "tofamivelarubedo");
        assert_eq!(normalize_code("Tofa Mive LarU beDo"), "tofamivelarubedo");
        assert_eq!(
            normalize_code("  tofa_mive.laru+bedo  "),
            "tofamivelarubedo"
        );
        assert_eq!(normalize_code("TOFAMIVELARUBEDO"), "tofamivelarubedo");
        // Non-letters are dropped entirely.
        assert_eq!(normalize_code("t0f4-m!v3"), "tfmv");
    }

    #[test]
    fn derive_key_is_deterministic_and_input_sensitive() {
        // Same logical code -> same key, regardless of formatting.
        let a = derive_key("tofa-mive-laru-bedo").unwrap();
        let b = derive_key("TOFA MIVE LARU BEDO").unwrap();
        assert_eq!(a.to_bytes(), b.to_bytes());

        // Different code -> different key.
        let c = derive_key("tofa-mive-laru-beee").unwrap();
        assert_ne!(a.to_bytes(), c.to_bytes());

        // public() is a stable function of the key, so both sides also agree
        // on the node id they're dialing / serving as.
        assert_eq!(a.public(), b.public());
    }

    #[test]
    fn generate_code_is_well_formed() {
        // Argon2 makes each derive_key() ~tens of ms, so the structural check
        // (CVCV shape, lowercase, alphabet) runs on a modest sample and a
        // single derive_key round-trip is asserted once after the loop.
        for _ in 0..32 {
            let code = generate_code();
            let words: Vec<&str> = code.split('-').collect();
            assert_eq!(words.len(), WORDS_IN_CODE, "code: {code}");
            for w in &words {
                assert_eq!(w.len(), 4, "word must be CVCV: {w} in {code}");
                assert!(
                    w.bytes().all(|b| b.is_ascii_lowercase()),
                    "code must be lowercase: {w}"
                );
                let b = w.as_bytes();
                assert!(CONSONANTS.contains(&b[0]), "pos0 consonant: {w}");
                assert!(VOWELS.contains(&b[1]), "pos1 vowel: {w}");
                assert!(CONSONANTS.contains(&b[2]), "pos2 consonant: {w}");
                assert!(VOWELS.contains(&b[3]), "pos3 vowel: {w}");
            }
        }
        // A generated code must round-trip through derive_key without error.
        let _ = derive_key(&generate_code()).unwrap().public();
    }

    #[test]
    fn sanitize_label_collapses_whitespace_and_falls_back() {
        assert_eq!(sanitize_label("my server"), "my-server");
        assert_eq!(sanitize_label("  spaced  "), "spaced");
        assert_eq!(sanitize_label("a\tb\nc"), "a-b-c");
        assert_eq!(sanitize_label(""), "host");
        assert_eq!(sanitize_label("   "), "host");
        assert_eq!(sanitize_label("#comment"), "host");
        assert_eq!(sanitize_label("plain"), "plain");
    }

    #[test]
    fn looks_like_code_accepts_real_codes_in_any_format() {
        // The exact CVCV-×-4 shape, in every separator/case variant a user
        // might type.
        assert!(looks_like_code("tofa-mive-laru-bedo"));
        assert!(looks_like_code("TOFA MIVE LARU BEDO"));
        assert!(looks_like_code("tofamivelarubedo"));
        assert!(looks_like_code("  tofa_mive.laru+bedo  "));
    }

    #[test]
    fn looks_like_code_rejects_wrong_shape_or_alphabet() {
        // Wrong length: too short / too long / empty.
        assert!(!looks_like_code("tofa-mive-laru"));
        assert!(!looks_like_code("tofa-mive-laru-bedo-extra"));
        assert!(!looks_like_code(""));
        // Right length, wrong alphabet (q / y aren't in CONSONANTS, o is fine
        // but only at vowel positions).
        assert!(!looks_like_code("qqqq-qqqq-qqqq-qqqq"));
        // Right length, wrong CVCV pattern: consonant where a vowel belongs.
        assert!(!looks_like_code("tttt-tttt-tttt-tttt"));
        // Realistic saved-host names must not be misread as codes.
        assert!(!looks_like_code("home"));
        assert!(!looks_like_code("workstation"));
        assert!(!looks_like_code("my-server"));
        assert!(!looks_like_code("prod-1"));
    }

    #[test]
    fn generated_codes_are_detected_as_codes() {
        // Round-trip: a freshly-generated code must look like one. Catches
        // drift between `generate_code` and `looks_like_code` (e.g. if the
        // alphabet or word count ever changes in one but not the other).
        for _ in 0..64 {
            let code = generate_code();
            assert!(
                looks_like_code(&code),
                "generated code not detected: {code}"
            );
            assert!(
                looks_like_code(code.replace('-', " ").as_str()),
                "space form: {code}"
            );
        }
    }
}
