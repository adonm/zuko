//! `zuko connect` — attach a local terminal to a remote `zuko host`.
//!
//! The mirror image of [`crate::host`]: puts the local terminal into raw mode,
//! opens a bidi Iroh stream to the host, and shuttles bytes back and forth
//! using the shared [`crate::wire`] framing. `vim`, `htop`, tab completion, and
//! resize all work because the host runs a real PTY.
//!
//! ## Auto-resume (v0.6.13+)
//!
//! The CLI mirrors the iOS client's reconnect policy: on a transient drop
//! (network error, host unreachable, relay churn) it redials with bounded
//! exponential backoff and resends the host-issued session token so the host
//! reattaches the same PTY while its detached lease is alive. Clean shell exit
//! (host sends EOF) is **not** retried — the client exits normally. The 3×
//! Ctrl-C force-quit hatch remains the escape from a wedged-but-not-dead link.
//!
//! Auto-resume rides the host's existing short detached lease: there is still
//! no replay buffer, output while detached is still discarded, and a reconnect
//! after the lease expires (host restart, long outage) lands on a fresh PTY.
//! Users running long-lived work should still do so inside `tmux`/`zellij`/
//! `screen` on the host — that's the layer robust to host restarts.
//!
//! ## Stable per-(client, host) PTY
//!
//! The client keeps a persistent identity at `~/.config/zuko/client_key` and
//! derives a deterministic reattach token from (client key, host id). It sends
//! that token on the first ATTACH, so the host creates-or-reattaches **the
//! same PTY** for a given client+host — across auto-resumes *and* across fresh
//! `zuko <host>` invocations. Two terminals sharing the identity take over one
//! PTY (last attach wins; the previous one sees EOF and exits); use `tmux`/
//! `zellij` for independent shells. Legacy clients (no persistent key, iOS for
//! now) keep getting fresh PTYs per connect — unchanged behaviour.
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
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::time::Instant;
use tokio::io::AsyncWriteExt as _;
use tokio::sync::mpsc::{self, error::TrySendError};

