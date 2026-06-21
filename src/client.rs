//! `zuko connect` — attach a local terminal to a remote `zuko host`.
//!
//! The mirror image of [`crate::host`]: puts the local terminal into raw mode,
//! opens a bidi Iroh stream to the host, and shuttles bytes back and forth
//! using the shared [`crate::wire`] framing. `vim`, `htop`, tab completion, and
//! resize all work because the host runs a real PTY.
//!
//! ## Single-shot (v0.6)
//!
//! No app-level heartbeat and no protocol resume. The CLI is intentionally
//! single-shot: on drop (network loss, host down, shell exit) it restores the
//! local terminal and exits; the user re-runs `zuko <host>` for a fresh PTY.
//! Mobile clients may auto-redial transient drops, but every successful redial
//! still starts a fresh PTY. Users running long-lived work should do so inside
//! `tmux`/`zellij`/`screen` on the host.
//!
//! ## Force-quit
//!
//! Because raw mode forwards Ctrl-C to the remote shell, a wedged connection
//! has no escape: keystrokes disappear into the frame channel and the only
//! recovery is killing the process from another terminal. Pressing Ctrl-C
//! 3× within ~1 s, with no remote output between presses, force-exits the
//! local client (exit code 130, the SIGINT convention). The "no output" gate
//! is what distinguishes a wedged session from a silent but healthy one.

use anyhow::{Context, Result};
use iroh::{Endpoint, EndpointAddr, endpoint::presets};
use iroh_tickets::endpoint::EndpointTicket;
use std::sync::Arc;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::time::Instant;
use tokio::io::AsyncWriteExt as _;
use tokio::sync::mpsc;

use crate::wire::{
    ALPN, SESSION_TOKEN_LEN, TYPE_DATA, TYPE_PING, attach_frame, decode_nonce, pong_frame,
    resize_frame, try_parse_frame,
};

/// Force-quit escape hatch: in raw mode Ctrl-C (0x03) is forwarded to the
/// remote shell, so a wedged connection has no normal escape (keystrokes go
/// into the void). Pressing Ctrl-C this many times, each within
/// `FORCE_QUIT_WINDOW` of the previous **and** with no remote output between
/// presses, force-exits the local client. The "no output" gate is what keeps
/// this from triggering when the user is just mashing Ctrl-C to interrupt a
/// silent long-running remote command — a responsive remote resets the count.
/// Abrupt exit is low-cost: a `zuko` session typically targets a shell inside
/// tmux/zellij, so the remote work survives.
const FORCE_QUIT_PRESSES: u32 = 3;
const FORCE_QUIT_WINDOW: std::time::Duration = std::time::Duration::from_secs(1);

