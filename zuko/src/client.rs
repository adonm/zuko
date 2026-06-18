//! `zuko connect` — attach a local terminal to a remote `zuko host`.
//!
//! The mirror image of [`crate::host`]: puts the local terminal into raw mode,
//! opens a bidi Iroh stream to the host, and shuttles bytes back and forth using
//! the shared [`crate::wire`] framing. `vim`, `htop`, tab completion, and resize
//! all work because the host runs a real PTY.

use anyhow::{Context, Result};
use iroh::endpoint::{RecvStream, SendStream};
use iroh::{Endpoint, EndpointAddr, endpoint::presets};
use iroh_tickets::endpoint::EndpointTicket;
use tokio::io::AsyncWriteExt as _;
use tokio::sync::mpsc;

use crate::wire::{data_frame, resize_frame, try_parse_frame, TYPE_DATA};

const ALPN: &[u8] = b"zuko/1";

/// Connect to a host and bridge the local terminal to its shell until the
/// session ends (remote shell exit or connection drop).
pub async fn connect(ticket_str: &str) -> Result<()> {
    let ticket = ticket_str
        .parse::<EndpointTicket>()
        .with_context(|| "that doesn't look like a ticket")?;
    let addr: EndpointAddr = ticket.into();

    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));

    // Connect *before* entering raw mode so connect errors print to a normal,
    // cooked terminal instead of a half-set-up raw one.
    let endpoint = Endpoint::builder(presets::N0)
        .bind()
        .await
        .context("bind local endpoint")?;
    let conn = endpoint
        .connect(addr, ALPN)
        .await
        .context("connect to host")?;
    let (mut send, recv) = conn.open_bi().await.context("open stream")?;

    // The opener must write before the host's accept_bi resolves, so send an
    // initial resize right away (the host spawns the PTY at this size; the real
    // size is corrected on the first SIGWINCH).
    send.write_all(&resize_frame(cols, rows))
        .await
        .context("send initial resize")?;

    crossterm::terminal::enable_raw_mode().context("enable raw mode")?;
    let _guard = RawModeGuard;

    let result = run_session(send, recv).await;

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

/// Restore cooked terminal mode on scope exit (and on unwind/panic, since the
/// release profile keeps unwinding). Best-effort: errors are ignored.
struct RawModeGuard;
impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = crossterm::terminal::disable_raw_mode();
    }
}

async fn run_session(mut send: SendStream, mut recv: RecvStream) -> Result<()> {
    // One writer owns the send stream, fed by a frame channel that both the
    // stdin pump and the resize watcher push into. Serialising writes here
    // guarantees keystroke and resize frames never interleave on the wire.
    let (frame_tx, mut frame_rx) = mpsc::channel::<Vec<u8>>(64);

    // stdin -> DATA frames. Blocking reads live on a dedicated OS thread; EOF
    // (Ctrl-D) ends the producer. Bytes are forwarded verbatim so the remote
    // shell sees exactly what a local shell would (Ctrl-C is the byte 0x03, etc).
    let stdin_tx = frame_tx.clone();
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin();
        let mut buf = vec![0u8; 4096];
        loop {
            match std::io::Read::read(&mut stdin, &mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if stdin_tx.blocking_send(data_frame(&buf[..n])).is_err() {
                        break;
                    }
                }
            }
        }
    });

    // SIGWINCH (terminal resize) -> RESIZE frames.
    #[cfg(unix)]
    {
        let resize_tx = frame_tx.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{signal, SignalKind};
            let Ok(mut sig) = signal(SignalKind::window_change()) else {
                return;
            };
            while sig.recv().await.is_some() {
                if let Ok((cols, rows)) = crossterm::terminal::size() {
                    if resize_tx.send(resize_frame(cols, rows)).await.is_err() {
                        break;
                    }
                }
            }
        });
    }

    let writer = tokio::spawn(async move {
        while let Some(frame) = frame_rx.recv().await {
            if send.write_all(&frame).await.is_err() {
                break;
            }
        }
        let _ = send.finish();
    });

    // net -> stdout. The session ends when the host closes the stream (the
    // remote shell exited) or the connection drops.
    let mut stdout = tokio::io::stdout();
    let mut acc: Vec<u8> = Vec::with_capacity(16 * 1024);
    let mut tmp = vec![0u8; 16 * 1024];
    loop {
        match recv.read(&mut tmp).await {
            Ok(Some(n)) => {
                acc.extend_from_slice(&tmp[..n]);
                while let Some(frame) = try_parse_frame(&mut acc) {
                    if frame.typ == TYPE_DATA {
                        if stdout.write_all(&frame.payload).await.is_err() {
                            break;
                        }
                        let _ = stdout.flush().await;
                    }
                }
            }
            Ok(None) => break,
            Err(_) => break,
        }
    }

    // Drop the writer; it will see the channel close and finish the send side.
    writer.abort();
    Ok(())
}