use crate::wire::{
    ALPN_V2, SESSION_TOKEN_LEN, SessionToken, TYPE_ATTACHED, TYPE_DATA, TYPE_PING, TYPE_PONG,
    TYPE_RESIZE, attach_frame, decode_nonce, parse_attached, pong_frame, resize_frame,
    try_parse_frame,
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
    // Foreground iroh + zuko logs on stderr. Defaults mirror `zuko host`
    // (`zuko=info,iroh=warn`): warn keeps a healthy session quiet so raw-mode
    // terminal output isn't corrupted, while still surfacing real problems.
    // To see the dial in detail (relay/direct, QUIC handshake) when chasing a
    // stall, run:  RUST_LOG=iroh=info zuko <host>
    // (Log lines land on the raw terminal by design in that case — the cost of
    // opting into verbose output mid-session.)
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "zuko=info,iroh=warn".into()),
        )
        .init();

    let ticket = ticket_str
        .parse::<EndpointTicket>()
        .with_context(|| "that doesn't look like a ticket")?;
    let addr: EndpointAddr = ticket.into();

    // Persistent client identity (`~/.config/zuko/client_key`). A stable key
    // does two things: it gives the client a stable Iroh node id, and — more
    // importantly — it lets us derive a deterministic reattach token for this
    // (client, host) pair. Sending that token on the first ATTACH means the
    // host reuses the same PTY across reconnects *and* across fresh `zuko
    // <host>` invocations, instead of minting a new shell each time.
    let client_key = crate::secret::load_or_create_key(&client_key_path())
        .context("load client identity key")?;
    let initial_token = derive_session_token(&client_key, &addr);

    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    // Current terminal size, updated by SIGWINCH. Packed as cols<<16 | rows in
    // a u32 so the connect path can read it lock-free.
    let size: Arc<AtomicU32> = Arc::new(AtomicU32::new(pack_size(cols, rows)));

    // Connect *before* entering raw mode so connect errors print to a normal,
    // cooked terminal instead of a half-set-up raw one. Bind with an EPHEMERAL
    // secret: a unique NodeId per process. The persistent identity used to be
    // bound here too, but that gave every simultaneous `zuko connect` the SAME
    // Iroh NodeId — Iroh couldn't tell the streams apart and reply routing
    // cross-talked (duplicate/garbled output when running several clients at
    // once). Reattach doesn't need a stable NodeId: the host keys sessions by
    // the deterministic token derived above, not by NodeId.
    let endpoint = Endpoint::builder(presets::N0)
        .secret_key(iroh::SecretKey::generate())
        .bind()
        .await
        .context("bind local endpoint")?;

    crossterm::terminal::enable_raw_mode().context("enable raw mode")?;
    let _guard = RawModeGuard;

    // Outbound frame channel. stdin + SIGWINCH push pre-framed bytes here;
    // the writer task drains it into the send stream. Bounded so a flood
    // can't grow memory unbounded (the producer awaits, back-pressuring
    // stdin reads).
    let (frame_tx, mut frame_rx) = mpsc::channel::<Vec<u8>>(64);

    // Monotonic token bumped by the read loop whenever DATA is written to
    // stdout. The stdin thread samples it to detect "no remote output since
    // the previous Ctrl-C", which is the gate for the 3× Ctrl-C force-quit
    // hatch. Any remote output bumps this, which is exactly the "remote is
    // alive" signal we want to reset the burst.
    let stdout_seq: Arc<AtomicU64> = Arc::new(AtomicU64::new(0));
    let connected: Arc<AtomicBool> = Arc::new(AtomicBool::new(false));

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
    let connected_for_stdin = connected.clone();
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
                    // Force-quit accounting. We count 0x03 bytes; a paste of
                    // several is an intentional gesture and resolves the same
                    // way as mashing the key. This happens BEFORE enqueueing so
                    // a full/stalled network queue cannot block the escape
                    // hatch.
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
                    if !connected_for_stdin.load(Ordering::Acquire) {
                        // No stream is attached during dial/backoff. Do not
                        // buffer stale keystrokes and replay them into a later
                        // shell; the next ATTACH carries the latest size.
                        continue;
                    }
                    match stdin_tx.try_send(crate::wire::data_frame(&buf[..n])) {
                        Ok(()) => {}
                        Err(TrySendError::Full(_)) => {
                            // Prefer dropping impatient input under brownout to
                            // blocking this thread and losing the force-quit
                            // escape hatch.
                        }
                        Err(TrySendError::Closed(_)) => break,
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
        let connected_for_signal = connected.clone();
        tokio::spawn(async move {
            use tokio::signal::unix::{SignalKind, signal};
            let Ok(mut sig) = signal(SignalKind::window_change()) else {
                return;
            };
            while sig.recv().await.is_some() {
                if let Ok((c, r)) = crossterm::terminal::size() {
                    let (pw, ph) = terminal_pixels();
                    size_for_signal.store(pack_size(c, r), Ordering::Relaxed);
                    if !connected_for_signal.load(Ordering::Acquire) {
                        continue;
                    }
                    if resize_tx.send(resize_frame(c, r, pw, ph)).await.is_err() {
                        break;
                    }
                }
            }
        });
    }

    // Auto-resume loop: keep redialing transient drops until the remote shell
    // exits cleanly. The first attempt sends the client's stable derived token
    // (so the host creates-or-reattaches the same PTY for this client); the
    // host replies ATTACHED with the real token, which we resend on every
    // reconnect so the host reattaches the same PTY while its detached lease
    // is alive. Connect/open/ATTACH/write errors are treated as transient
    // (Dropped) and retried with backoff; only a clean recv EOF (shell exit)
    // ends the session. This mirrors the iOS client's reconnect policy.
    let mut token: SessionToken = initial_token;
    let mut backoff = ReconnectBackoff::new();
    let ctx = ConnCtx {
        endpoint: &endpoint,
        addr: &addr,
        size: &size,
        frame_tx: &frame_tx,
        stdout_seq: &stdout_seq,
        connected: &connected,
    };
    let result: Result<()> = loop {
        connected.store(false, Ordering::Release);
        match run_one_connection(&ctx, &mut token, &mut frame_rx, &mut backoff).await {
            Ok(ConnOutcome::ShellExited) => break Ok(()),
            Ok(ConnOutcome::Dropped) => {
                status_line(&format!(
                    "link lost — reconnecting in {:?} (Ctrl-C 3× to give up)",
                    backoff.next_delay()
                ));
                backoff.sleep().await;
                continue;
            }
            // A local fatal error (e.g. stdout write failed): stop retrying.
            Err(e) => break Err(e),
        }
    };

    // Restore the terminal first, then surface any error on a clean (cooked) tty.
    drop(_guard);
    if let Err(e) = &result {
        eprintln!("\nzuko: {e:#}");
    }

    // Close the endpoint gracefully so iroh can drain the connection to the
    // host. Dropping without this logs "Endpoint dropped without calling
    // `Endpoint::close`. Aborting ungracefully." and makes the host see an
    // abrupt close instead of a clean one. By this point the recv loop has
    // already seen the host's stream EOF (ShellExited) or hit a fatal local
    // error, so the connection is tearing down and this returns quickly.
    // Mirrors the close in handoff.rs; the force-quit (3× Ctrl-C) path still
    // skips this on purpose — it exits via process::exit, so drop never runs.
    endpoint.close().await;

    result
}

