//! `zuko connect` — attach a local terminal to a remote `zuko host`.
//!
//! The mirror image of [`crate::host`]: puts the local terminal into raw mode,
//! opens a bidi Iroh stream to the host, and shuttles bytes back and forth
//! using the shared [`crate::wire`] framing. `vim`, `htop`, tab completion, and
//! resize all work because the host runs a real PTY.
//!
//! ## Session resume (v0.4)
//!
//! The connection runs in a reconnect loop: on a network drop (recv errors) we
//! reconnect and send a `HELLO` carrying the session id the host assigned on
//! the first connection. The host resumes the same PTY, replays its recent
//! output, and we keep going — the shell's state survives the blip. On a
//! genuine shell exit (recv EOF) we stop and exit. A bounded backoff spaces
//! reconnect attempts; the user can `kill` the process to give up.
//!
//! ## Heartbeat
//!
//! We send a `PING` every 5 s and answer inbound `PING`s with `PONG`. If no
//! frame arrives for ~10 s we print a "stalled" notice (iroh's QUIC keepalive
//! keeps the transport alive, but this surfaces a stuck link to the user
//! faster than the 15–30 s QUIC idle timeout).

use anyhow::{Context, Result};
use iroh::endpoint::RecvStream;
use iroh::{endpoint::presets, Endpoint, EndpointAddr};
use iroh_tickets::endpoint::EndpointTicket;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt as _;
use tokio::sync::{mpsc, Notify};

use crate::wire::{
    decode_nonce, ping_frame, pong_frame, resize_frame, try_parse_frame, Hello, Welcome,
    FLAG_HEARTBEAT, FLAG_RESUME, TYPE_DATA, TYPE_PING, TYPE_WELCOME, ALPN,
};

/// Reconnect backoff: starts here, doubles, caps here.
const BACKOFF_MIN: Duration = Duration::from_millis(500);
const BACKOFF_MAX: Duration = Duration::from_secs(5);

/// Heartbeat: send a PING this often, declare stalled after this long with no
/// inbound frame at all.
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(5);
const STALL_THRESHOLD: Duration = Duration::from_secs(10);

/// Why a connection's read half ended — drives the reconnect loop.
enum ReadEnd {
    /// Recv hit EOF — the host closed the stream, i.e. the shell exited. Stop.
    ShellExited,
    /// Recv errored — network drop. Reconnect (resume the session).
    Disconnected,
}

