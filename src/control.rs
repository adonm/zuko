//! Control socket for the host daemon.
//!
//! The host binds a Unix domain socket at [`control_socket_path`] so that
//! same-user CLI subcommands — currently just `zuko reap` — can ask a running
//! `zuko host` to do something without an IPC channel piggybacking on the
//! Iroh stream (the terminal protocol is byte-for-byte passthrough; control
//! bytes would corrupt the user's shell).
//!
//! ## Wire (line-based, ASCII, newline-terminated)
//!
//! One request line, then the client half-closes its write side. The server
//! replies with zero or more `REAPED` lines followed by a single terminator:
//!
//! ```text
//! client -> server:  REAP <min_idle_secs> <skip_session_hex | none>\n
//! server -> client:  REAPED <session_hex>\n   (zero or more)
//!                   DONE <count>\n
//! ```
//!
//! On a malformed request the server replies `ERROR <message>\n` and closes.
//! Unknown verbs are an error — forward compat is opt-in by adding new verbs.
//!
//! ## Trust boundary
//!
//! The socket is at `~/.config/zuko/control.sock` and (by default) created
//! with the same 0700-ish access as the rest of that dir, so only the host's
//! own user can reach it. Anyone on the trust boundary (anyone who can become
//! that user) can already do far worse; this is not a new exposure.

use anyhow::{bail, Context, Result};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use crate::config_dir;
use crate::wire::SessionId;

/// `~/.config/zuko/control.sock` (follows `XDG_CONFIG_HOME`).
pub fn control_socket_path() -> PathBuf {
    let mut p = config_dir();
    p.push("zuko");
    p.push("control.sock");
    p
}

/// Default idle threshold for `zuko reap`: 1 hour. Matches the operator
/// expectation in the README — abandoned sessions get cleaned up on a cadence
/// the user controls rather than silently by the daemon.
pub const DEFAULT_REAP_IDLE_SECS: u64 = 60 * 60;

/// Encode a session id as 16 lowercase hex chars. Used by the host (when
/// stuffing `$ZUKO_SESSION_ID` into the shell env and when reporting reaped
/// ids) and by the protocol layer here.
pub fn hex_id(id: &SessionId) -> String {
    let mut s = String::with_capacity(16);
    use std::fmt::Write;
    for b in id {
        write!(s, "{b:02x}").expect("writes to a String never fail");
    }
    s
}

/// Parse 16 lowercase-or-uppercase hex chars into a session id. Tolerates
/// surrounding whitespace. Returns `None` for any wrong-length or non-hex
/// input — the caller (the host's control-socket handler) treats that as a
/// protocol error and replies `ERROR`, never panics.
pub fn parse_session_id_hex(s: &str) -> Option<SessionId> {
    let s = s.trim();
    let bytes = s.as_bytes();
    if bytes.len() != 16 {
        return None;
    }
    let mut out = [0u8; 8];
    for (i, chunk) in bytes.chunks_exact(2).enumerate() {
        out[i] = u8::from_str_radix(std::str::from_utf8(chunk).ok()?, 16).ok()?;
    }
    Some(out)
}

/// Connect to a running `zuko host`'s control socket and ask it to reap
/// sessions idle for more than `min_idle_secs`. `skip` (if `Some`) is the
/// session id the command is running inside (read by the CLI from
/// `$ZUKO_SESSION_ID`); the host will never reap it, so `zuko reap` run from
/// inside a zuko session can't kill its own shell out from under itself.
///
/// Returns the hex ids of the sessions the host reaped. Empty if there were
/// no candidates over the threshold.
pub fn reap(min_idle_secs: u64, skip: Option<SessionId>) -> Result<Vec<String>> {
    let path = control_socket_path();
    let mut stream = UnixStream::connect(&path).with_context(|| {
        format!(
            "connect {} (is `zuko host` running on this machine?)",
            path.display()
        )
    })?;
    // Defence-in-depth: a wedged host shouldn't hang the CLI forever. 10 s is
    // far longer than the reap sweep takes (just an iteration of the session
    // registry + child kills); if we hit it, something is wrong upstream.
    let timeout = Duration::from_secs(10);
    stream.set_read_timeout(Some(timeout)).ok();
    stream.set_write_timeout(Some(timeout)).ok();

    let skip_hex = match skip {
        Some(id) => hex_id(&id),
        None => "none".to_string(),
    };
    let req = format!("REAP {min_idle_secs} {skip_hex}\n");
    stream
        .write_all(req.as_bytes())
        .context("send reap request")?;
    // Half-close so the server's `read_line` sees EOF after the request and
    // can't block waiting for more bytes that will never come.
    stream
        .shutdown(std::net::Shutdown::Write)
        .context("shutdown control socket write half")?;

    let mut reader = BufReader::new(stream);
    let mut reaped: Vec<String> = Vec::new();
    let mut line = String::new();
    loop {
        line.clear();
        let n = reader.read_line(&mut line).context("read reap response")?;
        if n == 0 {
            bail!("control socket closed before DONE");
        }
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("REAPED ") {
            reaped.push(rest.to_string());
        } else if trimmed.strip_prefix("DONE ").is_some() {
            return Ok(reaped);
        } else if let Some(rest) = trimmed.strip_prefix("ERROR ") {
            bail!("host: {rest}");
        } else {
            bail!("unexpected response line: {trimmed:?}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_round_trip() {
        let id: SessionId = [0x00, 0x11, 0x22, 0x33, 0xaa, 0xbb, 0xcc, 0xdd];
        let hex = hex_id(&id);
        assert_eq!(hex, "00112233aabbccdd");
        assert_eq!(parse_session_id_hex(&hex), Some(id));
    }

    #[test]
    fn hex_parse_tolerates_case_and_whitespace() {
        assert_eq!(
            parse_session_id_hex("  ABcdEF0123456789  "),
            Some([0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89])
        );
    }

    #[test]
    fn hex_parse_rejects_wrong_length_and_non_hex() {
        assert!(parse_session_id_hex("00112233aabbccdd00").is_none()); // too long
        assert!(parse_session_id_hex("00112233aabbcc").is_none()); // too short
        assert!(parse_session_id_hex("zz112233aabbccdd").is_none()); // non-hex
        assert!(parse_session_id_hex("").is_none());
    }
}