/// Outcome of one connect→pump attempt, driving the auto-resume loop.
enum ConnOutcome {
    /// Host closed the stream cleanly → remote shell exited. Stop retrying.
    ShellExited,
    /// Transient failure (dial/open/write/read error). Retry with backoff.
    Dropped,
}

/// Bounded exponential backoff between reconnect attempts. Mirrors the iOS
/// client: 1s base, doubling, capped at 15s. Reset to the base whenever a
/// connection reaches the live-pump phase (handshake bytes left the wire), so
/// a healthy link that blips doesn't inherit a huge delay from an earlier long
/// outage.
struct ReconnectBackoff {
    delay: std::time::Duration,
}

impl ReconnectBackoff {
    const BASE: std::time::Duration = std::time::Duration::from_secs(1);
    const MAX: std::time::Duration = std::time::Duration::from_secs(15);

    fn new() -> Self {
        Self { delay: Self::BASE }
    }

    /// Delay that will be slept on the next [`Self::sleep`].
    fn next_delay(&self) -> std::time::Duration {
        self.delay
    }

    async fn sleep(&mut self) {
        tokio::time::sleep(self.delay).await;
        self.delay = Self::next_after(self.delay);
    }

    fn reset(&mut self) {
        self.delay = Self::BASE;
    }

    /// Pure doubling step with the [`MAX`] cap. Extracted from [`sleep`] so the
    /// progression is unit-testable without a real timer.
    fn next_after(current: std::time::Duration) -> std::time::Duration {
        current.saturating_mul(2).min(Self::MAX)
    }
}

/// Shared, immutable handles one reconnect attempt reads through. Grouping
/// them keeps [`run_one_connection`]'s argument list short (clippy-clean) and
/// the auto-resume loop legible.
struct ConnCtx<'a> {
    endpoint: &'a Endpoint,
    addr: &'a EndpointAddr,
    size: &'a std::sync::atomic::AtomicU32,
    frame_tx: &'a mpsc::Sender<Vec<u8>>,
    stdout_seq: &'a std::sync::atomic::AtomicU64,
    connected: &'a std::sync::atomic::AtomicBool,
}

