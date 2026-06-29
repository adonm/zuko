//! `zuko host` — serve this machine's shell over Iroh.
//!
//! Binds an Iroh endpoint with a persistent secret key, writes its dialable
//! ticket to `~/.config/zuko/current_ticket` (read out-of-band by
//! `zuko share`), and for each incoming connection spawns the user's shell on
//! a PTY. The connection owns the PTY: when it ends (for any reason — shell
//! exit, or a short detached lease expires after a client/network drop.
//!
//! ## Short detached leases
//!
//! Earlier versions kept replay buffers and durable-ish session registries. The
//! current host keeps only an in-memory 5-minute lease: if a client reconnects
//! with its 16-byte token, it gets the same PTY; output while detached is
//! discarded. There is no replay buffer or cross-restart persistence. Users who
//! want robust resumability still run `tmux`/`zellij`/`screen` inside zuko.

use anyhow::{Context, Result};
use iroh::{Endpoint, SecretKey, endpoint::presets};
use iroh_tickets::endpoint::EndpointTicket;
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::Duration;
use tracing::{info, warn};

use crate::HostArgs;
use crate::config_dir;
use crate::secret;
use crate::ticket_file::write_current_ticket;
use crate::wire::{
    self, ALPN, SESSION_TOKEN_LEN, SessionToken, TYPE_ATTACH, TYPE_DATA, TYPE_PING, TYPE_RESIZE,
    decode_nonce, empty_session_token, parse_attach, try_parse_frame,
};

/// Per-direction capacity of the bounded channels that connect the network
/// pump to the PTY (and back). Bounds host memory under flood — without it a
/// client pasting/flooding faster than the shell drains stdin, or a shell
/// emitting faster than the network ships, would grow the heap without limit.
/// Saturation back-pressures the right way: the producer awaits, QUIC flow
/// control chokes the peer, and on the output side the kernel TTY buffer
/// eventually blocks the shell's own writes.
const PUMP_CHANNEL_CAP: usize = 128;
/// Bound half-open clients that connect but never open/send a zuko stream.
/// This keeps the host's per-connection task/thread budget predictable without
/// adding a separate accept limiter.
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
/// How long a PTY stays alive after its client disappears. Five minutes covers
/// normal mobile backgrounding, lock-screen auth, Wi‑Fi/cellular handover, and
/// brief tunnel/relay churn without letting abandoned shells linger for hours.
/// Output while detached is discarded.
const DETACHED_SESSION_TTL: Duration = Duration::from_secs(300);

type SessionRegistry = Arc<tokio::sync::Mutex<HashMap<SessionToken, Arc<Session>>>>;

/// The client terminal's size, relayed through ATTACH/RESIZE. Carried end to
/// end so a host-side `zuko app` can render at the client's real pixel size.
#[derive(Clone, Copy, Debug)]
struct TermSize {
    cols: u16,
    rows: u16,
    pixel_width: u16,
    pixel_height: u16,
}

#[derive(Debug)]
enum PtyCmd {
    Data(Vec<u8>),
    /// Full terminal size (cells + pixels). Pixels are 0 from clients/terminals
    /// that don't report them; a host-side `zuko app` then falls back.
    Resize(TermSize),
}

/// What the PTY→network pump should write to the iroh send stream. PTY bytes
/// get wrapped in a `DATA` frame; control frames (`PING`/`PONG`) are already
/// framed and pass through verbatim. Routing both through one channel keeps a
/// single writer on the send stream so frames never interleave.
enum OutItem {
    /// Raw PTY output — the pump wraps it in a `DATA` frame.
    Pty(Vec<u8>),
    /// An already-framed control frame (PONG replies to client PINGs) —
    /// written as-is.
    Frame(Vec<u8>),
    /// PTY reader hit EOF (shell exited). Drain any earlier output, then finish
    /// the send stream so the client exits instead of waiting for more input.
    End,
}

struct Attachment {
    id: u64,
    tx: tokio::sync::mpsc::Sender<OutItem>,
}

struct Session {
    token: SessionToken,
    pty_tx: tokio::sync::mpsc::Sender<PtyCmd>,
    child: Arc<std::sync::Mutex<Option<Box<dyn portable_pty::Child + Send + Sync>>>>,
    attachment: std::sync::Mutex<Option<Attachment>>,
    next_attach_id: AtomicU64,
    lease_generation: AtomicU64,
    exited: AtomicBool,
}

