//! `zuko share` / `zuko claim` — croc-style ticket handoff over Iroh.
//!
//! Pasting the long `endpointa…` ticket into a brand-new device is the one
//! rough edge left in the flow. These two commands remove it: the host operator
//! runs `zuko share`, reads off a short memorable code, and the new device runs
//! `zuko claim <code>` to fetch the real ticket over an end-to-end encrypted
//! Iroh connection — then saves it and connects, all in one command.
//!
//! ## How it stays safe
//!
//! The memorable code is a **one-time symmetric secret** for the handoff (the
//! croc model), never the host's identity. `zuko share` derives a *throwaway*
//! Iroh [`SecretKey`] from the code, binds a *second*, ephemeral endpoint with
//! that key, and uses it solely to deliver the host's real ticket. The real
//! host key (at `~/.config/zuko/key`) is unrelated and stays strong.
//!
//! Both sides derive the same key from the code, so:
//! - the host's throwaway endpoint proves ownership of the derived private key
//!   via the QUIC/TLS handshake;
//! - the claimer dials the throwaway node id (= the derived public key) and
//!   reads the ticket off a single unidirectional stream.
//!
//! Whoever has the code can claim — that's the point. The code has ~52 bits of
//! entropy, which is far beyond reach for online guessing during the
//! minutes-long window before `zuko share` exits after the first claim.
//!
//! ## Wire (ALPN `zuko/handoff/1`, one uni stream host -> client)
//!
//! The host opens a unidirectional stream and writes a tiny UTF-8 payload,
//! then closes the send side:
//!
//! ```text
//! <label>\n<ticket>
//! ```
//!
//! `label` has no newlines (sanitised), and tickets never contain whitespace,
//! so splitting on the first `\n` is unambiguous.

use anyhow::{Context, Result, bail};
use backon::{ConstantBuilder, Retryable};
use iroh::{Endpoint, SecretKey, endpoint::presets};
use sha2::{Digest, Sha256};
use std::time::Duration;
use tracing::{info, warn};

use crate::ShareArgs;

/// ALPN for the throwaway handoff endpoint (distinct from the terminal `zuko/1`).
const HANDOFF_ALPN: &[u8] = b"zuko/handoff/1";

/// Letters used to build pronounceable code words. Dropped: q/x/y (ambiguous
/// and rarely useful), and the CVCV shape structurally avoids the common
/// 4-letter offensive words (which are CVCC/CCVC, not CVCV).
const CONSONANTS: &[u8] = b"bcdfghjklmnprstvwz";
const VOWELS: &[u8] = b"aeiou";

/// Number of CVCV words in a code. 4 words × ~13 bits = ~52 bits of entropy —
/// vast overkill for a one-time, minutes-long handoff, and short enough to
/// read aloud or type once.
const WORDS_IN_CODE: usize = 4;

/// Cap a handoff payload so a misbehaving peer can't make us allocate forever.
const MAX_HANDOFF_PAYLOAD: usize = 8 * 1024;

// ────────────────────────── share (host side) ──────────────────────────────