/// Connect to a host once and bridge the local terminal to its shell until the
/// remote shell exits or the link drops.
pub async fn connect(ticket_str: &str) -> Result<()> {
    let ticket = ticket_str
        .parse::<EndpointTicket>()
        .with_context(|| "that doesn't look like a ticket")?;
    let addr: EndpointAddr = ticket.into();

    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    // Current terminal size, updated by SIGWINCH. Packed as cols<<16 | rows in
    // a u32 so the connect path can read it lock-free.
    let size: Arc<AtomicU32> = Arc::new(AtomicU32::new(pack_size(cols, rows)));

    // Connect *before* entering raw mode so connect errors print to a normal,
    // cooked terminal instead of a half-set-up raw one.
    let endpoint = Endpoint::builder(presets::N0)
        .bind()
        .await
        .context("bind local endpoint")?;

    crossterm::terminal::enable_raw_mode().context("enable raw mode")?;
    let _guard = RawModeGuard;

    // Outbound frame channel. stdin + SIGWINCH push pre-framed bytes here;
    // the writer task drains it into the send stream. Bounded so a flood
    // can't grow memory unbounded (the producer awaits, back-pressuring
    // stdin reads).
    let (frame_tx, frame_rx) = mpsc::channel::<Vec<u8>>(64);

    // Monotonic token bumped by the read loop whenever DATA is written to
    // stdout. The stdin thread samples it to detect "no remote output since
    // the previous Ctrl-C", which is the gate for the 3× Ctrl-C force-quit
    // hatch. Any remote output bumps this, which is exactly the "remote is
    // alive" signal we want to reset the burst.
    let stdout_seq: Arc<AtomicU64> = Arc::new(AtomicU64::new(0));

    // stdin -> DATA frames. A dedicated OS thread does blocking reads (the
    // original design — tokio's async stdin also parks on a blocking thread,
    // and a plain thread keeps the cancellation story simple). Bytes are
    // forwarded verbatim so the remote shell sees exactly what a local shell
    // would (Ctrl-C is 0x03, etc). EOF (Ctrl-D) just stops the producer; the
    // shell's response to it drives session end via recv EOF.
    //
    // The thread also implements the force-quit escape hatch: a burst of
    // Ctrl-C presses with no remote output between them force-exits the
    // client, since raw mode otherwise swallows Ctrl-C into the remote
    // stream and leaves no way out of a wedged session.
    let stdin_tx = frame_tx.clone();
    let stdout_seq_for_stdin = stdout_seq.clone();
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut buf = vec![0u8; 4096];
        // Burst-tracking state. `burst` is the count of consecutive
        // qualifying Ctrl-Cs; `prev_at` is when we last saw one; `prev_at_seq`
        // is the value of `stdout_seq` at that moment, so we can tell whether
        // any output has arrived since.
        let mut burst: u32 = 0;
        let mut prev_at: Option<Instant> = None;
        let mut prev_at_seq: u64 = 0;
        loop {
            match std::io::Read::read(&mut stdin, &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if stdin_tx
                        .blocking_send(crate::wire::data_frame(&buf[..n]))
                        .is_err()
                    {
                        break;
                    }
                    // Force-quit accounting. We count 0x03 bytes; a paste of
                    // several is an intentional gesture and resolves the same
                    // way as mashing the key.
                    let now = Instant::now();
                    let cur_seq = stdout_seq_for_stdin.load(Ordering::Relaxed);
                    for &b in &buf[..n] {
                        if b != 0x03 {
                            continue;
                        }
                        let within_window =
                            prev_at.is_some_and(|p| now.duration_since(p) <= FORCE_QUIT_WINDOW);
                        let output_unchanged = cur_seq == prev_at_seq;
                        burst = advance_burst(burst, within_window, output_unchanged);
                        prev_at = Some(now);
                        prev_at_seq = cur_seq;
                        if burst >= FORCE_QUIT_PRESSES {
                            force_quit();
                        }
                    }
                }
            }
        }
    });

    // SIGWINCH (terminal resize) -> RESIZE frames + size-tracking update.
    #[cfg(unix)]
    {
        let resize_tx = frame_tx.clone();
        let size_for_signal = size.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{SignalKind, signal};
            let Ok(mut sig) = signal(SignalKind::window_change()) else {
                return;
            };
            while sig.recv().await.is_some() {
                if let Ok((c, r)) = crossterm::terminal::size() {
                    size_for_signal.store(pack_size(c, r), Ordering::Relaxed);
                    if resize_tx.send(resize_frame(c, r)).await.is_err() {
                        break;
                    }
                }
            }
        });
    }

    // Single-shot CLI connect: the user re-runs `zuko <host>` if the link
    // drops. This keeps raw-mode terminal recovery boring and avoids implying
    // session state survived when the next dial would be a fresh PTY.
    let result: Result<()> = async {
        let conn = endpoint.connect(addr, ALPN).await.context("dial host")?;
        let (mut send, recv) = conn.open_bi().await.context("open bidi stream")?;

        // Initial ATTACH — zero token means "fresh PTY". Sent directly on
        // `send` BEFORE handing it to the writer so it's guaranteed first on
        // the wire.
        let (c, r) = unpack_size(size.load(Ordering::Relaxed));
        send.write_all(&attach_frame([0u8; SESSION_TOKEN_LEN], c, r))
            .await
            .context("send initial ATTACH")?;

        // Writer: drains the frame channel (stdin + SIGWINCH) into the send
        // stream. Runs until the channel closes or `send` errors.
        let writer = tokio::spawn(async move {
            let mut frame_rx = frame_rx;
            while let Some(frame) = frame_rx.recv().await {
                if send.write_all(&frame).await.is_err() {
                    break;
                }
            }
            let _ = send.finish();
        });

        // One-shot discoverability nudge for the force-quit hatch. Stays on
        // its own line via status_line's CR/\r\n so the remote prompt draws
        // cleanly under it.
        status_line("connected — press Ctrl-C 3× to force-quit if it hangs");

        // Read loop: DATA -> stdout. PINGs are answered for compatibility
        // with older/future peers; PONGs and unknown types are ignored.
        // Heartbeat removed in v0.6 — iroh's QUIC keepalive handles liveness.
        let mut recv = recv;
        let mut acc: Vec<u8> = Vec::with_capacity(16 * 1024);
        let mut tmp = vec![0u8; 16 * 1024];
        let read_result: Result<()> = loop {
            match recv.read(&mut tmp).await {
                Ok(Some(n)) => {
                    acc.extend_from_slice(&tmp[..n]);
                    while let Some(f) = try_parse_frame(&mut acc) {
                        match f.typ {
                            TYPE_DATA => {
                                let mut stdout = tokio::io::stdout();
                                if stdout.write_all(&f.payload).await.is_err()
                                    || stdout.flush().await.is_err()
                                {
                                    anyhow::bail!("stdout write failed");
                                }
                                // Bump the force-quit token: any DATA the
                                // remote sent resets the Ctrl-C burst.
                                stdout_seq.fetch_add(1, Ordering::Relaxed);
                            }
                            TYPE_PING => {
                                if let Some(reply) = control_reply_frame(f.typ, &f.payload) {
                                    let _ = frame_tx.send(reply).await;
                                }
                            }
                            _ => {}
                        }
                    }
                }
                Ok(None) => break Ok(()), // host closed → shell exited
                Err(e) => break Err(e).context("connection read failed"),
            }
        };

        // Cancel the writer (send stream may still be alive on shell-exit).
        writer.abort();
        read_result
    }
    .await;

    // Restore the terminal first, then surface any error on a clean (cooked) tty.
    drop(_guard);
    if let Err(e) = &result {
        eprintln!("\nzuko: {e:#}");
    }

    result
}