impl Session {
    fn attach(&self, tx: tokio::sync::mpsc::Sender<OutItem>) -> u64 {
        let id = self.next_attach_id.fetch_add(1, Ordering::Relaxed) + 1;
        let old = {
            let mut guard = self.attachment.lock().expect("attachment mutex poisoned");
            guard.replace(Attachment { id, tx })
        };
        if let Some(old) = old {
            let _ = old.tx.try_send(OutItem::End);
        }
        id
    }

    fn detach(&self, id: u64) -> Option<u64> {
        let mut guard = self.attachment.lock().expect("attachment mutex poisoned");
        if guard.as_ref().is_some_and(|a| a.id == id) {
            *guard = None;
            Some(self.lease_generation.fetch_add(1, Ordering::Relaxed) + 1)
        } else {
            None
        }
    }

    fn send_output(&self, bytes: Vec<u8>) {
        let tx = self
            .attachment
            .lock()
            .expect("attachment mutex poisoned")
            .as_ref()
            .map(|a| a.tx.clone());
        if let Some(tx) = tx {
            // No replay buffer: if the client is gone or badly stalled, drop
            // output and let the app/user request a redraw after reattach.
            let _ = tx.try_send(OutItem::Pty(bytes));
        }
    }

    fn mark_exited(&self) {
        self.exited.store(true, Ordering::Relaxed);
        let tx = self
            .attachment
            .lock()
            .expect("attachment mutex poisoned")
            .as_ref()
            .map(|a| a.tx.clone());
        if let Some(tx) = tx {
            let _ = tx.try_send(OutItem::End);
        }
    }

    fn active(&self, id: u64) -> bool {
        self.attachment
            .lock()
            .expect("attachment mutex poisoned")
            .as_ref()
            .is_some_and(|a| a.id == id)
    }

    fn should_reap(&self, generation: u64) -> bool {
        self.exited.load(Ordering::Relaxed)
            || (self.lease_generation.load(Ordering::Relaxed) == generation
                && self
                    .attachment
                    .lock()
                    .expect("attachment mutex poisoned")
                    .is_none())
    }

    fn kill(&self) {
        if let Ok(mut guard) = self.child.lock() {
            if let Some(child) = guard.as_mut() {
                let _ = child.kill();
                let _ = child.wait();
            }
            *guard = None;
        }
    }
}

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;

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
    let secret = secret::load_or_create_key(&key_path)?;

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

    // Accept connections forever. Each first connection creates a PTY-backed
    // session token; short client drops can reattach to that token within the
    // detached lease window.
    let sessions: SessionRegistry = Arc::new(tokio::sync::Mutex::new(HashMap::new()));
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
    Ok(())
}