/// Serve this host's ticket to the first claimer (or `--count` claimers) over
/// a throwaway, code-derived endpoint. Reads the live ticket from
/// `~/.config/zuko/current_ticket` unless `--ticket` is given.
pub async fn share(args: &ShareArgs) -> Result<()> {
    // `zuko share` is a foreground server; logs go to stderr so the code on
    // stdout stays clean for piping/copying.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "zuko=info,iroh=warn".into()),
        )
        .init();

    let ticket = match &args.ticket {
        Some(t) => t.trim().to_string(),
        None => read_current_ticket()?,
    };
    let label_owned = args.label.clone().unwrap_or_else(default_label);
    let label = sanitize_label(&label_owned);

    let code = generate_code();
    let secret = derive_key(&code);
    let node_id = secret.public();

    let endpoint = Endpoint::builder(presets::N0)
        .secret_key(secret)
        .alpns(vec![HANDOFF_ALPN.to_vec()])
        .bind()
        .await
        .context("bind handoff endpoint")?;
    endpoint.online().await;

    // The claimer dials this throwaway endpoint by node id alone, resolved
    // through the N0 DNS address-lookup. iroh publishes the endpoint's address
    // to that lookup shortly after coming online; give it a short head start so
    // a fast claimer doesn't lose a race with propagation.
    tokio::time::sleep(Duration::from_secs(2)).await;

    eprintln!();
    eprintln!("share this code (serves {n}, then exits):", n = args.count);
    println!("{code}");
    eprintln!("  on the other machine:");
    eprintln!("    zuko claim {code}");
    let timeout_hint = if args.timeout > 0 {
        format!(", or wait {}s", args.timeout)
    } else {
        String::new()
    };
    eprintln!("  (waiting — ctrl-c to cancel{timeout_hint})");
    eprintln!();
    info!(%node_id, "serving handoff on alpn {:?}", String::from_utf8_lossy(HANDOFF_ALPN));

    let max = args.count.max(1);
    let mut claims = 0usize;
    loop {
        let incoming = match accept_with_timeout(&endpoint, args.timeout).await? {
            AcceptOutcome::Incoming(i) => i,
            AcceptOutcome::Closed => break,
            AcceptOutcome::TimedOut => {
                eprintln!("share: timed out after {}s", args.timeout);
                break;
            }
        };
        match serve_handoff(*incoming, &label, &ticket).await {
            Ok(()) => {
                claims += 1;
                eprintln!("claim {claims}/{max} served");
                if claims >= max {
                    break;
                }
            }
            Err(e) => {
                // One bad peer shouldn't kill a multi-claim share; keep waiting.
                warn!("handoff to peer failed: {e:#}");
            }
        }
    }
    eprintln!("share: done");
    Ok(())
}

enum AcceptOutcome {
    // `iroh::endpoint::Incoming` is ~392 bytes; box it so the two tiny
    // sentinel variants don't balloon the enum's footprint.
    Incoming(Box<iroh::endpoint::Incoming>),
    Closed,
    TimedOut,
}

/// Wrap `endpoint.accept()` in an optional overall timeout. `timeout_secs == 0`
/// means wait forever (until the endpoint closes or Ctrl-C).
async fn accept_with_timeout(
    endpoint: &Endpoint,
    timeout_secs: u64,
) -> Result<AcceptOutcome> {
    if timeout_secs == 0 {
        return Ok(match endpoint.accept().await {
            Some(i) => AcceptOutcome::Incoming(Box::new(i)),
            None => AcceptOutcome::Closed,
        });
    }
    match tokio::time::timeout(Duration::from_secs(timeout_secs), endpoint.accept()).await {
        Ok(Some(i)) => Ok(AcceptOutcome::Incoming(Box::new(i))),
        Ok(None) => Ok(AcceptOutcome::Closed),
        Err(_) => Ok(AcceptOutcome::TimedOut),
    }
}

async fn serve_handoff(
    incoming: iroh::endpoint::Incoming,
    label: &str,
    ticket: &str,
) -> Result<()> {
    let conn = incoming
        .accept()
        .context("accept handoff connection")?
        .await
        .context("complete handoff connection")?;
    // Host is the initiator: open_uni + write makes the client's accept_uni
    // resolve (a stream is only "accepted" once the initiator sends data).
    let mut send = conn.open_uni().await.context("open handoff stream")?;
    let payload = format!("{label}\n{ticket}");
    send.write_all(payload.as_bytes())
        .await
        .context("send handoff payload")?;
    send.finish()?;
    drop(send);

    // Hold the connection open until the client disconnects (or QUIC's idle
    // timeout fires). Returning here immediately would tear down the endpoint
    // and race the client's `accept_uni`, sometimes aborting the stream before
    // the payload is read — manifesting as a spurious "timed out".
    let _ = conn.closed().await;
    Ok(())
}

// ────────────────────────── claim (client side) ────────────────────────────

