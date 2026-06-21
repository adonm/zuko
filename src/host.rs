//! `zuko host` — serve this machine's shell over Iroh.
//!
//! Binds an Iroh endpoint with a persistent secret key, writes its dialable
//! ticket to `~/.config/zuko/current_ticket` (read out-of-band by
//! `zuko share`), and for each incoming connection either spawns the user's
//! shell on a PTY (new session) or resumes an existing one (session resume,
//! v0.4).
//!
//! ## Session persistence (the mosh model, mapped onto zuko)
//!
//! A session is a PTY + shell + a bounded ring buffer of recent output. It
//! **outlives the connection**: when a connection drops the host *detaches*
//! (stops feeding that connection's send stream) but keeps the PTY reader
//! running and the ring buffer filling. A client that reconnects with the
//! session id gets the ring buffer replayed, then live output — the shell's
//! state (cwd, running command, editor) is preserved across network blips and
//! even across app restarts within the session's lifetime.
//!
//! Sessions are reaped when their shell exits (PTY EOF). Detached sessions are
//! kept **indefinitely** — a client can resume days later — so the host never
//! auto-reaps on idle. The trade-off is memory: an abandoned `vim` will sit
//! forever until the operator intervenes. The escape hatch is `zuko reap`,
//! which talks to the host's control socket
//! (`~/.config/zuko/control.sock`, see [`crate::control`]) and asks it to kill
//! any session idle for over the given threshold (default 1 hour), sparing the
//! session the command is run from (detected via `$ZUKO_SESSION_ID`, which the
//! host sets on every spawned shell).
//!
//! ## Why we don't need a server-side terminal emulator
//!
//! mosh runs the terminal emulator on the server so it can send screen *state*
//! on resume. zuko replays raw *bytes* from the ring buffer instead. For
//! line-oriented output that's clean; for full-screen apps (`vim`, `htop`) the
//! replay may leave the screen mid-redraw, but the client re-sends its current
//! size on resume → the host resizes the PTY → the app gets `SIGWINCH` and
//! redraws. Good enough without a Tier-4 state-sync rewrite.

use anyhow::{Context, Result};
use iroh::{endpoint::presets, Endpoint, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::{Mutex as AsyncMutex, Notify};
use tracing::{info, warn};

use crate::config_dir;
use crate::control::{control_socket_path, hex_id, parse_session_id_hex};
use crate::secret::write_secret_0600;
use crate::ticket_file::write_current_ticket;
use crate::wire::{
    self, decode_nonce, try_parse_frame, Hello, SessionId, Welcome, ALPN, FLAG_HEARTBEAT,
    FLAG_RESUME, FLAG_RESUMED, TYPE_DATA, TYPE_HELLO, TYPE_PING, TYPE_RESIZE,
};
use crate::HostArgs;

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;

/// Per-direction capacity of the bounded channels that connect the network
/// pump to the PTY (and back). Bounds host memory under flood — without it a
/// client pasting/flooding faster than the shell drains stdin, or a shell
/// emitting faster than the network ships, would grow the heap without limit.
/// Saturation back-pressures the right way: the producer awaits, QUIC flow
/// control chokes the peer, and on the output side the kernel TTY buffer
/// eventually blocks the shell's own writes. At the wire-max 64 KiB frame
/// payload this is an ~8 MiB worst-case ceiling per direction; typical
/// keystroke frames are a few bytes, so it never throttles normal use.
const PUMP_CHANNEL_CAP: usize = 128;

/// Ring buffer of recent PTY output, replayed on session resume. ~1 MiB is
/// ~1000 screenfuls — enough to recover meaningful scrollback during an outage
/// without being an unbounded heap liability per session.
const RING_BUFFER_BYTES: usize = 1024 * 1024;

/// How often the auto-reaper sweeps the registry. With no time-based reaping
/// (sessions live forever — see [`spawn_reaper`]) the sweep's only job is to
/// catch shell-exited sessions that [`serve`] somehow didn't clean up itself
/// (defensive; cheap).
const REAPER_INTERVAL: std::time::Duration = std::time::Duration::from_mins(1);

/// Heartbeat interval. The host sends a PING every interval; a PONG (or any
/// frame) resets the client's stall timer. iroh's QUIC keepalive (5 s) already
/// keeps the transport alive — this is an app-level liveness signal so the
/// client can surface a "stalled" state faster than the 15–30 s QUIC idle
/// timeout and trigger a prompt reconnect.
const HEARTBEAT_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);

#[derive(Debug)]
enum PtyCmd {
    Data(Vec<u8>),
    Resize(u16, u16),
}

/// Why a connection's network read half ended, driving whether the session
/// survives (network drop → detach + keep for resume) or is torn down (shell
/// exited → reap).
enum ConnEnd {
    /// The network read half hit EOF or errored — connection dropped. Detach,
    /// keep the session alive for resume + grace-period reaping.
    Detached,
    /// The shell exited (PTY reader saw EOF) — the session is genuinely done;
    /// tear it down and remove it from the registry.
    ShellExited,
}

/// What the PTY→network pump should write to the iroh send stream. PTY bytes
/// get wrapped in a `DATA` frame; control frames (`PING`/`PONG`) are already
/// framed and pass through verbatim. Routing both through one channel keeps a
/// single writer on the send stream so frames never interleave.
enum OutItem {
    /// Raw PTY output — the pump wraps it in a `DATA` frame.
    Pty(Vec<u8>),
    /// An already-framed control frame (`PING`/`PONG`) — written as-is.
    Frame(Vec<u8>),
}