/// Serve one connection: read the first frame for initial size, spawn a PTY,
/// pump bytes both ways until either side ends, then kill the PTY.
async fn serve(
    incoming: iroh::endpoint::Incoming,
    shell: String,
    shell_args: Vec<String>,
    cwd: Option<PathBuf>,
    sessions: SessionRegistry,
) -> Result<()> {
    let connecting = incoming.accept().context("accept connection")?;
    let conn = tokio::time::timeout(HANDSHAKE_TIMEOUT, connecting)
        .await
        .context("timed out completing connection")?
        .context("complete connection")?;
    let (mut send, mut recv) = tokio::time::timeout(HANDSHAKE_TIMEOUT, conn.accept_bi())
        .await
        .context("timed out waiting for bidi stream")?
        .context("accept bidi stream")?;

    // ── Handshake: read the client's first frame. ──
    // The client sends a single `RESIZE` carrying the initial terminal size.
    // Anything else (e.g. a stale v0.4–v0.5 `HELLO`): ignore and default to
    // 80×24; the client's first subsequent `RESIZE` corrects it.
    let mut acc: Vec<u8> = Vec::with_capacity(16 * 1024);
    let mut tmp = vec![0u8; 16 * 1024];
    let first = tokio::time::timeout(
        HANDSHAKE_TIMEOUT,
        read_one_frame(&mut recv, &mut acc, &mut tmp),
    )
    .await
    .context("timed out waiting for initial frame")??;
    let request = initial_request(first);
    let session = get_or_create_session(
        &sessions,
        request.requested_token,
        shell,
        shell_args,
        cwd,
        TermSize {
            cols: request.cols,
            rows: request.rows,
            pixel_width: request.pixel_width,
            pixel_height: request.pixel_height,
        },
    )
    .await?;

    // Outbound channel: PTY output + PONG replies to client PINGs all funnel
    // through here so the single `pty_to_net` writer puts frames on the wire
    // in order without interleaving. zuko doesn't run an app-level heartbeat;
    // Iroh/QUIC owns transport liveness. PING/PONG is just cheap peer
    // compatibility for clients that still send protocol control frames.
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<OutItem>(PUMP_CHANNEL_CAP);
    let pong_tx = out_tx.clone();
    let attach_id = session.attach(out_tx);
    let token = session.token;

    // PTY output (via the out channel) + control frames -> network.
    // Ends when all senders are dropped (reader thread done) or the send
    // errors (connection dropped).
    let mut pty_to_net = tokio::spawn(async move {
        if send.write_all(&wire::attached_frame(token)).await.is_err() {
            return;
        }
        while let Some(item) = out_rx.recv().await {
            let frame = match item {
                OutItem::Pty(bytes) => wire::data_frame(&bytes),
                OutItem::Frame(pre) => pre,
                OutItem::End => break,
            };
            if send.write_all(&frame).await.is_err() {
                break;
            }
        }
        let _ = send.finish();
    });

    // Network -> PTY. Async frame parser over the iroh recv stream. The first
    // frame was already consumed above; `acc` may still hold buffered bytes
    // from a coalesced read, so the pump continues from `acc`/`tmp`. PONGs
    // for inbound PINGs are routed back via `pong_tx`.
    let session_for_input = session.clone();
    let mut net_to_pty: tokio::task::JoinHandle<()> = tokio::spawn(async move {
        if let Some(frame) = request.pending_first
            && !handle_client_frame(&frame, &session_for_input, attach_id, &pong_tx).await
        {
            return;
        }
        loop {
            // Parse any bytes already in `acc` first (from the handshake
            // read), then top up from the stream.
            while let Some(frame) = try_parse_frame(&mut acc) {
                if !handle_client_frame(&frame, &session_for_input, attach_id, &pong_tx).await {
                    return;
                }
            }
            match recv.read(&mut tmp).await {
                Ok(Some(n)) => acc.extend_from_slice(&tmp[..n]),
                // Client closed send half / dropped / errored: same outcome.
                Ok(None) | Err(_) => return,
            }
        }
    });

    // No host-side heartbeat — see note on out_tx above.

    // End this attachment when either side ends: client/network EOF, replaced
    // attachment, or PTY EOF (shell exit). The PTY itself survives a network
    // drop for DETACHED_SESSION_TTL unless it exited.
    tokio::select! {
        _ = &mut net_to_pty => pty_to_net.abort(),
        _ = &mut pty_to_net => net_to_pty.abort(),
    }

    if session.exited.load(Ordering::Relaxed) {
        sessions.lock().await.remove(&session.token);
        session.kill();
    } else if let Some(generation) = session.detach(attach_id) {
        schedule_reap(sessions, session, generation);
    }
    Ok(())
}

/// Handle one frame from the client. Returns `false` if the session's PTY
/// writer is gone and the connection should end. `pong_tx` routes PONGs
/// (replies to client PINGs) back out the send stream.
async fn handle_client_frame(
    frame: &wire::ParsedFrame,
    session: &Session,
    attach_id: u64,
    pong_tx: &tokio::sync::mpsc::Sender<OutItem>,
) -> bool {
    if !session.active(attach_id) {
        return false;
    }
    match frame.typ {
        TYPE_DATA => {
            if session
                .pty_tx
                .send(PtyCmd::Data(frame.payload.clone()))
                .await
                .is_err()
            {
                return false;
            }
            true
        }
        TYPE_RESIZE if frame.payload.len() == 8 => {
            let cols = u16::from_be_bytes([frame.payload[0], frame.payload[1]]);
            let rows = u16::from_be_bytes([frame.payload[2], frame.payload[3]]);
            let pixel_width = u16::from_be_bytes([frame.payload[4], frame.payload[5]]);
            let pixel_height = u16::from_be_bytes([frame.payload[6], frame.payload[7]]);
            let _ = session
                .pty_tx
                .send(PtyCmd::Resize(TermSize {
                    cols: cols.max(1),
                    rows: rows.max(1),
                    pixel_width,
                    pixel_height,
                }))
                .await;
            true
        }
        TYPE_PING => {
            // Echo the nonce back as PONG, routed through the out channel so
            // the single writer puts it on the wire.
            let nonce = decode_nonce(&frame.payload);
            let _ = pong_tx.send(OutItem::Frame(wire::pong_frame(nonce))).await;
            true
        }
        _ => true, // ignore unknown types (forward compat — PONG, legacy HELLO/WELCOME, etc.)
    }
}

