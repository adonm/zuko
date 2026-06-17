//! Zuko host daemon.
//!
//! Exposes an interactive shell (over a real PTY) through an Iroh connection.
//!
//! ## Wire protocol (single bidirectional Iroh stream, ALPN `zuko/1`)
//!
//! Every message is length-prefixed:
//! ```text
//!   [type: u8][len: u16 big-endian][payload: `len` bytes]
//! ```
//! - `0x00` DATA   — payload is raw terminal bytes.
//!   client -> host: keystrokes. host -> client: PTY output.
//! - `0x01` RESIZE — payload is `[cols: u16 BE][rows: u16 BE]`. client → host only.
//!
//! Keeping the same framing on both ends means resize + data stay ordered and
//! nothing leaks into the terminal as in-band escape sequences.

use anyhow::{Context, Result, bail};
use clap::Parser;
use iroh::{Endpoint, SecretKey, endpoint::presets};
use iroh_tickets::endpoint::EndpointTicket;
use portable_pty::{CommandBuilder, PtySize, native_pty_system};
use std::io::{Read, Write};
use std::path::PathBuf;
use tracing::{info, warn};

const ALPN: &[u8] = b"zuko/1";
const DEFAULT_COLS: u16 = 80;
const DEFAULT_ROWS: u16 = 24;

#[derive(Parser)]
#[command(name = "zuko-host", version, about = "Expose a shell over Iroh for the Zuko iOS app")]
struct Cli {
    /// Path to the persistent secret key file. A stable key keeps your node id
    /// stable across restarts so saved connections keep working.
    #[arg(long)]
    key: Option<PathBuf>,

    /// Shell to launch for new connections.
    #[arg(long, default_value = "$SHELL")]
    shell: String,

    /// Extra args passed to the shell.
    #[arg(long, num_args = 0.., default_values_t = Vec::<String>::new())]
    shell_args: Vec<String>,

    /// Directory to start the shell in.
    #[arg(long)]
    cwd: Option<PathBuf>,
}

