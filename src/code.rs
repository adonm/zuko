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
//! The code has ~28 bits of entropy (one adjective from ~37K × one noun from
//! ~6K, via the [petname](https://crates.io/crates/petname) large wordlists) —
//! far beyond reach for **online** guessing during the minutes-long window
//! before `zuko share` exits.
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
        .filter(char::is_ascii_lowercase)
        .collect()
}

/// Derive the throwaway 32-byte seed deterministically from a code. Both
/// sides run exactly this, so they converge on the same seed (and thus
/// the same node id) without ever exchanging secret material.
///
/// Memory-hard (Argon2id, ~19 MiB) so the code resists offline brute-force
/// even if the ephemeral `NodeId` is observed. The code itself carries ~28 bits
/// of entropy (one adjective from ~37K × one noun from ~6K), which is far
/// beyond reach for **online** guessing during the minutes-long share window,
/// and the Argon2id KDF raises each **offline** guess to ~200 ms.
///
/// Pure Argon2id so Dart and Rust can share stable fixture bytes.
pub fn derive_seed(code: &str) -> Result<[u8; 32]> {
    let material = normalize_code(code);
    let mut seed = [0u8; 32];
    // With our const-constructed Argon2 + a 32-byte output buffer the only
    // failure mode is an OS allocation error mid-hash; surface it rather than
    // panic so the caller can report a clean error.
    kdf()
        .hash_password_into(material.as_bytes(), KDF_SALT, &mut seed)
        .map_err(|e| anyhow::anyhow!("argon2 derivation failed: {e}"))?;
    Ok(seed)
}

/// Derive the throwaway [`SecretKey`] deterministically from a code by
/// running [`derive_seed`] and wrapping the bytes in iroh's `SecretKey`
/// for CLI convenience (the handoff code passes the key straight into
/// iroh's `Endpoint::builder`).
///
pub fn derive_key(code: &str) -> Result<SecretKey> {
    let seed = derive_seed(code)?;
    Ok(SecretKey::from_bytes(&seed))
}

/// Generate a fresh, memorable code: `<adjective>-<noun>` from petname's large
/// wordlists (~37K adjectives × ~6K nouns ≈ 28 bits of entropy). Example:
/// `iridescent-sardine`.
///
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
    select_default_label(
        std::env::var("HOSTNAME").ok(),
        std::fs::read_to_string("/etc/hostname").ok(),
        system_hostname(),
    )
}

fn select_default_label(
    environment: Option<String>,
    hostname_file: Option<String>,
    system: Option<String>,
) -> String {
    [environment, hostname_file, system]
        .into_iter()
        .flatten()
        .map(|hostname| hostname.trim().to_string())
        .find(|hostname| !hostname.is_empty())
        .unwrap_or_else(|| "host".to_string())
}

#[cfg(unix)]
fn system_hostname() -> Option<String> {
    let mut buffer = [0u8; 256];
    // SAFETY: `buffer` is writable for the supplied length. The untouched
    // final byte keeps the result terminated if the hostname reaches the limit.
    let result =
        unsafe { libc::gethostname(buffer.as_mut_ptr().cast::<libc::c_char>(), buffer.len() - 1) };
    if result != 0 {
        return None;
    }
    let end = buffer
        .iter()
        .position(|byte| *byte == 0)
        .unwrap_or(buffer.len());
    String::from_utf8(buffer[..end].to_vec()).ok()
}

#[cfg(not(unix))]
fn system_hostname() -> Option<String> {
    None
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

    #[test]
    fn default_label_falls_back_to_platform_hostname() {
        assert_eq!(
            select_default_label(None, None, Some("MacBook-Pro.local".to_string())),
            "MacBook-Pro.local"
        );
        assert_eq!(
            select_default_label(
                Some("  ".to_string()),
                Some("\n".to_string()),
                Some("MacBook-Pro.local\n".to_string()),
            ),
            "MacBook-Pro.local"
        );
        assert_eq!(select_default_label(None, None, None), "host");
    }

    // --- generate_code / looks_like_code tests ---
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

    #[test]
    fn looks_like_code_accepts_real_codes() {
        // Known adjective-noun combos from petname's large wordlists.
        assert!(looks_like_code("iridescent-hilton"));
        assert!(looks_like_code("languorous-davis"));
        assert!(looks_like_code("LANGUOROUS-DAVIS")); // case-insensitive
    }

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
