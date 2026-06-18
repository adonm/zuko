//! `zuko host` — serve this machine's shell over Iroh.
//!
//! Binds an Iroh endpoint with a persistent secret key, prints a copy-pasteable
//! ticket, and for each incoming connection spawns the user's shell on a PTY
//! and bridges it over a single bidirectional Iroh stream.

use anyhow::{Context, Result};
use iroh::{endpoint::presets, Endpoint, SecretKey};
use iroh_tickets::endpoint::EndpointTicket;
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use std::io::{Read, Write};
use std::path::PathBuf;
use tracing::{info, warn};

use crate::config_dir;
use crate::secret::write_secret_0600;
use crate::ticket_file::write_current_ticket;
use crate::wire::{try_parse_frame, ALPN, TYPE_DATA, TYPE_RESIZE};
use crate::HostArgs;

const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;

#[derive(Debug)]
enum PtyCmd {
    Data(Vec<u8>),
    Resize(u16, u16),
}

/// Run the host: bind, print a ticket, accept connections forever.
pub async fn run(args: HostArgs) -> Result<()> {
    // The host logs to stderr (journald / launchd capture); stdout carries only
    // the bare ticket so `... | grep endpointa` and piping work cleanly.
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

    // Stable node id (derived from the persisted key) + a copy-pasteable ticket.
    let node_id = endpoint.id();
    let ticket_str = EndpointTicket::new(endpoint.addr()).to_string();

    // User-facing banner: this is exactly what gets pasted into the app / `zuko connect`.
    eprintln!();
    eprintln!("zuko host ready");
    eprintln!("  node id: {node_id}");
    eprintln!("  to connect, paste this ticket into the iOS app or run:");
    eprintln!("    zuko connect \"{ticket_str}\"");
    println!("{ticket_str}");
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

    // Accept connections forever. Each connection gets its own PTY + shell.
    loop {
        match endpoint.accept().await {
            Some(incoming) => {
                let shell = shell.clone();
                let shell_args = args.shell_args.clone();
                let cwd = args.cwd.clone();
                tokio::spawn(async move {
                    if let Err(e) = serve(incoming, shell, shell_args, cwd).await {
                        warn!("connection ended: {e:#}");
                    }
                });
            }
            None => {
                info!("endpoint stopped accepting");
                break;
            }
        }
    }
    Ok(())
}

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

    let pty_system = native_pty_system();
    let pair = pty_system
        .openpty(PtySize {
            rows: DEFAULT_ROWS,
            cols: DEFAULT_COLS,
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
    let mut child = pair.slave.spawn_command(cmd).context("spawn shell")?;
    // Drop the slave so that EOF propagates to the master reader when the shell exits.
    drop(pair.slave);

    let reader = pair.master.try_clone_reader().context("clone reader")?;
    let master = pair.master;

    // Single thread owns the PTY writer + resize, fed by a channel from the
    // network pump. Keeps all writes to the PTY serialised.
    let (pty_tx, pty_rx) = std::sync::mpsc::channel::<PtyCmd>();
    std::thread::spawn(move || {
        let Ok(mut writer) = master.take_writer() else {
            return;
        };
        for cmd in pty_rx {
            match cmd {
                PtyCmd::Data(d) => {
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

    // PTY output -> network. Blocking reads in a dedicated thread feed a tokio
    // channel; an async task frames and writes to the iroh send stream.
    let (out_tx, mut out_rx) = tokio::sync::mpsc::channel::<Vec<u8>>(128);
    std::thread::spawn(move || {
        let mut reader = reader;
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if out_tx.blocking_send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
            }
        }
    });
    let pty_to_net = tokio::spawn(async move {
        while let Some(bytes) = out_rx.recv().await {
            // The frame type lives in the shared wire module so both sides agree.
            let frame = crate::wire::data_frame(&bytes);
            if send.write_all(&frame).await.is_err() {
                break;
            }
        }
        let _ = send.finish();
    });

    // Network -> PTY. Async frame parser over the iroh recv stream.
    let net_to_pty = tokio::spawn(async move {
        let mut acc: Vec<u8> = Vec::with_capacity(16 * 1024);
        let mut tmp = vec![0u8; 16 * 1024];
        loop {
            match recv.read(&mut tmp).await {
                Ok(Some(n)) => {
                    acc.extend_from_slice(&tmp[..n]);
                    while let Some(frame) = try_parse_frame(&mut acc) {
                        match frame.typ {
                            TYPE_DATA => {
                                if pty_tx.send(PtyCmd::Data(frame.payload)).is_err() {
                                    return;
                                }
                            }
                            TYPE_RESIZE if frame.payload.len() == 4 => {
                                let cols = u16::from_be_bytes([frame.payload[0], frame.payload[1]]);
                                let rows = u16::from_be_bytes([frame.payload[2], frame.payload[3]]);
                                let _ = pty_tx.send(PtyCmd::Resize(cols, rows));
                            }
                            _ => { /* ignore unknown frame types */ }
                        }
                    }
                }
                Ok(None) => return, // stream finished
                Err(_) => return,
            }
        }
    });

    // When either side finishes, tear the session down.
    tokio::select! {
        _ = net_to_pty => {}
        _ = pty_to_net => {}
    }
    // Reap the child explicitly: SIGKILL is asynchronous, and `portable_pty`'s
    // `Child` Drop isn't guaranteed to wait across every backend — so on a
    // long-running host with many sessions a backend that doesn't reap in Drop
    // would otherwise leak zombies. Both calls are best-effort: the shell may
    // already be gone (ESRCH from `kill`) and `wait` then just returns the
    // exit status that the PTY reader already observed.
    let _ = child.kill();
    let _ = child.wait();
    Ok(())
}

fn default_key_path() -> PathBuf {
    let mut p = config_dir();
    p.push("zuko");
    p.push("key");
    p
}

fn load_or_create_key(path: &PathBuf) -> Result<SecretKey> {
    if path.exists() {
        let bytes = std::fs::read(path).with_context(|| format!("read key {}", path.display()))?;
        if bytes.len() != 32 {
            anyhow::bail!("key file {} is not 32 bytes", path.display());
        }
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&bytes);
        Ok(SecretKey::from_bytes(&arr))
    } else {
        let secret = SecretKey::generate();
        let bytes = secret.to_bytes();
        // The key is the host's persistent identity: write it through the shared
        // atomic 0600 writer so a crash mid-write can never leave a truncated
        // file that load_or_create_key would then reject (silently invalidating
        // every saved connection on the next start).
        write_secret_0600(path, &bytes)?;
        Ok(secret)
    }
}
