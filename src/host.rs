//! `zuko host` — serve this machine's shell over Iroh.
//!
//! Binds an Iroh endpoint with a persistent secret key, writes its dialable
//! ticket to `~/.config/zuko/current_ticket` (read out-of-band by
//! `zuko share`), and for each incoming connection spawns the user's shell on
//! a PTY. The connection owns the PTY: when it ends (for any reason — shell
//! exit, network drop, client disconnect) the PTY is killed.
//!
//! ## No session persistence (v0.6)
//!
//! Earlier versions (v0.4–v0.5) kept sessions alive across disconnects and
//! replayed a ring buffer on resume. That added a lot of machinery (session
//! registry, ring buffer, reaper, control socket) and a class of edge cases
//! (stale sessions, two connections to one session, garbled replays for
//! fullscreen apps). v0.6 rips it out: each connection is a fresh PTY, end of
//! story. Users who want resumability run `tmux`/`zellij`/`screen` *inside*
//! the zuko session — that's the proper layer for it.

use anyhow::{Context, Result};
use iroh::{Endpoint, SecretKey, endpoint::presets};
use iroh_tickets::endpoint::EndpointTicket;
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{info, warn};

use crate::HostArgs;
use crate::config_dir;
use crate::secret::write_secret_0600;
use crate::ticket_file::write_current_ticket;
use crate::wire::{self, ALPN, TYPE_DATA, TYPE_PING, TYPE_RESIZE, decode_nonce, try_parse_frame};

/// Per-direction capacity of the bounded channels that connect the network
/// pump to the PTY (and back). Bounds host memory under flood — without it a
/// client pasting/flooding faster than the shell drains stdin, or a shell
/// emitting faster than the network ships, would grow the heap without limit.
/// Saturation back-pressures the right way: the producer awaits, QUIC flow
/// control chokes the peer, and on the output side the kernel TTY buffer
/// eventually blocks the shell's own writes.
const PUMP_CHANNEL_CAP: usize = 128;

#[derive(Debug)]
enum PtyCmd {
    Data(Vec<u8>),
    Resize(u16, u16),
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