/// Open one connection, complete the ATTACH handshake, and pump both
/// directions until the connection ends. Updates `token` from the host's
/// ATTACHED reply so the next attempt reattaches the same PTY. Transient
/// failures return `Ok(Dropped)`; only a clean remote EOF returns
/// `Ok(ShellExited)`. A local stdout write failure (terminal gone) is fatal
/// and returns `Err`.
async fn run_one_connection(
    ctx: &ConnCtx<'_>,
    token: &mut SessionToken,
    frame_rx: &mut mpsc::Receiver<Vec<u8>>,
    backoff: &mut ReconnectBackoff,
) -> Result<ConnOutcome> {
    // Dial + open the bidi stream. Any failure here is transient: the host
    // may be down, roaming between relays, or the network briefly flaked.
    // `connect` consumes the EndpointAddr, so clone the borrowed handle —
    // dialing is cheap and we redo it on every reconnect.
    let (conn, protocol) = match connect_preferred(ctx.endpoint, ctx.addr).await {
        Some(p) => p,
        None => return Ok(ConnOutcome::Dropped),
    };
    let (mut send, mut recv) = match conn.open_bi().await {
        Ok(p) => p,
        Err(_) => return Ok(ConnOutcome::Dropped),
    };
    let mut control = if protocol == ALPN_V2 {
        match conn.open_bi().await {
            Ok((send, recv)) => Some((send, recv, Vec::with_capacity(1024), vec![0u8; 4096])),
            Err(_) => None,
        }
    } else {
        None
    };

    // Initial ATTACH — the current token (zero on first attach, the host's
    // issued token on reconnect). Sent on `send` before the pump starts so
    // it's guaranteed first on the wire.
    let (c, r) = unpack_size(ctx.size.load(Ordering::Relaxed));
    let (pw, ph) = terminal_pixels();
    if send
        .write_all(&attach_frame(*token, c, r, pw, ph))
        .await
        .is_err()
    {
        return Ok(ConnOutcome::Dropped);
    }
    // Handshake bytes are on the wire — this connection is live. Reset the
    // backoff so the next drop after a healthy stretch starts fresh.
    backoff.reset();
    let _active = ActiveConnection::new(ctx.connected);
    status_line("connected — Ctrl-C 3× to force-quit if it hangs");

    // Pump both directions concurrently. stdin/SIGWINCH frames drain into
    // `send`; recv frames parse into stdout / ATTACH-token capture / PONG
    // replies. Either side ending tears down this connection; the outer loop
    // decides whether to reconnect based on the outcome.
    let mut acc: Vec<u8> = Vec::with_capacity(16 * 1024);
    let mut tmp = vec![0u8; 16 * 1024];
    loop {
        tokio::select! {
            // outbound: stdin + SIGWINCH frames -> send stream
            frame = frame_rx.recv() => match frame {
                Some(bytes) => {
                    if protocol == ALPN_V2 && control_frame_type(&bytes).is_some() {
                        if let Some((control_send, _, _, _)) = control.as_mut() {
                            if control_send.write_all(&bytes).await.is_err() {
                                return Ok(ConnOutcome::Dropped);
                            }
                        } else if send.write_all(&bytes).await.is_err() {
                            return Ok(ConnOutcome::Dropped);
                        }
                    } else if send.write_all(&bytes).await.is_err() {
                        return Ok(ConnOutcome::Dropped);
                    }
                }
                None => {
                    // All frame producers gone (stdin closed + SIGWINCH task
                    // ended — effectively client teardown). Finish the send
                    // half and drain remaining output until the shell exits.
                    let _ = send.finish();
                    loop {
                        match recv.read(&mut tmp).await {
                            Ok(Some(n)) => {
                                acc.extend_from_slice(&tmp[..n]);
                                process_buffered_frames(
                                    &mut acc, token, ctx.stdout_seq, None,
                                )
                                .await?;
                            }
                            Ok(None) => return Ok(ConnOutcome::ShellExited),
                            Err(_) => return Ok(ConnOutcome::Dropped),
                        }
                    }
                }
            },
            // inbound: recv stream -> parse -> stdout / token / pong
            read = recv.read(&mut tmp) => match read {
                Ok(Some(n)) => {
                    acc.extend_from_slice(&tmp[..n]);
                    process_buffered_frames(&mut acc, token, ctx.stdout_seq, Some(ctx.frame_tx)).await?;
                }
                // Host closed the stream cleanly → remote shell exited.
                Ok(None) => return Ok(ConnOutcome::ShellExited),
                Err(_) => return Ok(ConnOutcome::Dropped),
            },
            read = async {
                if let Some((_, control_recv, _, control_tmp)) = control.as_mut() {
                    control_recv.read(control_tmp).await
                } else {
                    std::future::pending().await
                }
            }, if control.is_some() => match read {
                Ok(Some(n)) => {
                    if let Some((_, _, control_acc, control_tmp)) = control.as_mut() {
                        control_acc.extend_from_slice(&control_tmp[..n]);
                        process_buffered_frames(control_acc, token, ctx.stdout_seq, Some(ctx.frame_tx)).await?;
                    }
                }
                Ok(None) => control = None,
                Err(_) => return Ok(ConnOutcome::Dropped),
            },
        }
    }
}