/// Resolve a `zuko share` code to the host's real ticket, save it, and (by
/// default) connect immediately. `no_save` just prints the ticket; `no_connect`
/// skips the terminal session.
pub async fn claim(
    code: &str,
    name: Option<String>,
    no_connect: bool,
    no_save: bool,
    timeout_secs: u64,
) -> Result<()> {
    // No tracing subscriber here: if we connect, the terminal goes raw and any
    // log output would corrupt it. Status goes to stderr; the ticket to stdout.
    let secret = derive_key(code);
    let node_id = secret.public();

    let endpoint = Endpoint::builder(presets::N0)
        .bind()
        .await
        .context("bind local endpoint")?;
    endpoint.online().await;

    // The throwaway endpoint is dialed by node id and resolved via the N0 DNS
    // address-lookup, which can lag a few seconds behind `zuko share` coming
    // online. Retry the dial with backoff so a fast claimer rides out the
    // propagation delay instead of failing immediately.
    let conn = dial_throwaway(&endpoint, node_id, timeout_secs)
        .await
        .context("couldn't reach the sharing host — is `zuko share` still running and the code correct?")?;

    let mut recv = conn.accept_uni().await.context("accept handoff stream")?;
    let payload = read_to_end(&mut recv, MAX_HANDOFF_PAYLOAD).await?;
    let payload = String::from_utf8(payload).context("handoff payload wasn't utf-8")?;

    let (label, ticket) = payload
        .split_once('\n')
        .unwrap_or(("host", payload.as_str()));
    let label = label.trim();
    let ticket = ticket.trim();
    if ticket.is_empty() {
        bail!("received an empty ticket");
    }

    eprintln!("claimed host: {label}");
    if no_save {
        // Raw ticket to stdout so it can be piped into `zuko add` etc.
        println!("{ticket}");
    } else {
        let save_name = name.unwrap_or_else(|| label.to_string());
        crate::store::add(&save_name, ticket)?;
        eprintln!("saved as {save_name}  (run `zuko {save_name}` to reconnect)");
    }

    if !no_connect {
        crate::client::connect(ticket).await?;
    }
    Ok(())
}

/// Dial the throwaway host, retrying with constant backoff. The throwaway
/// endpoint is resolved via the N0 DNS address-lookup, which can lag a couple
/// seconds behind `zuko share` coming online; backon handles the tenacity.
///
/// `timeout_secs > 0` bounds the *total* wall time (across all attempts) via an
/// outer deadline; `timeout_secs == 0` tries up to a fixed number of attempts.
async fn dial_throwaway(
    endpoint: &Endpoint,
    node_id: iroh::PublicKey,
    timeout_secs: u64,
) -> Result<iroh::endpoint::Connection> {
    // Constant 2s between attempts: long enough for DNS propagation, short
    // enough that the outer deadline still allows many tries.
    const DELAY: Duration = Duration::from_secs(2);
    const MAX_TIMES: usize = 30;

    let retry = (|| async { endpoint.connect(node_id, HANDOFF_ALPN).await })
        .retry(ConstantBuilder::default().with_delay(DELAY).with_max_times(MAX_TIMES))
        .notify(|err: &iroh::endpoint::ConnectError, dur: Duration| {
            warn!("claim dial failed, retrying in {dur:?}: {err}");
        });

    if timeout_secs == 0 {
        return retry.await.context("dial throwaway endpoint");
    }
    tokio::time::timeout(Duration::from_secs(timeout_secs), retry)
        .await
        .map_err(|_| anyhow::anyhow!("timed out after {timeout_secs}s"))?
        .context("dial throwaway endpoint")
}

/// Read a uni recv stream to end, bailing if it exceeds `max` bytes.
async fn read_to_end(recv: &mut iroh::endpoint::RecvStream, max: usize) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        match recv.read(&mut tmp).await {
            Ok(Some(n)) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.len() > max {
                    bail!("handoff payload exceeded {max} bytes");
                }
            }
            Ok(None) => return Ok(buf),
            Err(e) => return Err(e).context("read handoff payload"),
        }
    }
}

// ─────────────────── code generation + key derivation ──────────────────────

/// Normalise a typed code into its canonical letter sequence: lowercased, with
/// everything except a–z stripped. Separators are only for readability, so
/// `Tofa-Mive`, `tofa mive`, and `tofamive` all derive the same key.
fn normalize_code(code: &str) -> String {
    code.trim()
        .to_lowercase()
        .chars()
        .filter(|c| c.is_ascii_lowercase())
        .collect()
}