    // Accept connections forever. Each connection spawns its own PTY; the
    // PTY dies with the connection.
    loop {
        if let Some(incoming) = endpoint.accept().await {
            let shell = shell.clone();
            let shell_args = args.shell_args.clone();
            let cwd = args.cwd.clone();
            tokio::spawn(async move {
                if let Err(e) = serve(incoming, shell, shell_args, cwd).await {
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
) -> Result<()> {
    let conn = incoming
        .accept()
        .context("accept connection")?
        .await
        .context("complete connection")?;
    let (mut send, mut recv) = conn.accept_bi().await.context("accept bidi stream")?;

    // ── Handshake: read the client's first frame. ──
    // The client sends a single `RESIZE` carrying the initial terminal size.
    // Anything else (e.g. a stale v0.4–v0.5 `HELLO`): ignore and default to
    // 80×24; the client's first subsequent `RESIZE` corrects it.
    let mut acc: Vec<u8> = Vec::with_capacity(16 * 1024);
    let mut tmp = vec![0u8; 16 * 1024];
    let first = read_one_frame(&mut recv, &mut acc, &mut tmp).await?;
    let (cols, rows) = match first.typ {
        TYPE_RESIZE if first.payload.len() == 4 => {
            let cols = u16::from_be_bytes([first.payload[0], first.payload[1]]);
            let rows = u16::from_be_bytes([first.payload[2], first.payload[3]]);
            (cols.max(1), rows.max(1))
        }
        _ => (DEFAULT_COLS, DEFAULT_ROWS),
    };

    // ── Spawn the PTY + shell. ──
    let Pty {
        tx: pty_tx,
        rx: _pty_rx,
        reader: pty_reader,
        master,
        child,
    } = spawn_pty(shell, shell_args, cwd, cols, rows)?;

    // Outbound channel: PTY output + PONG replies to client PINGs all funnel
    // through here so the single `pty_to_net` writer puts frames on the wire
    // in order without interleaving. (Heartbeat was removed in v0.6 — iroh's
    // QUIC keepalive handles transport liveness, and without auto-reconnect
    // there's nothing for an app-level heartbeat to trigger.)
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<OutItem>(PUMP_CHANNEL_CAP);
    let pong_tx = out_tx.clone();

    // PTY reader -> out channel. Runs on a dedicated OS thread because
    // portable_pty's reader is a blocking `Read`. The channel's bounded cap
    // back-pressures: if the network slows, this thread awaits `send`,
    // which in turn blocks the PTY's stdout pipe (kernel TTY buffer fills,
    // the shell's own writes block). No ring buffer, no detach — the PTY
    // dies with the connection.
    let out_tx_for_reader = out_tx.clone();
    std::thread::spawn(move || {
        // `reader` is owned by this closure; the loop reads until EOF/err.
        let mut reader = pty_reader;
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let chunk = buf[..n].to_vec();
                    // Verbose byte trace for output diagnostics.
                    tracing::debug!(
                        target: "zuko::host::output",
                        bytes = ?chunk.iter().map(|b| format!("{:02x}", b)).collect::<Vec<_>>(),
                        ascii = %String::from_utf8_lossy(&chunk),
                        "pty output"
                    );
                    if out_tx_for_reader.blocking_send(OutItem::Pty(chunk)).is_err() {
                        // Network side gone — stop reading.
                        break;
                    }
                }
            }
        }
        // Reader saw EOF (shell exited) or the network dropped. Either way,
        // close the outbound so `pty_to_net` drains + finishes the send
        // stream → the client sees EOF → stops rather than reconnecting a
        // dead session.
        drop(out_tx_for_reader);
    });

    // PTY writer: dedicated thread, takes commands from `pty_tx` and applies
    // them to the PTY master. Keeps all writes serialised; the channel cap
    // bounds memory if a client floods DATA frames faster than the shell
    // reads stdin. Owns `master` outright (no Arc) — portable_pty's MasterPty
    // isn't `Send`-safe to share, and the writer is the only place that
    // touches it after spawn.
    std::thread::spawn(move || {
        // Take the receiver end of the PTY command channel and own it here.
        // The PTY writer is the sole consumer.
        let mut pty_rx = _pty_rx;
        let master = master;
        let Ok(mut writer) = master.take_writer() else {
            return;
        };
        while let Some(cmd) = pty_rx.blocking_recv() {
            match cmd {
                PtyCmd::Data(d) => {
                    // Verbose byte trace for input diagnostics. Enable with
                    // RUST_LOG=zuko=debug.
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
                PtyCmd::Resize(cols, rows) => {
                    let _ = master.resize(PtySize {
                        cols,
                        rows,
                        pixel_width: 0,
                        pixel_height: 0,
                    });
                }
            }
        }
    });

    // PTY output (via the out channel) + control frames -> network.
    // Ends when all senders are dropped (reader thread done) or the send
    // errors (connection dropped).
    let pty_to_net = tokio::spawn(async move {
        while let Some(item) = out_rx.recv().await {
            let frame = match item {
                OutItem::Pty(bytes) => wire::data_frame(&bytes),
                OutItem::Frame(pre) => pre,
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
    let net_to_pty: tokio::task::JoinHandle<()> = tokio::spawn(async move {
        loop {
            // Parse any bytes already in `acc` first (from the handshake
            // read), then top up from the stream.
            while let Some(frame) = try_parse_frame(&mut acc) {
                if !handle_client_frame(&frame, &pty_tx, &pong_tx).await {
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

    // Host-side heartbeat removed in v0.6 — see note on out_tx above.

    // Wait for the network side to end. The PTY→net side ends on its own when
    // `out_rx` closes (reader thread done), the send errors, or the shell
    // exited (reader saw EOF, dropped its sender, pty_to_net drains + finishes).
    let _ = net_to_pty.await;
    pty_to_net.abort();

    // Always kill the PTY — there's no resume to preserve it for. Best-effort:
    // the shell may already be gone (ESRCH from `kill`).
    if let Ok(mut guard) = child.lock() {
        if let Some(child) = guard.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
        *guard = None;
    }
    Ok(())
}

/// Handle one frame from the client. Returns `false` if the session's PTY
/// writer is gone and the connection should end. `pong_tx` routes PONGs
/// (replies to our PINGs) back out the send stream.
async fn handle_client_frame(
    frame: &wire::ParsedFrame,
    pty_tx: &tokio::sync::mpsc::Sender<PtyCmd>,
    pong_tx: &tokio::sync::mpsc::Sender<OutItem>,
) -> bool {
    match frame.typ {
        TYPE_DATA => {
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
        _ => true, // ignore unknown types (forward compat — PONG, legacy HELLO/WELCOME, etc.)
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
    cols: u16,
    rows: u16,
) -> Result<Pty> {
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
        assert_eq!(perms & 0o777, 0o600, "key file must be 0600, got {perms:o}");
    }
}