struct InitialRequest {
    requested_token: SessionToken,
    cols: u16,
    rows: u16,
    pixel_width: u16,
    pixel_height: u16,
    pending_first: Option<wire::ParsedFrame>,
}

fn initial_request(first: wire::ParsedFrame) -> InitialRequest {
    match first.typ {
        TYPE_ATTACH => {
            if let Some((token, cols, rows, pw, ph)) = parse_attach(&first.payload) {
                InitialRequest {
                    requested_token: token,
                    cols: cols.max(1),
                    rows: rows.max(1),
                    pixel_width: pw,
                    pixel_height: ph,
                    pending_first: None,
                }
            } else {
                default_initial_request(Some(first))
            }
        }
        TYPE_RESIZE if first.payload.len() == 8 => {
            let cols = u16::from_be_bytes([first.payload[0], first.payload[1]]);
            let rows = u16::from_be_bytes([first.payload[2], first.payload[3]]);
            let pixel_width = u16::from_be_bytes([first.payload[4], first.payload[5]]);
            let pixel_height = u16::from_be_bytes([first.payload[6], first.payload[7]]);
            InitialRequest {
                requested_token: [0u8; SESSION_TOKEN_LEN],
                cols: cols.max(1),
                rows: rows.max(1),
                pixel_width,
                pixel_height,
                pending_first: None,
            }
        }
        _ => default_initial_request(Some(first)),
    }
}

fn default_initial_request(pending_first: Option<wire::ParsedFrame>) -> InitialRequest {
    InitialRequest {
        requested_token: [0u8; SESSION_TOKEN_LEN],
        cols: DEFAULT_COLS,
        rows: DEFAULT_ROWS,
        pixel_width: 0,
        pixel_height: 0,
        pending_first,
    }
}

async fn get_or_create_session(
    sessions: &SessionRegistry,
    requested_token: SessionToken,
    shell: String,
    shell_args: Vec<String>,
    cwd: Option<PathBuf>,
    size: TermSize,
) -> Result<Arc<Session>> {
    if !empty_session_token(&requested_token)
        && let Some(existing) = sessions.lock().await.get(&requested_token).cloned()
        && !existing.exited.load(Ordering::Relaxed)
    {
        // Force the remote app to repaint on reattach. The kernel only emits
        // SIGWINCH on an *actual* size change, so resizing straight to
        // (cols, rows) is a no-op when the client reconnects at the same size
        // — and a full-screen app (vim/htop/tmux) would keep showing a stale
        // screen. Resize to a deliberately-different width then back to
        // the real one: two SIGWINCHes, final state correct. The intermediate
        // frame is superseded before it ships over the relay, so there's no
        // visible flicker in practice.
        let mut nudge = size;
        nudge.cols = redraw_nudge_cols(size.cols);
        let _ = existing.pty_tx.send(PtyCmd::Resize(nudge)).await;
        let _ = existing.pty_tx.send(PtyCmd::Resize(size)).await;
        return Ok(existing);
    }

    // Creating a new session: honor a client-proposed token when given so a
    // client with a stable identity always lands on the same PTY (across
    // reconnects and fresh `zuko <host>` invocations). Clients that send an
    // all-zero token (legacy/first-run, or clients without a persistent key)
    // get a fresh random one — unchanged behaviour.
    //
    // `requested_token` reaching here is guaranteed non-colliding in practice:
    // it's derived from the client's 32-byte secret, and we only arrive when
    // no live session holds it (the reuse branch above, or an exited session
    // already removed from the registry by `serve`).
    let token = if empty_session_token(&requested_token) {
        fresh_session_token(sessions).await
    } else {
        requested_token
    };
    let session = spawn_session(token, shell, shell_args, cwd, size)?;
    sessions.lock().await.insert(token, session.clone());
    Ok(session)
}