/// Connect to a host and bridge the local terminal to its shell, reconnecting
/// on network drops until the remote shell exits.
pub async fn connect(ticket_str: &str) -> Result<()> {
    let ticket = ticket_str
        .parse::<EndpointTicket>()
        .with_context(|| "that doesn't look like a ticket")?;
    let addr: EndpointAddr = ticket.into();

    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    // Current terminal size, updated by SIGWINCH across reconnects. Packed as
    // cols<<16 | rows in a u32 so the reconnect path can read it lock-free.
    let size: Arc<AtomicU32> = Arc::new(AtomicU32::new(pack_size(cols, rows)));

    // Connect *before* entering raw mode so connect errors print to a normal,
    // cooked terminal instead of a half-set-up raw one.
    let endpoint = Endpoint::builder(presets::N0)
        .bind()
        .await
        .context("bind local endpoint")?;

    crossterm::terminal::enable_raw_mode().context("enable raw mode")?;
    let _guard = RawModeGuard;

    // Outbound frame channel — persistent across reconnects. stdin + SIGWINCH
    // + heartbeat push pre-framed bytes here; a per-connection writer task
    // drains it into the current send stream. Between connections the receiver
    // is stashed in a slot so a reconnect can pick it up and keep draining
    // (keystrokes typed during the outage flush on reconnect).
    let (frame_tx, frame_rx) = mpsc::channel::<Vec<u8>>(64);
    let frame_rx_slot: Arc<tokio::sync::Mutex<Option<mpsc::Receiver<Vec<u8>>>>> =
        Arc::new(tokio::sync::Mutex::new(Some(frame_rx)));

    // stdin -> DATA frames. A dedicated OS thread does blocking reads (the
    // original design — tokio's async stdin also parks on a blocking thread,
    // and a plain thread keeps the cancellation story simple). Bytes are
    // forwarded verbatim so the remote shell sees exactly what a local shell
    // would (Ctrl-C is 0x03, etc). EOF (Ctrl-D) just stops the producer; the
    // shell's response to it drives session end via recv EOF.
    let stdin_tx = frame_tx.clone();
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut buf = vec![0u8; 4096];
        loop {
            match std::io::Read::read(&mut stdin, &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if stdin_tx.blocking_send(crate::wire::data_frame(&buf[..n])).is_err() {
                        break;
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
            use tokio::signal::unix::{signal, SignalKind};
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

    let mut session_id: Option<[u8; 8]> = None;
    let mut backoff = BACKOFF_MIN;
    let stop = Arc::new(AtomicBool::new(false));

    // Reconnect loop. Each iteration: dial, handshake (HELLO + initial RESIZE),
    // run the session until the read half ends, then either stop (shell exited)
    // or back off and reconnect (resume).
    let result: Result<()> = loop {
        let conn = match endpoint.connect(addr.clone(), ALPN).await {
            Ok(c) => c,
            Err(_) => {
                status_line(&format!("can't reach host, retrying in {:.1}s…", backoff.as_secs_f64()));
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(BACKOFF_MAX);
                continue;
            }
        };
        let (mut send, recv) = match conn.open_bi().await {
            Ok(bi) => bi,
            Err(_) => {
                status_line(&format!("stream open failed, retrying in {:.1}s…", backoff.as_secs_f64()));
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(BACKOFF_MAX);
                continue;
            }
        };

        // Handshake: HELLO (caps + current size + session id) then a RESIZE.
        // Sent directly on `send` BEFORE handing it to the writer, so they're
        // guaranteed first on the wire (a resumed session's ring replay + the
        // PTY's SIGWINCH redraw both depend on the size being known up front).
        let (c, r) = unpack_size(size.load(Ordering::Relaxed));
        let hello = Hello {
            flags: FLAG_RESUME | FLAG_HEARTBEAT,
            cols: c,
            rows: r,
            session_id,
        };
        if send.write_all(&hello.frame()).await.is_err()
            || send.write_all(&resize_frame(c, r)).await.is_err()
        {
            // The brand-new stream already broke — treat as a disconnect.
            status_line("handshake write failed, reconnecting…");
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(BACKOFF_MAX);
            continue;
        }

        // Hand the send stream to a writer that drains the (persistent) frame
        // receiver. Take the receiver back from the slot so this writer owns
        // it; on exit (cancel or send error) it puts it back for the next
        // reconnect. `writer_stop` lets the loop cancel the writer on
        // shell-exit (the send stream is still alive there, so the writer
        // wouldn't end on its own — without this, `writer.await` would hang).
        let frame_rx = {
            let mut slot = frame_rx_slot.lock().await;
            slot.take().expect("frame_rx present between connections")
        };
        let slot_for_writer = frame_rx_slot.clone();
        let writer_stop = Arc::new(Notify::new());
        let writer_stop_for_writer = writer_stop.clone();
        let writer = tokio::spawn(async move {
            let mut frame_rx = frame_rx;
            let mut send = send;
            loop {
                tokio::select! {
                    biased;
                    _ = writer_stop_for_writer.notified() => break,
                    frame = frame_rx.recv() => {
                        let Some(frame) = frame else { break; };
                        if send.write_all(&frame).await.is_err() {
                            break;
                        }
                    }
                }
            }
            let _ = send.finish();
            // Return the receiver so the next reconnect can keep draining.
            *slot_for_writer.lock().await = Some(frame_rx);
        });

        // Read the WELCOME (first frame) so we can adopt the host's session id.
        // A legacy host (v0.3) that doesn't speak HELLO would never send one;
        // we'd time out via the read erroring. Detect that: a non-WELCOME first
        // frame or an early EOF bails and we reconnect.
        let (welcome, mut acc, recv) = match read_welcome(recv).await {
            Ok(triple) => triple,
            Err(_) => {
                status_line("host didn't send WELCOME (legacy peer?) — reconnecting…");
                writer.await.ok();
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(BACKOFF_MAX);
                continue;
            }
        };
        if let Some(id) = welcome.session_id {
            session_id = Some(id);
        }

        // A fresh (non-resumed) connection resets the backoff. A resumed one
        // does too — the resume succeeded, so the host is reachable.
        backoff = BACKOFF_MIN;
        if welcome.resumed() {
            status_line("resumed session");
        }

        // Heartbeat: PING every interval, enqueued into the frame channel so
        // the writer puts them on the wire alongside keystrokes.
        let ping_tx = frame_tx.clone();
        let stop_ping = stop.clone();
        let heartbeat = tokio::spawn(async move {
            let mut interval = tokio::time::interval(HEARTBEAT_INTERVAL);
            let mut nonce: u64 = 0;
            loop {
                interval.tick().await;
                if stop_ping.load(Ordering::Relaxed) {
                    break;
                }
                nonce = nonce.wrapping_add(1);
                if ping_tx.send(ping_frame(nonce)).await.is_err() {
                    break;
                }
            }
        });

        // Read loop: DATA -> stdout, PING -> PONG, track last-heard for stall.
        let last_heard = Arc::new(tokio::sync::Mutex::new(Instant::now()));
        let last_heard_for_read = last_heard.clone();
        let pong_tx = frame_tx.clone();
        let read_end = tokio::spawn(async move {
            let mut recv = recv;
            let mut tmp = vec![0u8; 16 * 1024];
            loop {
                match recv.read(&mut tmp).await {
                    Ok(Some(n)) => {
                        acc.extend_from_slice(&tmp[..n]);
                        while let Some(f) = try_parse_frame(&mut acc) {
                            *last_heard_for_read.lock().await = Instant::now();
                            match f.typ {
                                TYPE_DATA => {
                                    let mut stdout = tokio::io::stdout();
                                    if stdout.write_all(&f.payload).await.is_err()
                                        || stdout.flush().await.is_err()
                                    {
                                        return ReadEnd::Disconnected;
                                    }
                                }
                                TYPE_PING => {
                                    let _ = pong_tx.send(pong_frame(decode_nonce(&f.payload))).await;
                                }
                                _ => {} // WELCOME (already consumed), PONG, unknown: ignore
                            }
                        }
                    }
                    Ok(None) => return ReadEnd::ShellExited,
                    Err(_) => return ReadEnd::Disconnected,
                }
            }
        });

        // Stall watcher: if no frame has arrived for STALL_THRESHOLD, print a
        // notice once. Doesn't force a reconnect — iroh's QUIC idle timeout
        // (15–30 s) will eventually error the read and trigger that.
        let last_heard_for_stall = last_heard.clone();
        let stop_stall = stop.clone();
        let stall = tokio::spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(2)).await;
                if stop_stall.load(Ordering::Relaxed) {
                    break;
                }
                let elapsed = last_heard_for_stall.lock().await.elapsed();
                if elapsed > STALL_THRESHOLD {
                    status_line(&format!(
                        "connection stalled (no data for {:.0}s), waiting…",
                        elapsed.as_secs_f64()
                    ));
                }
            }
        });

        let end = read_end.await.unwrap_or(ReadEnd::Disconnected);
        stop.store(true, Ordering::Relaxed);
        heartbeat.abort();
        stall.abort();
        // Cancel the writer and wait for it to return frame_rx to the slot.
        // (On a network drop the writer's `send.write_all` also errors, but
        // the notify guarantees it stops promptly in the shell-exit case too,
        // where the send stream is still alive.)
        writer_stop.notify_one();
        writer.await.ok();

        match end {
            ReadEnd::ShellExited => break Ok(()),
            ReadEnd::Disconnected => {
                status_line("reconnecting…");
                stop.store(false, Ordering::Relaxed);
                continue;
            }
        }
    };

    // Restore the terminal first, then surface any error on a clean (cooked) tty.
    drop(_guard);
    if let Err(e) = &result {
        eprintln!("\nzuko: {e:#}");
    }

    // Force exit: the stdin reader thread is blocked on a blocking read and
    // would otherwise keep the process alive past the session end. The
    // RawModeGuard has already restored the terminal.
    std::process::exit(if result.is_ok() { 0 } else { 1 });
}