async fn connect_preferred(
    endpoint: &Endpoint,
    addr: &EndpointAddr,
) -> Option<(iroh::endpoint::Connection, &'static [u8])> {
    endpoint
        .connect(addr.clone(), ALPN_V2)
        .await
        .ok()
        .map(|conn| (conn, ALPN_V2))
}

fn control_frame_type(frame: &[u8]) -> Option<u8> {
    let typ = *frame.first()?;
    matches!(typ, TYPE_RESIZE | TYPE_PING | TYPE_PONG).then_some(typ)
}

/// Parse and act on every complete frame currently buffered in `acc`. DATA
/// goes to stdout (fatal if stdout is gone); ATTACHED updates the reattach
/// token; PING is answered via `frame_tx` when given (omitted during the
/// post-stdin drain, when no producer remains). Unknown types are ignored —
/// the wire protocol is designed to gain types without breaking old peers.
async fn process_buffered_frames(
    acc: &mut Vec<u8>,
    token: &mut SessionToken,
    stdout_seq: &std::sync::atomic::AtomicU64,
    frame_tx: Option<&mpsc::Sender<Vec<u8>>>,
) -> Result<()> {
    while let Some(f) = try_parse_frame(acc) {
        match f.typ {
            TYPE_DATA => {
                let mut stdout = tokio::io::stdout();
                if stdout.write_all(&f.payload).await.is_err() || stdout.flush().await.is_err() {
                    anyhow::bail!("stdout write failed");
                }
                // Bump the force-quit token: any DATA the remote sent resets
                // the Ctrl-C burst (a responsive remote isn't "wedged").
                stdout_seq.fetch_add(1, Ordering::Relaxed);
            }
            // Host's reply to ATTACH: the token to resend on reconnect. On a
            // fresh attach this is a new token; on a reattach within the lease
            // it's the same one; if the lease expired, a new token (fresh PTY).
            TYPE_ATTACHED => {
                if let Some(t) = parse_attached(&f.payload) {
                    *token = t;
                }
            }
            TYPE_PING => {
                if let Some(reply) = control_reply_frame(f.typ, &f.payload)
                    && let Some(tx) = frame_tx
                {
                    let _ = tx.send(reply).await;
                }
            }
            _ => {}
        }
    }
    Ok(())
}

/// Restore cooked terminal mode on scope exit (and on unwind/panic, since the
/// release profile keeps unwinding). Best-effort: errors are ignored.
struct RawModeGuard;
impl Drop for RawModeGuard {
    fn drop(&mut self) {
        let _ = crossterm::terminal::disable_raw_mode();
    }
}

struct ActiveConnection<'a>(&'a AtomicBool);
impl<'a> ActiveConnection<'a> {
    fn new(flag: &'a AtomicBool) -> Self {
        flag.store(true, Ordering::Release);
        Self(flag)
    }
}
impl Drop for ActiveConnection<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