/// A column count guaranteed to differ from `cols` (and stay ≥1), used to
/// provoke a real `SIGWINCH` on reattach when the terminal size is unchanged.
/// Pure so the boundary clamping is unit-testable.
const fn redraw_nudge_cols(cols: u16) -> u16 {
    if cols > 1 {
        cols - 1
    } else {
        cols.saturating_add(1)
    }
}

async fn fresh_session_token(sessions: &SessionRegistry) -> SessionToken {
    loop {
        let bytes = SecretKey::generate().to_bytes();
        let mut token = [0u8; SESSION_TOKEN_LEN];
        token.copy_from_slice(&bytes[..SESSION_TOKEN_LEN]);
        if empty_session_token(&token) {
            continue;
        }
        if !sessions.lock().await.contains_key(&token) {
            return token;
        }
    }
}

fn spawn_session(
    token: SessionToken,
    shell: String,
    shell_args: Vec<String>,
    cwd: Option<PathBuf>,
    size: TermSize,
) -> Result<Arc<Session>> {
    let Pty {
        tx: pty_tx,
        rx: pty_rx,
        reader: pty_reader,
        master,
        child,
    } = spawn_pty(shell, shell_args, cwd, size)?;

    let session = Arc::new(Session {
        token,
        pty_tx,
        child,
        attachment: std::sync::Mutex::new(None),
        next_attach_id: AtomicU64::new(0),
        lease_generation: AtomicU64::new(0),
        exited: AtomicBool::new(false),
    });

    spawn_pty_reader(session.clone(), pty_reader);
    spawn_pty_writer(pty_rx, master);
    Ok(session)
}

fn spawn_pty_reader(session: Arc<Session>, pty_reader: Box<dyn std::io::Read + Send>) {
    std::thread::spawn(move || {
        let mut reader = pty_reader;
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let chunk = buf[..n].to_vec();
                    tracing::debug!(
                        target: "zuko::host::output",
                        bytes = ?chunk.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>(),
                        ascii = %String::from_utf8_lossy(&chunk),
                        "pty output"
                    );
                    session.send_output(chunk);
                }
            }
        }
        session.mark_exited();
    });
}

fn spawn_pty_writer(
    mut pty_rx: tokio::sync::mpsc::Receiver<PtyCmd>,
    master: Box<dyn portable_pty::MasterPty + Send>,
) {
    std::thread::spawn(move || {
        let Ok(mut writer) = master.take_writer() else {
            return;
        };
        while let Some(cmd) = pty_rx.blocking_recv() {
            match cmd {
                PtyCmd::Data(d) => {
                    tracing::debug!(
                        target: "zuko::host::input",
                        bytes = ?d.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>(),
                        ascii = %String::from_utf8_lossy(&d),
                        "client DATA frame"
                    );
                    if writer.write_all(&d).is_err() {
                        break;
                    }
                }
                PtyCmd::Resize(size) => {
                    let _ = master.resize(PtySize {
                        cols: size.cols,
                        rows: size.rows,
                        pixel_width: size.pixel_width,
                        pixel_height: size.pixel_height,
                    });
                }
            }
        }
    });
}

