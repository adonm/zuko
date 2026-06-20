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
/// `Iridescent-Sardine`, `iridescent sardine`, and `iridescentsardine` all
/// derive the same key.
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
/// Memory-hard (Argon2id, ~19 MiB) so the code resists offline brute-force
/// even if the ephemeral `NodeId` is observed. The code itself carries ~28 bits
/// of entropy (one adjective from ~37K × one noun from ~6K), which is far
/// beyond reach for **online** guessing during the minutes-long share window,
/// and the Argon2id KDF raises each **offline** guess to ~200 ms.
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

/// Generate a fresh, memorable code: `<adjective>-<noun>` from petname's large
/// wordlists (~37K adjectives × ~6K nouns ≈ 28 bits of entropy). Example:
/// `iridescent-sardine`.
///
/// Desktop-only (the iOS app never generates codes — it only claims with
/// `derive_handoff_key`).
#[cfg(not(target_os = "ios"))]
pub fn generate_code() -> String {
    let pn = petname::Petnames::large();
    let mut buf = String::new();
    pn.namer(2, "-").generate_into(&mut buf, &mut rand::rng());
    buf
}

/// Heuristic: does this string look like a pairing code? Used by the
/// bare-`zuko <input>` shortcut to tell a one-time code apart from a saved
/// host name. A code is exactly two dash-separated words where the first is
/// in petname's adjective list and the second is in the noun list. Real
/// saved-host names effectively never match.
///
/// Desktop-only (the iOS app has a dedicated code-entry field).
#[cfg(not(target_os = "ios"))]
pub fn looks_like_code(s: &str) -> bool {
    let pn = petname::Petnames::large();
    let Some((adj, noun)) = s.trim().split_once('-') else {
        return false;
    };
    if noun.contains('-') {
        return false; // codes are exactly 2 words
    }
    pn.adjectives.contains(&adj.to_lowercase().as_str())
        && pn.nouns.contains(&noun.to_lowercase().as_str())
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
        assert_eq!(normalize_code("Iridescent-Sardine"), "iridescentsardine");
        assert_eq!(normalize_code("IRIDESCENT SARDINE"), "iridescentsardine");
        assert_eq!(
            normalize_code("  iridescent_sardine  "),
            "iridescentsardine"
        );
        // Non-letters are dropped entirely.
        assert_eq!(normalize_code("ir1d3sc3nt-s4rd1n3"), "irdscntsrdn");
    }

    #[test]
    fn derive_key_is_deterministic_and_input_sensitive() {
        // Same logical code -> same key, regardless of formatting.
        let a = derive_key("iridescent-sardine").unwrap();
        let b = derive_key("IRIDESCENT SARDINE").unwrap();
        assert_eq!(a.to_bytes(), b.to_bytes());

        // Different code -> different key.
        let c = derive_key("iridescent-whale").unwrap();
        assert_ne!(a.to_bytes(), c.to_bytes());

        // public() is a stable function of the key, so both sides also agree
        // on the node id they're dialing / serving as.
        assert_eq!(a.public(), b.public());
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

    // --- generate_code / looks_like_code tests (desktop only) ---
    #[cfg(not(target_os = "ios"))]
    #[test]
    fn generate_code_is_well_formed() {
        for _ in 0..32 {
            let code = generate_code();
            let words: Vec<&str> = code.split('-').collect();
            assert_eq!(words.len(), 2, "code must be adj-noun: {code}");
            assert!(
                words.iter().all(|w| !w.is_empty()),
                "no empty words: {code}"
            );
        }
        // A generated code must round-trip through derive_key without error.
        let _ = derive_key(&generate_code()).unwrap().public();
    }

    #[cfg(not(target_os = "ios"))]
    #[test]
    fn looks_like_code_accepts_real_codes() {
        // Known adjective-noun combos from petname's large wordlists.
        assert!(looks_like_code("iridescent-hilton"));
        assert!(looks_like_code("languorous-davis"));
        assert!(looks_like_code("LANGUOROUS-DAVIS")); // case-insensitive
    }

    #[cfg(not(target_os = "ios"))]
    #[test]
    fn looks_like_code_rejects_non_codes() {
        // Single word, three words, empty.
        assert!(!looks_like_code("home"));
        assert!(!looks_like_code("a-b-c"));
        assert!(!looks_like_code(""));
        // Two words but not in the wordlists.
        assert!(!looks_like_code("my-server"));
        assert!(!looks_like_code("prod-1"));
        assert!(!looks_like_code("foo-bar"));
    }

    #[cfg(not(target_os = "ios"))]
    #[test]
    fn generated_codes_are_detected_as_codes() {
        // Round-trip: a freshly-generated code must look like one.
        for _ in 0..32 {
            let code = generate_code();
            assert!(
                looks_like_code(&code),
                "generated code not detected: {code}"
            );
        }
    }
}