/// Run the host: bind, print a ticket, accept connections forever.
pub async fn run(args: HostArgs) -> Result<()> {
    // The host logs to stderr only. stdout stays empty so a future caller
    // that captures it never gets a long-lived bearer secret mixed in with
    // status output — the ticket is read out of band (via the
    // `~/.config/zuko/current_ticket` file) by `zuko share`.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "zuko=info,iroh=warn".into()),
        )
        .init();

    let key_path = args.key.unwrap_or_else(default_key_path);
    let secret = load_or_create_key(&key_path)?;

    let shell = if args.shell == "$SHELL" {
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string())
    } else {
        args.shell
    };

    let endpoint = Endpoint::builder(presets::N0)
        .secret_key(secret)
        // Advertise our ALPN so the endpoint accepts (and the QUIC handshake's
        // ALPN negotiation succeeds). Without this, `Endpoint::accept` filters
        // out every connection and clients fail with "peer doesn't support any
        // known protocol".
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await
        .context("bind endpoint")?;
    endpoint.online().await;

    // Stable node id (derived from the persisted key) + a copy-pasteable
    // ticket. The ticket is a long-lived bearer secret (anyone holding it gets
    // a shell), so it is **never** printed — not to stdout, not to stderr.
    // The host operator pairs other devices with `zuko share` (an OTP-style
    // code that expires in minutes); there is no other CLI path that exposes
    // the raw ticket, by design.
    let node_id = endpoint.id();
    let ticket_str = EndpointTicket::new(endpoint.addr()).to_string();

    eprintln!();
    eprintln!("zuko host ready");
    eprintln!("  node id: {node_id}");
    eprintln!("  to pair another device, run on this machine:");
    eprintln!("    zuko share");
    eprintln!("  then on the other machine:");
    eprintln!("    zuko claim <code>");
    eprintln!();
    info!(%node_id, "listening on alpn {:?}", String::from_utf8_lossy(ALPN));

    // Publish the live ticket so `zuko share` can hand it off without an IPC
    // channel to this daemon. The ticket encodes current addresses, which can
    // drift (relay re-home), so refresh it periodically from `endpoint.addr()`.
    // Best-effort: a failed write is logged but never fatal — shells still work.
    if let Err(e) = write_current_ticket(&ticket_str) {
        warn!("could not write current ticket: {e:#}");
    }
    let ep = endpoint.clone();
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(std::time::Duration::from_secs(30));
        // The first tick() fires immediately; we already wrote once above, so
        // drain it and then rewrite on each subsequent tick.
        tick.tick().await;
        loop {
            tick.tick().await;
            let t = EndpointTicket::new(ep.addr()).to_string();
            if let Err(e) = write_current_ticket(&t) {
                warn!("could not refresh current ticket: {e:#}");
            }
        }
    });

    // The session registry, shared across every connection task. A session
    // outlives its connections (see the module docs); the registry is the
    // anchor that keeps detached-session PTY reader tasks alive.
    let sessions: SessionRegistry = Arc::new(AsyncMutex::new(HashMap::new()));
    spawn_reaper(sessions.clone());
    spawn_control_listener(sessions.clone());

    // Accept connections forever. Each connection attaches to a session (new
    // or resumed); the session persists after the connection ends.
    loop {
        if let Some(incoming) = endpoint.accept().await {
            let shell = shell.clone();
            let shell_args = args.shell_args.clone();
            let cwd = args.cwd.clone();
            let sessions = sessions.clone();
            tokio::spawn(async move {
                if let Err(e) = serve(incoming, shell, shell_args, cwd, sessions).await {
                    warn!("connection ended: {e:#}");
                }
            });
        } else {
            info!("endpoint stopped accepting");
            break;
        }
    }
    // Best-effort: remove the control socket so a stale path doesn't sit at
    // `control_socket_path()` for the next start to clean up. We unlink on
    // bind too, so a clean shutdown isn't load-bearing — but it's tidy.
    let _ = std::fs::remove_file(control_socket_path());
    Ok(())
}

type SessionRegistry = Arc<AsyncMutex<HashMap<SessionId, Arc<Session>>>>;

/// A live session: PTY + shell + ring buffer, outliving any single connection.
///
/// The PTY reader thread (started in [`Session::spawn`]) runs for the
/// session's whole life: it appends to [`ring`] and, if a connection is
/// currently attached (a sender in [`attached_tx`]), fans the chunk out to it.
/// When no connection is attached the chunk is just buffered — the session
/// keeps "running" in the background, ready to resume.
struct Session {
    id: SessionId,
    /// Feeds the PTY writer thread (keystrokes + resizes). One per session,
    /// shared across reconnects — a resumed connection pushes into the same
    /// channel as the original.
    pty_tx: tokio::sync::mpsc::Sender<PtyCmd>,
    /// Recent output. The PTY reader appends; on attach we snapshot + replay.
    ring: Arc<RingBuffer>,
    /// The currently-attached connection's outbound sender. `None` when
    /// detached. The PTY reader clones this under the lock per chunk and sends
    /// outside the lock (so a slow network never blocks the reader's lock
    /// hold). Replacing it (a new connection resumes) drops the previous
    /// sender — its `pty_to_net` task then sees a closed channel and exits,
    /// which is the desired "roam" semantics (new connection takes over).
    attached_tx: Arc<std::sync::Mutex<Option<tokio::sync::mpsc::Sender<OutItem>>>>,
    /// Notifies the (unused-while-detached) wait path that a client attached.
    /// Kept for future use; the reader thread currently just drops chunks when
    /// `attached_tx` is None (the ring already has them).
    #[allow(dead_code)]
    attach_notify: Notify,
    /// Set when the PTY reader saw EOF (the shell exited). The reaper uses
    /// this to remove the session immediately rather than waiting for grace.
    exited: Arc<std::sync::atomic::AtomicBool>,
    /// Fired when the PTY reader sees EOF, so the attached connection's
    /// `pty_to_net` task can drain + close the send stream — that's how the
    /// client learns the shell exited (recv EOF → `ShellExited` → stop,
    /// rather than reconnecting a dead session).
    exited_notify: Arc<Notify>,
    /// Last time the session saw activity — updated on attach, on every PTY
    /// output chunk, and on every inbound client frame. Used by `zuko reap`
    /// (via the control socket) to find idle sessions. The auto-reaper never
    /// reaps on this — sessions live forever unless the shell exits.
    last_activity: Arc<std::sync::Mutex<std::time::Instant>>,
    /// The child shell, for explicit kill on reap. portable-pty `Child` is a
    /// trait; `spawn_command` returns `Box<dyn Child + Send + Sync>`. Its Drop
    /// isn't guaranteed to wait across backends, so we kill+wait explicitly.
    child: Arc<std::sync::Mutex<Option<Box<dyn portable_pty::Child + Send + Sync>>>>,
}