/// Restore cooked terminal mode on scope exit (and on unwind/panic, since the
/// release profile keeps unwinding). Best-effort: errors are ignored.
struct RawModeGuard;
impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = crossterm::terminal::disable_raw_mode();
    }
}

const fn pack_size(cols: u16, rows: u16) -> u32 {
    ((cols as u32) << 16) | (rows as u32)
}
const fn unpack_size(packed: u32) -> (u16, u16) {
    ((packed >> 16) as u16, (packed & 0xFFFF) as u16)
}

fn control_reply_frame(typ: u8, payload: &[u8]) -> Option<Vec<u8>> {
    (typ == TYPE_PING).then(|| pong_frame(decode_nonce(payload)))
}

/// Print a status line without corrupting the terminal: a CR, the message,
/// and a clear-to-end-of-line. Raw mode means no automatic CR/LF translation,
/// so we use `\r` explicitly and EL (erase in line) to avoid leaving stale
/// chars when a shorter message follows a longer one.
fn status_line(msg: &str) {
    use std::io::Write;
    let mut out = std::io::stderr();
    let _ = write!(out, "\r\x1b[2Kzuko: {msg}\r\n");
    let _ = out.flush();
}

/// Pure rule for the 3× Ctrl-C force-quit hatch. Returns the new burst count
/// after observing one Ctrl-C. `within_window` should be true iff the previous
/// Ctrl-C was within `FORCE_QUIT_WINDOW`; `output_unchanged` should be true
/// iff no `DATA` frame has been written to stdout since the previous Ctrl-C.
/// Extracted as a free function so the rule is unit-testable without I/O.
const fn advance_burst(prev_burst: u32, within_window: bool, output_unchanged: bool) -> u32 {
    if within_window && output_unchanged {
        prev_burst.saturating_add(1)
    } else {
        1
    }
}