/// Read the WELCOME frame (the host's first frame), returning it, the
/// leftover accumulator (which may hold coalesced bytes from the same read),
/// and the recv stream for the caller to keep reading on.
async fn read_welcome(mut recv: RecvStream) -> Result<(Welcome, Vec<u8>, RecvStream)> {
    let mut acc: Vec<u8> = Vec::with_capacity(16 * 1024);
    let mut tmp = vec![0u8; 16 * 1024];
    let first = loop {
        if let Some(f) = try_parse_frame(&mut acc) {
            break f;
        }
        match recv.read(&mut tmp).await? {
            Some(n) => acc.extend_from_slice(&tmp[..n]),
            None => anyhow::bail!("stream closed before WELCOME"),
        }
    };
    if first.typ != TYPE_WELCOME {
        anyhow::bail!("expected WELCOME, got frame type {:#x}", first.typ);
    }
    let welcome = Welcome::decode(&first.payload)?;
    // `acc` still holds any bytes that arrived after WELCOME in the same read;
    // the read loop processes them. Hand recv back so the caller owns it.
    Ok((welcome, acc, recv))
}

/// Restore cooked terminal mode on scope exit (and on unwind/panic, since the
/// release profile keeps unwinding). Best-effort: errors are ignored.
struct RawModeGuard;
impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = crossterm::terminal::disable_raw_mode();
    }
}

fn pack_size(cols: u16, rows: u16) -> u32 {
    ((cols as u32) << 16) | (rows as u32)
}
fn unpack_size(packed: u32) -> (u16, u16) {
    ((packed >> 16) as u16, (packed & 0xFFFF) as u16)
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