impl Session {
    /// Create a session: spawn the PTY + shell, start the PTY-reader thread
    /// (appends to the ring + fans out to an attached connection), and start
    /// the PTY-writer thread (consumes from `pty_tx`).
    fn spawn(
        shell: String,
        shell_args: Vec<String>,
        cwd: Option<PathBuf>,
        cols: u16,
        rows: u16,
    ) -> Result<Arc<Self>> {
        // Mint the session id up front so we can expose it to the spawned shell
        // via `$ZUKO_SESSION_ID` — `zuko reap` reads this to spare the session
        // it's running in. `rand::random` gives 8 fresh bytes.
        let id: SessionId = rand::random();
        let id_hex = hex_id(&id);

        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty")?;

        let mut cmd = CommandBuilder::new(&shell);
        cmd.args(&shell_args);
        cmd.env("TERM", "xterm-256color");
        cmd.env("ZUKO_SESSION_ID", &id_hex);
        if let Some(dir) = cwd.as_deref() {
            cmd.cwd(dir);
        }
        let child = pair.slave.spawn_command(cmd).context("spawn shell")?;
        // Drop the slave so that EOF propagates to the master reader when the
        // shell exits.
        drop(pair.slave);

        let reader = pair.master.try_clone_reader().context("clone reader")?;
        let master = pair.master;

        let (pty_tx, mut pty_rx) = tokio::sync::mpsc::channel::<PtyCmd>(PUMP_CHANNEL_CAP);

        // Single thread owns the PTY writer + resize, fed by a bounded channel
        // from the network pump. Keeps all writes to the PTY serialised; the
        // bound (see `PUMP_CHANNEL_CAP`) caps memory if a client floods DATA
        // frames faster than the shell reads stdin — once saturated, the
        // `net_to_pty` task awaits on `send`, stops reading the recv stream,
        // and QUIC flow control back-pressures the peer.
        let master_for_writer = master;
        std::thread::spawn(move || {
            let Ok(mut writer) = master_for_writer.take_writer() else {
                return;
            };
            // `blocking_recv` parks this dedicated OS thread without a tokio
            // runtime context (it panics inside an async task, but this is a
            // plain `std::thread::spawn` thread). The producer side `await`s
            // the tokio `Sender`, which is what yields the backpressure.
            while let Some(cmd) = pty_rx.blocking_recv() {
                match cmd {
                    PtyCmd::Data(d) => {
                        if writer.write_all(&d).is_err() {
                            break;
                        }
                    }
                    PtyCmd::Resize(cols, rows) => {
                        let _ = master_for_writer.resize(PtySize {
                            cols,
                            rows,
                            pixel_width: 0,
                            pixel_height: 0,
                        });
                    }
                }
            }
        });

        let ring = Arc::new(RingBuffer::new(RING_BUFFER_BYTES));
        let exited = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let exited_notify = Arc::new(Notify::new());
        let child = Arc::new(std::sync::Mutex::new(Some(child)));
        let attached_tx: Arc<std::sync::Mutex<Option<tokio::sync::mpsc::Sender<OutItem>>>> =
            Arc::new(std::sync::Mutex::new(None));
        let last_activity: Arc<std::sync::Mutex<std::time::Instant>> =
            Arc::new(std::sync::Mutex::new(std::time::Instant::now()));

        // PTY reader -> (ring + attached connection). Runs for the session's
        // whole life: even with no connection attached it keeps buffering, so
        // a resume replays output that arrived during the outage. The sender
        // slot is cloned out under the lock per chunk and the send happens
        // *outside* the lock — so a slow/stuck network never blocks the reader
        // (it'll error on a dropped receiver, which we treat as detach).
        let ring_for_reader = ring.clone();
        let exited_for_reader = exited.clone();
        let exited_notify_for_reader = exited_notify.clone();
        let attached_for_reader = attached_tx.clone();
        let last_activity_for_reader = last_activity.clone();
        std::thread::spawn(move || {
            let mut reader = reader;
            let mut buf = vec![0u8; 16 * 1024];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let chunk = buf[..n].to_vec();
                        ring_for_reader.append(&chunk);
                        // PTY output counts as session activity (so a session
                        // producing output stays on the right side of `zuko
                        // reap`'s idle threshold). The mutex hold is trivial
                        // — just an Instant write — so unthrottled is fine.
                        if let Ok(mut t) = last_activity_for_reader.lock() {
                            *t = std::time::Instant::now();
                        }
                        // Clone the sender under the lock (quick), send
                        // outside the lock. If the send errors the receiver is
                        // gone — clear the slot so we stop trying (the ring
                        // already holds the chunk, so no data loss).
                        let tx = {
                            let guard = attached_for_reader
                                .lock()
                                .expect("attached_tx lock poisoned");
                            guard.clone()
                        };
                        if let Some(tx) = tx
                            && tx.blocking_send(OutItem::Pty(chunk)).is_err()
                                && let Ok(mut g) = attached_for_reader.lock() {
                                    *g = None;
                                }
                        // No tx: chunk is dropped (ring has it). The reader
                        // keeps running — that's the whole point of detach.
                    }
                }
            }
            exited_for_reader.store(true, std::sync::atomic::Ordering::Relaxed);
            // Wake the attached connection's `pty_to_net` so it closes the
            // send stream → the client sees EOF → stops (shell exited, not a
            // network drop to reconnect).
            exited_notify_for_reader.notify_one();
        });

        Ok(Arc::new(Self {
            id,
            pty_tx,
            ring,
            attached_tx,
            attach_notify: Notify::new(),
            exited,
            exited_notify,
            last_activity,
            child,
        }))
    }

    /// Install `tx` as the live fan-out sender for new PTY output. Replaces
    /// any previous sender (roam). The previous connection's `pty_to_net` task
    /// observes its sender dropped and exits. A new attachment counts as
    /// activity, so this also bumps `last_activity`.
    fn attach(&self, tx: tokio::sync::mpsc::Sender<OutItem>) {
        let mut guard = self.attached_tx.lock().expect("attached_tx lock poisoned");
        *guard = Some(tx);
        if let Ok(mut t) = self.last_activity.lock() {
            *t = std::time::Instant::now();
        }
    }

    /// Stop fanning output to any connection. The PTY reader keeps running and
    /// buffering into the ring.
    fn detach(&self) {
        let mut guard = self.attached_tx.lock().expect("attached_tx lock poisoned");
        *guard = None;
    }

    /// Mark the session as having just seen activity (a frame from the client,
    /// a resume, etc). Called by the net→PTY pump on every frame. The auto-
    /// reaper never reads this; `zuko reap` (via the control socket) does.
    fn touch_activity(&self) {
        if let Ok(mut t) = self.last_activity.lock() {
            *t = std::time::Instant::now();
        }
    }

    /// Idle duration: how long since this session last saw activity (a client
    /// frame, an attach, or PTY output). `None` if the lock is contended (the
    /// caller treats that as "not idle" — same as the auto-reaper's `try_lock`
    /// pattern).
    fn idle(&self) -> Option<std::time::Duration> {
        self.last_activity.lock().ok().map(|t| t.elapsed())
    }
}