const fn pack_size(cols: u16, rows: u16) -> u32 {
    ((cols as u32) << 16) | (rows as u32)
}
const fn unpack_size(packed: u32) -> (u16, u16) {
    ((packed >> 16) as u16, (packed & 0xFFFF) as u16)
}

/// Read the local terminal's pixel dimensions via `TIOCGWINSZ`, so they can be
/// sent to the host (RESIZE/ATTACH) and set on the host PTY winsize — letting
/// a host-side `zuko app` render at the client terminal's real resolution.
/// Returns (0, 0) on terminals/PTys that don't report pixels.
#[cfg(unix)]
fn terminal_pixels() -> (u16, u16) {
    let mut winsz = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut winsz) };
    if rc == 0 {
        (winsz.ws_xpixel, winsz.ws_ypixel)
    } else {
        (0, 0)
    }
}

#[cfg(not(unix))]
fn terminal_pixels() -> (u16, u16) {
    (0, 0)
}

/// `~/.config/zuko/client_key` (follows `XDG_CONFIG_HOME`). The client's
/// persistent identity — distinct from the host's `key` so a machine that is
/// both host and client keeps the two roles independent.
pub fn client_key_path() -> std::path::PathBuf {
    let mut p = crate::config_dir();
    p.push("zuko");
    p.push("client_key");
    p
}