#[derive(Debug)]
enum PtyCmd {
    Data(Vec<u8>),
    Resize(u16, u16),
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "zuko_host=info,iroh=warn".into()),
        )
        .init();

    let cli = Cli::parse();
    let key_path = cli.key.unwrap_or_else(default_key_path);
    let secret = load_or_create_key(&key_path)?;

    let shell = if cli.shell == "$SHELL" {
        std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string())
    } else {
        cli.shell
    };

    let endpoint = Endpoint::builder(presets::N0)
        .secret_key(secret)
        .bind()
        .await
        .context("bind endpoint")?;
    endpoint.online().await;

    // Stable node id (derived from the persisted key) + a copy-pasteable ticket.
    let node_id = endpoint.id();
    let ticket_str = EndpointTicket::new(endpoint.addr()).to_string();

    // User-facing banner: this is exactly what gets pasted into the app.
    eprintln!();
    eprintln!("zuko host ready");
    eprintln!("  node id: {node_id}");
    eprintln!("  on your iPhone, add a new connection and paste this ticket:");
    println!("{ticket_str}");
    eprintln!();
    info!(%node_id, "listening on alpn {:?}", String::from_utf8_lossy(ALPN));

    // Accept connections forever. Each connection gets its own PTY + shell.
    loop {
        match endpoint.accept().await {
            Some(incoming) => {
                let shell = shell.clone();
                let shell_args = cli.shell_args.clone();
                let cwd = cli.cwd.clone();
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
            let mut frame = Vec::with_capacity(3 + bytes.len());
            frame.push(0x00); // DATA
            frame.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
            frame.extend_from_slice(&bytes);
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
                            0x00 => {
                                if pty_tx.send(PtyCmd::Data(frame.payload)).is_err() {
                                    return;
                                }
                            }
                            0x01 if frame.payload.len() == 4 => {
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
    let _ = child.kill();
    Ok(())
}

struct ParsedFrame {
    typ: u8,
    payload: Vec<u8>,
}

/// Pull one complete length-prefixed frame off the front of `buf`, draining it.
fn try_parse_frame(buf: &mut Vec<u8>) -> Option<ParsedFrame> {
    if buf.len() < 3 {
        return None;
    }
    let typ = buf[0];
    let len = u16::from_be_bytes([buf[1], buf[2]]) as usize;
    if buf.len() < 3 + len {
        return None;
    }
    let payload = buf[3..3 + len].to_vec();
    buf.drain(..3 + len);
    Some(ParsedFrame { typ, payload })
}

fn default_key_path() -> PathBuf {
    let mut p = dirs_or_home();
    p.push("zuko");
    p.push("key");
    p
}

fn dirs_or_home() -> PathBuf {
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        return PathBuf::from(xdg);
    }
    let mut h = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    h.push(".config");
    h
}

fn load_or_create_key(path: &PathBuf) -> Result<SecretKey> {
    if path.exists() {
        let bytes = std::fs::read(path).with_context(|| format!("read key {}", path.display()))?;
        if bytes.len() != 32 {
            bail!("key file {} is not 32 bytes", path.display());
        }
        let mut arr = [0u8; 32];
        arr.copy_from_slice(&bytes);
        Ok(SecretKey::from_bytes(&arr))
    } else {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        let secret = SecretKey::generate();
        let bytes = secret.to_bytes();
        // Create with 0600 perms where possible.
        write_secret(path, &bytes)?;
        Ok(secret)
    }
}

fn write_secret(path: &PathBuf, bytes: &[u8]) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        let mut f = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        use std::io::Write;
        f.write_all(bytes)?;
    }
    #[cfg(not(unix))]
    {
        std::fs::write(path, bytes)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Mirror of the iOS `Wire.encode` for the DATA frame, used to check the
    /// host parser against the exact bytes a client sends.
    fn client_data_frame(payload: &[u8]) -> Vec<u8> {
        let mut f = Vec::with_capacity(3 + payload.len());
        f.push(0x00);
        f.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        f.extend_from_slice(payload);
        f
    }

    fn resize_frame(cols: u16, rows: u16) -> Vec<u8> {
        let payload = [cols.to_be_bytes(), rows.to_be_bytes()].concat();
        let mut framed = Vec::with_capacity(3 + payload.len());
        framed.push(0x01);
        framed.extend_from_slice(&(payload.len() as u16).to_be_bytes());
        framed.extend_from_slice(&payload);
        framed
    }

    #[test]
    fn parses_single_data_frame() {
        let mut buf = client_data_frame(b"ls -la\r\n");
        let frame = try_parse_frame(&mut buf).expect("frame");
        assert_eq!(frame.typ, 0x00);
        assert_eq!(frame.payload, b"ls -la\r\n");
        assert!(buf.is_empty(), "buffer drained");
    }

    #[test]
    fn parses_back_to_back_frames_and_resumes_partial() {
        let mut buf = Vec::new();
        buf.extend(client_data_frame(b"hi"));
        buf.extend(resize_frame(120, 40));
        // A deliberately truncated third frame (header claims 5 bytes, only 2 present).
        buf.extend_from_slice(&[0x00, 0x00, 0x05, b'x', b'y']);

        let f1 = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f1.typ, 0x00);
        assert_eq!(f1.payload, b"hi");

        let f2 = try_parse_frame(&mut buf).unwrap();
        assert_eq!(f2.typ, 0x01);
        assert_eq!(f2.payload.len(), 4);
        let cols = u16::from_be_bytes([f2.payload[0], f2.payload[1]]);
        let rows = u16::from_be_bytes([f2.payload[2], f2.payload[3]]);
        assert_eq!((cols, rows), (120, 40));

        // Partial frame: parser must wait for more bytes, leaving the remainder intact.
        assert!(try_parse_frame(&mut buf).is_none());
        assert_eq!(buf, vec![0x00, 0x00, 0x05, b'x', b'y']);
    }

    #[test]
    fn ignores_unknown_frame_type() {
        let mut buf = vec![0x42, 0x00, 0x01, 0xFF];
        let frame = try_parse_frame(&mut buf).unwrap();
        assert_eq!(frame.typ, 0x42);
        assert_eq!(frame.payload, vec![0xFF]);
    }
}