/// A bounded ring buffer of recent bytes. Appends drop from the front when
/// over capacity. Snapshots start at the first newline (so replay doesn't
/// begin mid-ANSI-sequence for line-oriented output; full-screen apps are
/// fixed by the resume RESIZE → SIGWINCH redraw).
struct RingBuffer {
    cap: usize,
    buf: std::sync::Mutex<std::collections::VecDeque<u8>>,
}

impl RingBuffer {
    fn new(cap: usize) -> Self {
        Self {
            cap,
            buf: std::sync::Mutex::new(std::collections::VecDeque::with_capacity(cap)),
        }
    }

    fn append(&self, data: &[u8]) {
        let mut guard = self.buf.lock().expect("ring lock poisoned");
        guard.extend(data.iter().copied());
        let overflow = guard.len().saturating_sub(self.cap);
        if overflow > 0 {
            guard.drain(..overflow);
        }
    }

    fn snapshot(&self) -> Vec<u8> {
        let guard = self.buf.lock().expect("ring lock poisoned");
        // Start at the first newline so line-oriented replay is clean. If
        // there's no newline, replay the whole buffer (the resume RESIZE will
        // fix full-screen apps regardless).
        let start = guard
            .iter()
            .position(|&b| b == b'\n')
            .map_or(0, |i| i + 1);
        guard.iter().copied().skip(start).collect()
    }
}