/// Derive a stable 16-byte reattach token for this (client, host) pair.
///
/// Mixing in the host's public key (`addr.id`) makes the token per-host, so
/// the same client gets a different — but equally stable — token on every
/// host it reaches, and the token is useless on any other host's registry.
/// Hashing (rather than sending raw key bytes) keeps key material off the wire
/// even though the stream is already end-to-end encrypted.
///
/// The result is non-zero for any real secret (SHA-256's first 16 bytes being
/// all zero is a ~2^-128 impossibility), which is required because the host
/// rejects empty authorisation tokens.
pub fn derive_session_token(secret: &iroh::SecretKey, addr: &EndpointAddr) -> SessionToken {
    use sha2::{Digest, Sha256};
    let mut hasher = Sha256::new();
    hasher.update(b"zuko-session-token-v1");
    hasher.update(secret.to_bytes());
    hasher.update(addr.id.as_bytes());
    let out = hasher.finalize();
    let mut tok = [0u8; SESSION_TOKEN_LEN];
    tok.copy_from_slice(&out[..SESSION_TOKEN_LEN]);
    tok
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
    use std::time::Duration;

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
    fn replies_to_ping_control_frame() {
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

    #[test]
    fn v2_routes_resize_and_ping_to_control_stream() {
        assert_eq!(
            control_frame_type(&crate::wire::resize_frame(80, 24, 0, 0)),
            Some(TYPE_RESIZE)
        );
        assert_eq!(
            control_frame_type(&crate::wire::ping_frame(1)),
            Some(TYPE_PING)
        );
        assert_eq!(
            control_frame_type(&crate::wire::pong_frame(1)),
            Some(TYPE_PONG)
        );
        assert_eq!(control_frame_type(&crate::wire::data_frame(b"x")), None);
        assert_eq!(control_frame_type(&[]), None);
    }

    // ── auto-resume backoff ──

    #[test]
    fn backoff_doubles_then_caps_at_max() {
        // 1s → 2s → 4s → 8s → 15s (cap) → 15s … mirrors the iOS client.
        let mut d = ReconnectBackoff::BASE;
        assert_eq!(d, Duration::from_secs(1));
        d = ReconnectBackoff::next_after(d);
        assert_eq!(d, Duration::from_secs(2));
        d = ReconnectBackoff::next_after(d);
        assert_eq!(d, Duration::from_secs(4));
        d = ReconnectBackoff::next_after(d);
        assert_eq!(d, Duration::from_secs(8));
        d = ReconnectBackoff::next_after(d);
        assert_eq!(d, ReconnectBackoff::MAX);
        assert_eq!(d, Duration::from_secs(15));
        // Once at the cap it stays there — never grows past MAX even over many
        // retries (a long host outage must not push the delay to minutes).
        for _ in 0..100 {
            d = ReconnectBackoff::next_after(d);
            assert_eq!(d, ReconnectBackoff::MAX);
        }
    }

    #[test]
    fn backoff_starts_at_base_and_resets() {
        let mut b = ReconnectBackoff::new();
        assert_eq!(b.next_delay(), ReconnectBackoff::BASE);
        // Simulate the delay bump sleep performs (without actually sleeping).
        b.delay = ReconnectBackoff::next_after(b.delay);
        assert_eq!(b.next_delay(), Duration::from_secs(2));
        // reset() returns to the base — a healthy connection that later blips
        // starts the next backoff from 1s, not the elevated delay.
        b.reset();
        assert_eq!(b.next_delay(), ReconnectBackoff::BASE);
    }

    // ── ATTACH token capture (the core reattach mechanic) ──

    #[tokio::test]
    async fn attached_frame_updates_reattach_token() {
        // The host replies ATTACHED with the active token. The reconnect loop
        // must capture it so the next dial reattaches the same PTY.
        let issued = [7u8; SESSION_TOKEN_LEN];
        let mut acc = crate::wire::attached_frame(issued);
        let mut token = [0u8; SESSION_TOKEN_LEN];
        let stdout_seq = AtomicU64::new(0);
        // ATTACHED-only buffer: no DATA, so nothing is written to stdout.
        process_buffered_frames(&mut acc, &mut token, &stdout_seq, None)
            .await
            .unwrap();
        assert_eq!(token, issued, "client must adopt the host-issued token");
        // Buffer fully drained.
        assert!(acc.is_empty());
    }

    #[tokio::test]
    async fn unknown_frame_type_is_ignored_without_overwriting_token() {
        // Forward-compat: an unknown frame must be silently skipped and must
        // NOT clobber the reattach token.
        let mut acc = Vec::new();
        acc.extend(crate::wire::frame(0xEE, b"junk"));
        let mut token = [9u8; SESSION_TOKEN_LEN];
        let stdout_seq = AtomicU64::new(0);
        process_buffered_frames(&mut acc, &mut token, &stdout_seq, None)
            .await
            .unwrap();
        assert_eq!(token, [9u8; SESSION_TOKEN_LEN]);
        assert!(acc.is_empty());
    }

    // ── stable per-(client,host) reattach token ──

    #[test]
    fn derived_token_is_stable_and_nonzero() {
        // The whole point: a client always lands on the same host PTY because
        // it derives the same token for a given (client, host) every time.
        let client = iroh::SecretKey::generate();
        let addr = EndpointAddr::new(iroh::SecretKey::generate().public());
        let t1 = derive_session_token(&client, &addr);
        let t2 = derive_session_token(&client, &addr);
        assert_eq!(t1, t2, "same (client,host) must derive the same token");
        assert!(
            !crate::wire::empty_session_token(&t1),
            "must never be the all-zero invalid authorisation token"
        );
    }

    #[test]
    fn derived_token_differs_across_hosts_and_clients() {
        let client1 = iroh::SecretKey::generate();
        let client2 = iroh::SecretKey::generate();
        let addr_a = EndpointAddr::new(iroh::SecretKey::generate().public());
        let addr_b = EndpointAddr::new(iroh::SecretKey::generate().public());
        // Same client, different host → different token (so each host keeps
        // its own PTY for this client).
        assert_ne!(
            derive_session_token(&client1, &addr_a),
            derive_session_token(&client1, &addr_b)
        );
        // Different client, same host → different token (so two clients on one
        // host don't collide on each other's PTY).
        assert_ne!(
            derive_session_token(&client1, &addr_a),
            derive_session_token(&client2, &addr_a)
        );
    }
}