/// Derive the throwaway [`SecretKey`] deterministically from a code. Both sides
/// run exactly this, so they converge on the same key (and thus the same node
/// id) without ever exchanging secret material.
fn derive_key(code: &str) -> SecretKey {
    let material = normalize_code(code);
    let mut hasher = Sha256::new();
    hasher.update(material.as_bytes());
    let digest = hasher.finalize();
    let mut seed = [0u8; 32];
    seed.copy_from_slice(&digest);
    SecretKey::from_bytes(&seed)
}

/// Generate a fresh, memorable code: `WORD-WORD-WORD-WORD`, each word a
/// pronounceable CVCV (e.g. `tofa-mive-laru-bedo`). Entropy comes from
/// [`SecretKey::generate`] (OsRng).
fn generate_code() -> String {
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

fn pick(alphabet: &[u8], byte: u8) -> u8 {
    alphabet[(byte as usize) % alphabet.len()]
}

/// Default handoff label: the system hostname if we can find it cheaply,
/// otherwise the boring-but-honest `"host"`.
fn default_label() -> String {
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
fn sanitize_label(s: &str) -> String {
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

// ─────────────────────── current_ticket file helpers ───────────────────────
//
// `zuko host` writes its live, dialable ticket here; `zuko share` reads it so
// the handoff never needs an IPC channel to the running daemon. The file is a
// dialing secret (anyone holding it can connect), so it's written 0600 like
// the key.

/// `~/.config/zuko/current_ticket` (follows `XDG_CONFIG_HOME`).
pub fn current_ticket_path() -> std::path::PathBuf {
    let mut p = crate::config_dir();
    p.push("zuko");
    p.push("current_ticket");
    p
}

/// Write the live ticket atomically with 0600 perms (best-effort; errors
/// logged but not fatal — the host keeps serving shells even if this write
/// fails). Called by `zuko host` on startup and periodically.
pub fn write_current_ticket(ticket: &str) -> Result<()> {
    write_secret_0600(&current_ticket_path(), ticket.trim().as_bytes())
}

fn read_current_ticket() -> Result<String> {
    let path = current_ticket_path();
    let ticket = std::fs::read_to_string(&path).with_context(|| {
        format!(
            "read {} (is `zuko host` running? it writes the current ticket there)",
            path.display()
        )
    })?;
    let ticket = ticket.trim().to_string();
    if ticket.is_empty() {
        bail!("{} is empty (is `zuko host` running?)", path.display());
    }
    Ok(ticket)
}

fn write_secret_0600(path: &std::path::Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).ok();
    }
    let tmp = path.with_extension("tmp");
    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(&tmp, bytes)?;
    }
    std::fs::rename(&tmp, path)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_is_separator_and_case_agnostic() {
        assert_eq!(normalize_code("tofa-mive-laru-bedo"), "tofamivelarubedo");
        assert_eq!(normalize_code("Tofa Mive LarU beDo"), "tofamivelarubedo");
        assert_eq!(normalize_code("  tofa_mive.laru+bedo  "), "tofamivelarubedo");
        assert_eq!(normalize_code("TOFAMIVELARUBEDO"), "tofamivelarubedo");
        // Non-letters are dropped entirely.
        assert_eq!(normalize_code("t0f4-m!v3"), "tfmv");
    }

    #[test]
    fn derive_key_is_deterministic_and_input_sensitive() {
        // Same logical code -> same key, regardless of formatting.
        let a = derive_key("tofa-mive-laru-bedo");
        let b = derive_key("TOFA MIVE LARU BEDO");
        assert_eq!(a.to_bytes(), b.to_bytes());

        // Different code -> different key.
        let c = derive_key("tofa-mive-laru-beee");
        assert_ne!(a.to_bytes(), c.to_bytes());

        // public() is a stable function of the key, so both sides also agree
        // on the node id they're dialing / serving as.
        assert_eq!(a.public(), b.public());
    }

    #[test]
    fn generate_code_is_well_formed() {
        for _ in 0..256 {
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
            // A generated code must round-trip through derive_key without panic.
            let _ = derive_key(&code).public();
        }
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
}