async fn serve(
    incoming: iroh::endpoint::Incoming,
    shell: String,
    shell_args: Vec<String>,
    cwd: Option<PathBuf>,
    sessions: SessionRegistry,
) -> Result<()> {
    let conn = incoming
        .accept()
        .context("accept connection")?
        .await
        .context("complete connection")?;
    let (mut send, mut recv) = conn.accept_bi().await.context("accept bidi stream")?;

    // ── Handshake: read the client's first frame. ──
    // A v0.4 client sends HELLO (caps + initial size + optional resume id).
    // A v0.3 client sends a bare RESIZE; we treat that as a legacy new-session
    // handshake at the carried size and skip WELCOME (it'd ignore it anyway).
    let mut acc: Vec<u8> = Vec::with_capacity(16 * 1024);
    let mut tmp = vec![0u8; 16 * 1024];
    let first = read_one_frame(&mut recv, &mut acc, &mut tmp).await?;

    let (cols, rows, resume_id): (u16, u16, Option<SessionId>) = match first.typ {
        TYPE_HELLO => {
            let hello = Hello::decode(&first.payload)?;
            (hello.cols.max(1), hello.rows.max(1), hello.session_id)
        }
        TYPE_RESIZE if first.payload.len() == 4 => {
            let cols = u16::from_be_bytes([first.payload[0], first.payload[1]]);
            let rows = u16::from_be_bytes([first.payload[2], first.payload[3]]);
            (cols.max(1), rows.max(1), None)
        }
        // Anything else: legacy client. Feed the frame back into the parser so
        // the net→PTY pump sees it (it might be the first DATA bytes).
        _ => (DEFAULT_COLS, DEFAULT_ROWS, None),
    };

    // ── Resolve the session: resume an existing one or spawn a fresh one. ──
    let host_caps = FLAG_RESUME | FLAG_HEARTBEAT;
    let (session, resumed) = if let Some(id) = resume_id {
        let registry = sessions.lock().await;
        match registry.get(&id) {
            Some(s) if !s.exited.load(std::sync::atomic::Ordering::Relaxed) => {
                let s = s.clone();
                drop(registry);
                (s, true)
            }
            _ => {
                // Unknown or exited id → mint a fresh session (don't reuse the
                // id; the client adopts the new one from WELCOME).
                let s = Session::spawn(shell, shell_args, cwd, cols, rows)?;
                (s, false)
            }
        }
    } else {
        let s = Session::spawn(shell, shell_args, cwd, cols, rows)?;
        (s, false)
    };

    // Register the session (it may already be there on resume; overwrite with
    // the same Arc, and on a fresh spawn insert under its new id).
    {
        let mut registry = sessions.lock().await;
        registry.insert(session.id, session.clone());
    }

    // ── Reply WELCOME (only for HELLO-speaking clients). ──
    if first.typ == TYPE_HELLO {
        let welcome = Welcome {
            flags: host_caps | if resumed { FLAG_RESUMED } else { 0 },
            session_id: Some(session.id),
        };
        send.write_all(&welcome.frame())
            .await
            .context("send WELCOME")?;
    }

    // ── Attach: replay the ring buffer, then install the live fan-out. ──
    if resumed {
        let snapshot = session.ring.snapshot();
        if !snapshot.is_empty() {
            send.write_all(&wire::data_frame(&snapshot))
                .await
                .context("replay ring buffer")?;
        }
    }
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<OutItem>(PUMP_CHANNEL_CAP);
    // Clones for the heartbeat task (PINGs) and the net→PTY task (PONGs).
    // mpsc senders are cheap clones; all three feed the single `pty_to_net`
    // writer, so frames never interleave on the wire.
    let ping_tx = out_tx.clone();
    let pong_tx = out_tx.clone();
    session.attach(out_tx);

    // PTY output (via the session's fan-out) + control frames -> network.
    // Drains the out channel; ends when all senders are dropped (detach) or
    // the send errors (connection dropped). Also listens for the shell-exited
    // notify: when the PTY reader sees EOF it fires, we drain any remaining
    // output, then `send.finish()` so the client sees EOF and stops (rather
    // than reconnecting a dead session).
    let exited_notify = session.exited_notify.clone();
    let pty_to_net = tokio::spawn(async move {
        loop {
            tokio::select! {
                biased;
                () = exited_notify.notified() => {
                    // Shell exited: flush any buffered output, then close.
                    while let Ok(item) = out_rx.try_recv() {
                        let frame = match item {
                            OutItem::Pty(bytes) => wire::data_frame(&bytes),
                            OutItem::Frame(pre) => pre,
                        };
                        if send.write_all(&frame).await.is_err() {
                            break;
                        }
                    }
                    break;
                }
                item = out_rx.recv() => {
                    let Some(item) = item else { break; };
                    let frame = match item {
                        OutItem::Pty(bytes) => wire::data_frame(&bytes),
                        OutItem::Frame(pre) => pre,
                    };
                    if send.write_all(&frame).await.is_err() {
                        break;
                    }
                }
            }
        }
        let _ = send.finish();
    });

    // Network -> PTY. Async frame parser over the iroh recv stream. The first
    // frame was already consumed above; `acc` may still hold buffered bytes
    // from a coalesced read, so the pump continues from `acc`/`tmp`. PONGs for
    // inbound PINGs are routed back via `pong_tx`. Real user input (DATA,
    // RESIZE) bumps `last_activity` so `zuko reap` sees an active session;
    // PINGs and PONGs deliberately don't, or a connected-but-ignored session
    // would never look idle.
    let pty_tx = session.pty_tx.clone();
    let session_for_net = session.clone();
    let net_to_pty: tokio::task::JoinHandle<ConnEnd> = tokio::spawn(async move {
        loop {
            // Parse any bytes already in `acc` first (from the handshake
            // read), then top up from the stream.
            while let Some(frame) = try_parse_frame(&mut acc) {
                if !handle_client_frame(&frame, &pty_tx, &pong_tx).await {
                    // pty_tx closed → session reaped; connection done.
                    return ConnEnd::ShellExited;
                }
                if frame.typ == TYPE_DATA || frame.typ == TYPE_RESIZE {
                    session_for_net.touch_activity();
                }
            }
            match recv.read(&mut tmp).await {
                Ok(Some(n)) => acc.extend_from_slice(&tmp[..n]),
                // Client closed send half / dropped / errored: same outcome.
                Ok(None) | Err(_) => return ConnEnd::Detached,
            }
        }
    });

    // Host-side heartbeat: send a PING every interval. Cheap (8-byte frame),
    // rides the same send stream as PTY output (so it shares ordering — fine,
    // it's tiny), and gives the client a liveness signal to PONG. A
    // non-heartbeat client ignores PING as an unknown type; the cost is
    // negligible so we send unconditionally.
    let heartbeat = tokio::spawn(async move {
        let mut interval = tokio::time::interval(HEARTBEAT_INTERVAL);
        let mut nonce: u64 = 0;
        loop {
            interval.tick().await;
            nonce = nonce.wrapping_add(1);
            if ping_tx
                .send(OutItem::Frame(wire::ping_frame(nonce)))
                .await
                .is_err()
            {
                break; // connection gone; stop heartbeating
            }
        }
    });

    // Wait for the network side to end. The PTY→net side ends on its own when
    // `out_rx` closes (all senders dropped on detach), the send errors, or the
    // shell-exited notify fires (it then drains + finishes the send stream).
    let end = net_to_pty.await.unwrap_or(ConnEnd::Detached);

    // Tear down this connection's attachment. The session itself stays (for
    // resume — sessions are kept indefinitely; see `zuko reap` for explicit
    // cleanup) unless the shell exited.
    session.detach();
    session.touch_activity();
    pty_to_net.abort();
    heartbeat.abort();

    let shell_gone = session.exited.load(std::sync::atomic::Ordering::Relaxed)
        || matches!(end, ConnEnd::ShellExited);
    if shell_gone {
        // The shell is gone (PTY EOF) or the session was reaped elsewhere.
        // Remove it from the registry and kill+reap the child explicitly.
        let mut registry = sessions.lock().await;
        registry.remove(&session.id);
        drop(registry);
        reap_session(&session);
    }
    // else: network drop — keep the session; the PTY reader keeps buffering
    // into the ring for a later resume, and the reaper handles grace expiry.
    Ok(())
}