/// Force-exit the client from the stdin thread: restore cooked mode first so
/// the message lands on a clean terminal (the `RawModeGuard` won't run its
/// `Drop` across `process::exit`), then exit 130 — the conventional code for
/// "terminated by SIGINT", so the parent shell sees an interrupt rather than
/// a generic failure. Deliberately skips `Endpoint::close`: the user has
/// decided the session is stuck and wants out *now*; the remote shell is
/// typically inside tmux/zellij and survives.
fn force_quit() -> ! {
    let _ = crossterm::terminal::disable_raw_mode();
    eprintln!("\rzuko: 3× Ctrl-C with no response — exiting");
    std::process::exit(130);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn burst_starts_at_one() {
        // First-ever Ctrl-C: no prior press, so it always starts a fresh burst
        // at 1 regardless of the window/output inputs.
        assert_eq!(advance_burst(0, false, false), 1);
        assert_eq!(advance_burst(0, true, true), 1);
    }

    #[test]
    fn burst_climbs_when_no_output_and_within_window() {
        // The wedged case: rapid Ctrl-Cs, nothing coming back. Climbs to the
        // threshold, at which point the stdin thread calls `force_quit`.
        let mut burst = advance_burst(0, false, false);
        assert_eq!(burst, 1);
        burst = advance_burst(burst, true, true);
        assert_eq!(burst, 2);
        burst = advance_burst(burst, true, true);
        assert_eq!(burst, 3);
        assert!(burst >= FORCE_QUIT_PRESSES);
    }

    #[test]
    fn burst_resets_when_remote_output_arrived() {
        // Healthy remote: Ctrl-C interrupts the foreground job, the shell
        // redraws a prompt (DATA arrives) — the next Ctrl-C must NOT carry
        // over the previous burst, or normal usage would false-trigger.
        let burst = advance_burst(0, false, false);
        let burst = advance_burst(burst, true, true); // 2, still wedged
        assert_eq!(burst, 2);
        // Remote responded between presses → output_unchanged is false.
        let burst = advance_burst(burst, true, false);
        assert_eq!(burst, 1, "output between presses must reset the burst");
    }

    #[test]
    fn burst_resets_when_too_far_apart_in_time() {
        // User hit Ctrl-C, wandered off, came back and hit it again: not a
        // force-quit gesture, treat as a fresh single press.
        let burst = advance_burst(0, false, false);
        let burst = advance_burst(burst, true, true);
        assert_eq!(burst, 2);
        let burst = advance_burst(burst, false, true);
        assert_eq!(burst, 1, "outside the window must reset the burst");
    }

    #[test]
    fn burst_saturates_and_never_overflows() {
        // A runaway caller (or a paste of many 0x03 bytes) can't wrap the
        // counter past the threshold into stale "below threshold" territory.
        let mut burst = FORCE_QUIT_PRESSES;
        for _ in 0..1_000 {
            burst = advance_burst(burst, true, true);
            assert!(burst >= FORCE_QUIT_PRESSES);
        }
    }

    #[test]
    fn replies_to_ping_for_peer_compatibility() {
        let reply = control_reply_frame(crate::wire::TYPE_PING, &42u64.to_be_bytes()).unwrap();
        let mut buf = reply;
        let frame = crate::wire::try_parse_frame(&mut buf).unwrap();
        assert_eq!(frame.typ, crate::wire::TYPE_PONG);
        assert_eq!(crate::wire::decode_nonce(&frame.payload), 42);
    }

    #[test]
    fn ignores_non_ping_control_frames() {
        assert!(control_reply_frame(crate::wire::TYPE_PONG, &[]).is_none());
        assert!(control_reply_frame(0xFF, &[]).is_none());
    }
}