fn schedule_reap(sessions: SessionRegistry, session: Arc<Session>, generation: u64) {
    tokio::spawn(async move {
        tokio::time::sleep(DETACHED_SESSION_TTL).await;
        if session.should_reap(generation) {
            sessions.lock().await.remove(&session.token);
            session.kill();
        }
    });
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

/// Owned PTY handles for one connection. The receiver (`rx`) is consumed by
/// the dedicated writer thread; `reader` is consumed by the dedicated reader
/// thread; `master` moves into the writer thread (it owns both `take_writer`
/// and `resize`); `child` is killed on connection end.
struct Pty {
    tx: tokio::sync::mpsc::Sender<PtyCmd>,
    rx: tokio::sync::mpsc::Receiver<PtyCmd>,
    reader: Box<dyn std::io::Read + Send>,
    master: Box<dyn portable_pty::MasterPty + Send>,
    child: Arc<std::sync::Mutex<Option<Box<dyn portable_pty::Child + Send + Sync>>>>,
}

/// Open a PTY, spawn the shell, and return the handles the caller needs to
/// plumb reader/writer/resizer/killer threads around it. Doesn't spawn any
/// threads itself — `serve()` does that, so the threading model stays in
/// one place.
fn spawn_pty(
    shell: String,
    shell_args: Vec<String>,
    cwd: Option<PathBuf>,
    size: TermSize,
) -> Result<Pty> {
    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: size.rows,
            cols: size.cols,
            pixel_width: size.pixel_width,
            pixel_height: size.pixel_height,
        })
        .context("openpty")?;

    let mut cmd = CommandBuilder::new(&shell);
    cmd.args(&shell_args);
    cmd.env("TERM", "xterm-256color");
    if let Some(dir) = cwd.as_deref() {
        cmd.cwd(dir);
    }
    let child = pair.slave.spawn_command(cmd).context("spawn shell")?;
    // Drop the slave so that EOF propagates to the master reader when the
    // shell exits.
    drop(pair.slave);

    let reader = pair.master.try_clone_reader().context("clone reader")?;
    let master = pair.master;

    let (tx, rx) = tokio::sync::mpsc::channel::<PtyCmd>(PUMP_CHANNEL_CAP);
    let child = Arc::new(std::sync::Mutex::new(Some(child)));

    Ok(Pty {
        tx,
        rx,
        reader,
        master,
        child,
    })
}

fn default_key_path() -> PathBuf {
    let mut p = config_dir();
    p.push("zuko");
    p.push("key");
    p
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn initial_resize_is_clamped_and_consumed() {
        // 8-byte RESIZE: [cols=0][rows=0][pw=0][ph=0] — both clamp to 1.
        let frame = wire::ParsedFrame {
            typ: TYPE_RESIZE,
            payload: vec![0, 0, 0, 0, 0, 0, 0, 0],
        };
        let req = initial_request(frame);
        assert_eq!((req.cols, req.rows), (1, 1));
        assert_eq!((req.pixel_width, req.pixel_height), (0, 0));
        assert!(empty_session_token(&req.requested_token));
        assert!(req.pending_first.is_none());
    }

    #[test]
    fn non_resize_first_frame_is_preserved() {
        let frame = wire::ParsedFrame {
            typ: TYPE_DATA,
            payload: b"x".to_vec(),
        };
        let req = initial_request(frame);
        assert_eq!((req.cols, req.rows), (DEFAULT_COLS, DEFAULT_ROWS));
        assert!(empty_session_token(&req.requested_token));
        let pending = req
            .pending_first
            .expect("DATA first frame must be replayed");
        assert_eq!(pending.typ, TYPE_DATA);
        assert_eq!(pending.payload, b"x");
    }

    #[test]
    fn attach_first_frame_uses_token_and_size() {
        let token = [9u8; SESSION_TOKEN_LEN];
        let mut buf = wire::attach_frame(token, 120, 33, 1024, 600);
        let frame = wire::try_parse_frame(&mut buf).unwrap();
        let req = initial_request(frame);
        assert_eq!(req.requested_token, token);
        assert_eq!((req.cols, req.rows), (120, 33));
        assert_eq!((req.pixel_width, req.pixel_height), (1024, 600));
        assert!(req.pending_first.is_none());
    }

    // The reattach redraw nudge must always differ from the real width (so the
    // kernel actually emits SIGWINCH) and never collapse to 0 (an invalid PTY
    // size that portable_pty would reject).
    #[test]
    fn redraw_nudge_differs_and_stays_positive() {
        assert_eq!(redraw_nudge_cols(80), 79);
        assert_eq!(redraw_nudge_cols(2), 1);
        // Width 1: can't subtract, so bump the other way instead.
        assert_eq!(redraw_nudge_cols(1), 2);
        // Never 0, and never equals the input.
        for c in [1u16, 2, 3, 80, 200] {
            let n = redraw_nudge_cols(c);
            assert_ne!(n, c, "nudge must differ at {c}");
            assert!(n >= 1, "nudge must stay ≥1 at {c}");
        }
        // The widest terminal must not overflow.
        assert_eq!(redraw_nudge_cols(u16::MAX), u16::MAX - 1);
    }
}