/// Handle one frame from the client. Returns `false` if the session's PTY
/// writer is gone (session reaped) and the connection should end. `pong_tx`
/// routes PONGs (replies to our PINGs) back out the send stream.
async fn handle_client_frame(
    frame: &wire::ParsedFrame,
    pty_tx: &tokio::sync::mpsc::Sender<PtyCmd>,
    pong_tx: &tokio::sync::mpsc::Sender<OutItem>,
) -> bool {
    match frame.typ {
        TYPE_DATA => {
            // Verbose byte trace for input diagnostics. Enable with
            // RUST_LOG=zuko=debug. Reads as: byte values in hex, ASCII in
            // brackets where printable. Lets us verify LF→CR normalisation
            // on the client and diagnose any other input quirks without
            // needing to instrument the iOS side.
            tracing::debug!(
                target: "zuko::host::input",
                bytes = ?frame.payload.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>(),
                ascii = %String::from_utf8_lossy(&frame.payload),
                "client DATA frame"
            );
            if pty_tx
                .send(PtyCmd::Data(frame.payload.clone()))
                .await
                .is_err()
            {
                return false;
            }
            true
        }
        TYPE_RESIZE if frame.payload.len() == 4 => {
            let cols = u16::from_be_bytes([frame.payload[0], frame.payload[1]]);
            let rows = u16::from_be_bytes([frame.payload[2], frame.payload[3]]);
            let _ = pty_tx.send(PtyCmd::Resize(cols, rows)).await;
            true
        }
        TYPE_PING => {
            // Echo the nonce back as PONG, routed through the out channel so
            // the single writer puts it on the wire.
            let nonce = decode_nonce(&frame.payload);
            let _ = pong_tx.send(OutItem::Frame(wire::pong_frame(nonce))).await;
            true
        }
        _ => true, // ignore unknown types (forward compat — PONG, WELCOME, etc.)
    }
}

/// Read exactly one complete frame, blocking on the stream until one arrives.
/// `acc` accumulates bytes across reads (a frame may be split or coalesced);
/// `tmp` is the read scratch buffer.
async fn read_one_frame(
    recv: &mut iroh::endpoint::RecvStream,
    acc: &mut Vec<u8>,
    tmp: &mut [u8],
) -> Result<wire::ParsedFrame> {
    loop {
        if let Some(f) = try_parse_frame(acc) {
            return Ok(f);
        }
        match recv.read(tmp).await? {
            Some(n) => acc.extend_from_slice(&tmp[..n]),
            None => anyhow::bail!("stream closed before a complete frame arrived"),
        }
    }
}

/// Kill + reap the child, remove the session from the registry. Best-effort:
/// the shell may already be gone (ESRCH from `kill`).
fn reap_session(session: &Arc<Session>) {
    if let Ok(mut guard) = session.child.lock() {
        if let Some(child) = guard.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        *guard = None;
    }
}

/// Periodically reap sessions whose shell has exited but that [`serve`] didn't
/// clean up itself (e.g. if the connection task was cancelled mid-detach). The
/// sweep is defensive — sessions are otherwise kept indefinitely (the mosh
/// "live until killed" model), with [`crate::control`] / `zuko reap` as the
/// operator-facing cleanup path. Cheap: a 60 s tick iterating the registry.
fn spawn_reaper(sessions: SessionRegistry) {
    tokio::spawn(async move {
        let mut tick = tokio::time::interval(REAPER_INTERVAL);
        tick.tick().await; // drain the immediate first tick
        loop {
            tick.tick().await;
            let mut to_reap: Vec<SessionId> = Vec::new();
            {
                let registry = sessions.lock().await;
                for (id, session) in registry.iter() {
                    if session.exited.load(std::sync::atomic::Ordering::Relaxed) {
                        to_reap.push(*id);
                    }
                    // No time-based reaping — sessions live forever until the
                    // shell exits or `zuko reap` is run.
                }
            }
            for id in &to_reap {
                let session = {
                    let mut registry = sessions.lock().await;
                    registry.remove(id)
                };
                if let Some(session) = session {
                    reap_session(&session);
                    info!(session = hex_id(id), "reaped exited session");
                }
            }
        }
    });
}

/// Bind the host's control socket and serve [`crate::control`] requests on a
/// dedicated OS thread per connection. Plain `std::thread` (not tokio) is
/// deliberate: the work is blocking I/O (a line read, a registry sweep, a
/// few lines back), the connection rate is operator-paced (a couple per day
/// at most), and using `blocking_lock` on the `AsyncMutex` registry from
/// outside the async runtime keeps the handler code boring.
///
/// Failures to bind are logged and swallowed — a missing control socket only
/// means `zuko reap` won't work; shells still serve. A stale socket from a
/// crashed previous host is unlinked before bind (standard Unix-socket
/// hygiene).
fn spawn_control_listener(sessions: SessionRegistry) {
    std::thread::spawn(move || {
        let path = control_socket_path();
        // Stale socket from a previous crashed host — otherwise `bind` fails
        // with EADDRINUSE and the operator's `zuko reap` can never connect.
        let _ = std::fs::remove_file(&path);
        if let Some(parent) = path.parent()
            && let Err(e) = std::fs::create_dir_all(parent) {
                warn!("control socket: mkdir {}: {e:#}", parent.display());
                return;
            }
        let listener = match std::os::unix::net::UnixListener::bind(&path) {
            Ok(l) => l,
            Err(e) => {
                warn!(
                    "could not bind control socket at {} — `zuko reap` won't work ({e:#})",
                    path.display()
                );
                return;
            }
        };
        info!(path = %path.display(), "control socket listening");
        for stream in listener.incoming() {
            let Ok(stream) = stream else {
                warn!("control socket: accept failed, stopping listener");
                break;
            };
            // Each request is tiny and operator-paced; a thread per connection
            // is the simplest correct shape. `std::thread` keeps us off the
            // tokio runtime entirely (see the doc comment above).
            let sessions = sessions.clone();
            std::thread::spawn(move || {
                if let Err(e) = handle_control_conn(stream, sessions) {
                    warn!("control socket request failed: {e:#}");
                }
            });
        }
        // Listener exhausted (rare: only on socket teardown). Clean up so the
        // next start binds cleanly.
        let _ = std::fs::remove_file(&path);
    });
}

/// One control connection: read one request line, dispatch, write the reply.
/// The request format is documented in [`crate::control`].
fn handle_control_conn(
    stream: std::os::unix::net::UnixStream,
    sessions: SessionRegistry,
) -> Result<()> {
    use std::io::{BufRead, BufReader, Write};
    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    reader
        .read_line(&mut line)
        .context("read control request line")?;
    let resp = handle_control_line(line.trim(), &sessions);
    (&stream)
        .write_all(resp.as_bytes())
        .context("write control response")?;
    Ok(())
}

/// Build the response string for one parsed control request. Pure (no I/O)
/// so it can be unit-tested; the actual reap happens via [`reap_idle`].
fn handle_control_line(line: &str, sessions: &SessionRegistry) -> String {
    let parts: Vec<&str> = line.split_whitespace().collect();
    if parts.len() < 3 || parts.first() != Some(&"REAP") {
        return format!("ERROR expected 'REAP <secs> <skip|none>', got {line:?}\n");
    }
    let secs: u64 = match parts[1].parse() {
        Ok(s) => s,
        Err(_) => return format!("ERROR bad secs value: {:?}\n", parts[1]),
    };
    let skip: Option<SessionId> = if parts[2] == "none" {
        None
    } else {
        match parse_session_id_hex(parts[2]) {
            Some(id) => Some(id),
            None => return format!("ERROR bad skip session id: {:?}\n", parts[2]),
        }
    };
    let reaped = reap_idle(sessions, std::time::Duration::from_secs(secs), skip);
    use std::fmt::Write;
    let mut out = String::new();
    for id in &reaped {
        let _ = writeln!(out, "REAPED {}", hex_id(id));
    }
    let _ = writeln!(out, "DONE {}", reaped.len());
    out
}

/// Reap every session idle longer than `threshold`, sparing `skip` (the
/// session the `zuko reap` CLI is running inside, if any). Returns the ids
/// that were killed, in the order they were reaped. Synchronous + blocking —
/// only call from the control-socket handler thread.
fn reap_idle(
    sessions: &SessionRegistry,
    threshold: std::time::Duration,
    skip: Option<SessionId>,
) -> Vec<SessionId> {
    // First pass: collect candidates under a short hold of the registry lock.
    let mut to_reap: Vec<SessionId> = Vec::new();
    {
        let registry = sessions.blocking_lock();
        for (id, session) in registry.iter() {
            if Some(*id) == skip {
                continue;
            }
            // An exited session is always a candidate regardless of activity —
            // it's already dead, just hasn't been cleaned up yet.
            let exited = session.exited.load(std::sync::atomic::Ordering::Relaxed);
            let idle_too_long = session.idle().is_some_and(|d| d > threshold);
            if exited || idle_too_long {
                to_reap.push(*id);
            }
        }
    }
    // Second pass: actually remove + kill each one. Done outside the registry
    // lock so the (potentially blocking) child kill doesn't hold it.
    for id in &to_reap {
        let session = {
            let mut registry = sessions.blocking_lock();
            registry.remove(id)
        };
        if let Some(session) = session {
            reap_session(&session);
            info!(
                session = hex_id(id),
                "reaped idle session via control socket"
            );
        }
    }
    to_reap
}

fn default_key_path() -> PathBuf {
    let mut p = config_dir();
    p.push("zuko");
    p.push("key");
    p
}

fn load_or_create_key(path: &PathBuf) -> Result<SecretKey> {
    // Race-safe create-or-read for the host's persistent identity. Two `zuko
    // host` processes starting at the same instant on a fresh install (e.g.
    // the just-installed service plus a manual `zuko host`) would otherwise
    // both generate a different key and the second write would clobber the
    // first, silently flipping the node id under any host saved in between.
    //
    // We hold an exclusive flock on a sibling `.lock` file across the
    // check-create-write transaction, mirroring the pattern `store::HostsLock`
    // uses for the hosts file. The lock is on a separate inode so the atomic
    // 0600 temp+rename can't orphan it (and so it's safe to leave on disk).
    let _guard = KeyLock::acquire(path)?;

    if path.exists() {
        return read_key(path);
    }

    // We're the sole creator (any concurrent caller is blocked on the flock
    // above). Generate, write atomically through the shared 0600 writer so a
    // crash mid-write can never leave a truncated file the next start would
    // then reject as "not 32 bytes" (silently invalidating every saved
    // connection).
    let secret = SecretKey::generate();
    write_secret_0600(path, &secret.to_bytes())?;
    Ok(secret)
}

fn read_key(path: &PathBuf) -> Result<SecretKey> {
    let bytes = std::fs::read(path).with_context(|| format!("read key {}", path.display()))?;
    if bytes.len() != 32 {
        anyhow::bail!("key file {} is not 32 bytes", path.display());
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(&bytes);
    Ok(SecretKey::from_bytes(&arr))
}

/// Cross-process advisory lock guarding the read-or-create transaction in
/// [`load_or_create_key`]. Lives at `<key>.lock` (a separate path so the
/// atomic `key` temp+rename never orphans the lock inode), held until the
/// guard is dropped. Mirrors `store::HostsLock`.
struct KeyLock(std::fs::File);

impl KeyLock {
    fn acquire(key_path: &std::path::Path) -> Result<Self> {
        let lock_path = key_path.with_extension("lock");
        if let Some(parent) = lock_path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("mkdir {}", parent.display()))?;
        }
        let f = std::fs::OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .with_context(|| format!("open {}", lock_path.display()))?;
        fs4::fs_std::FileExt::lock_exclusive(&f)?;
        Ok(Self(f))
    }
}

impl Drop for KeyLock {
    fn drop(&mut self) {
        let _ = fs4::fs_std::FileExt::unlock(&self.0);
    }
}

// `TYPE_HEARTBEAT` isn't a real frame type — it's a capability flag. No
// stray import to suppress here.

#[cfg(test)]
mod tests {
    use super::*;

    // Two concurrent `load_or_create_key` calls on a fresh path must converge
    // on the *same* key — `create_new` is the gatekeeper, so the loser reads
    // the winner's bytes back. Without the race-safety this test would fail
    // intermittently with mismatched `to_bytes()` (and on a real host, a
    // silent node-id flip under any saved connection).
    #[test]
    fn concurrent_creates_converge_on_one_key() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");

        // Spawn N threads racing on the same fresh path. Each call returns
        // either the key it created or the key it read after losing the
        // race — either way, all callers must observe the same 32 bytes.
        const N: usize = 8;
        let path = std::sync::Arc::new(path);
        let keys: Vec<[u8; 32]> = (0..N)
            .map(|_| {
                let p = std::sync::Arc::clone(&path);
                std::thread::spawn(move || load_or_create_key(&p).unwrap().to_bytes())
            })
            .collect::<Vec<_>>()
            .into_iter()
            .map(|h| h.join().unwrap())
            .collect();

        // Every observed key must be identical.
        let first = keys[0];
        for (i, k) in keys.iter().enumerate() {
            assert_eq!(k, &first, "thread {i} observed a different key");
        }

        // The on-disk key must match what the callers observed.
        let on_disk = std::fs::read(&*path).unwrap();
        assert_eq!(
            &on_disk[..],
            &first[..],
            "on-disk key diverges from in-memory"
        );

        // Calling again on the existing file must read back the same key
        // (sanity check the read path).
        let again = load_or_create_key(&path).unwrap().to_bytes();
        assert_eq!(again, first);
    }

    #[cfg(unix)]
    #[test]
    fn created_key_file_is_0600() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("key");
        let _ = load_or_create_key(&path).unwrap();
        let perms = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(
            perms & 0o777,
            0o600,
            "key file must be 0600, got {perms:o}"
        );
    }

    // Ring buffer: append + cap eviction + newline-aligned snapshot.
    #[test]
    fn ring_buffer_evicts_oldest_and_snapshots_from_newline() {
        let ring = RingBuffer::new(16);
        ring.append(b"hello\nworld\n");
        // Over-fill: the front is dropped.
        ring.append(b"0123456789ABCDEFXXXX");
        let snap = ring.snapshot();
        // Snapshot starts after the first newline still present in the buffer.
        // The exact bytes depend on eviction; assert it's bounded + non-empty
        // + starts mid-buffer (no "hello").
        assert!(snap.len() <= 16 + 4);
        assert!(!snap.starts_with(b"hello"));
    }

    #[test]
    fn ring_buffer_empty_snapshot() {
        let ring = RingBuffer::new(1024);
        assert!(ring.snapshot().is_empty());
    }

    // ── control-socket request parsing ──
    //
    // The error paths of `handle_control_line` don't need real sessions (the
    // request fails validation before the registry is inspected), so an empty
    // registry is enough. The success path requires a real `Session` (PTY +
    // child + reader thread) and is covered end-to-end by `tests/e2e.rs`.

    fn empty_registry() -> SessionRegistry {
        Arc::new(AsyncMutex::new(HashMap::new()))
    }

    #[test]
    fn control_line_rejects_unknown_verb() {
        let r = empty_registry();
        let resp = handle_control_line("LIST", &r);
        assert!(resp.starts_with("ERROR "), "got: {resp:?}");
    }

    #[test]
    fn control_line_rejects_missing_args() {
        let r = empty_registry();
        let resp = handle_control_line("REAP 60", &r);
        assert!(resp.starts_with("ERROR "), "got: {resp:?}");
    }

    #[test]
    fn control_line_rejects_non_numeric_secs() {
        let r = empty_registry();
        let resp = handle_control_line("REAP soon none", &r);
        assert!(resp.contains("ERROR bad secs"), "got: {resp:?}");
    }

    #[test]
    fn control_line_rejects_bad_skip_id() {
        let r = empty_registry();
        let resp = handle_control_line("REAP 60 nothex", &r);
        assert!(resp.contains("ERROR bad skip session id"), "got: {resp:?}");
    }

    #[test]
    fn control_line_reap_on_empty_registry_returns_done_zero() {
        // No sessions = nothing to reap, even with a valid request.
        let r = empty_registry();
        let resp = handle_control_line("REAP 3600 none", &r);
        assert!(resp.contains("DONE 0"), "got: {resp:?}");
        assert!(!resp.contains("REAPED"));
    }
}
