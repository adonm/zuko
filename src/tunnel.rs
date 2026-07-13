//! Ephemeral raw TCP forwarding for a hosted Zuko shell.
//!
//! `zuko tunnel PORT` registers host `127.0.0.1:PORT` with the parent
//! `zuko host` through a random per-PTY control capability. The attached client
//! receives a typed offer, opens a separate authenticated `zuko/tunnel/1` Iroh
//! connection, and binds an ephemeral client-loopback port. Each accepted TCP
//! connection maps to one Iroh bidirectional stream. Zuko never interprets the
//! forwarded bytes, so HTTP, TLS, WebSockets, SSH, and other TCP protocols work
//! unchanged.

use anyhow::{Context, Result, bail};
use iroh::{Endpoint, EndpointAddr, endpoint::Connection};
use std::collections::HashMap;
use std::io;
use std::net::{Ipv4Addr, SocketAddr};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::{mpsc, watch};
use tokio::task::{JoinHandle, JoinSet};

use crate::TunnelArgs;
use crate::wire::{
    self, ERR_AUTHORIZATION, ERR_PROTOCOL, SessionToken, TUNNEL_ALPN, TUNNEL_ID_LEN, TYPE_ERROR,
    TYPE_TUNNEL_ATTACH, TYPE_TUNNEL_ATTACHED, TunnelId, parse_error, parse_tunnel_attach,
    parse_tunnel_id, try_parse_frame, tunnel_attach_frame,
};

pub const CONTROL_ADDR_ENV: &str = "ZUKO_TUNNEL_CONTROL_ADDR";
pub const CONTROL_SECRET_ENV: &str = "ZUKO_TUNNEL_CONTROL_SECRET";
const CONTROL_MAGIC: &[u8; 8] = b"ZTUNNEL1";
const CONTROL_SECRET_LEN: usize = 32;
const EVENT_OPENED: u8 = 1;
const EVENT_CLOSED: u8 = 2;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_CONCURRENT_CONNECTIONS: usize = 64;
pub const MAX_ACTIVE_TUNNELS_PER_SESSION: usize = 64;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct TunnelOffer {
    pub id: TunnelId,
    pub port: u16,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TunnelEvent {
    Opened {
        connection: u64,
    },
    Closed {
        connection: u64,
        uploaded: u64,
        downloaded: u64,
    },
}

struct Registration {
    token: SessionToken,
    port: u16,
    cancel: watch::Sender<bool>,
    events: mpsc::Sender<TunnelEvent>,
    permits: Arc<tokio::sync::Semaphore>,
}

struct RegistryInner {
    entries: Mutex<HashMap<TunnelId, Registration>>,
    next_connection: AtomicU64,
}

#[derive(Clone)]
pub struct TunnelRegistry {
    inner: Arc<RegistryInner>,
}

impl Default for TunnelRegistry {
    fn default() -> Self {
        Self {
            inner: Arc::new(RegistryInner {
                entries: Mutex::new(HashMap::new()),
                next_connection: AtomicU64::new(1),
            }),
        }
    }
}

pub struct TunnelTarget {
    pub port: u16,
    pub cancel: watch::Receiver<bool>,
    events: mpsc::Sender<TunnelEvent>,
    permits: Arc<tokio::sync::Semaphore>,
}

impl TunnelRegistry {
    pub fn register(
        &self,
        token: SessionToken,
        port: u16,
    ) -> Result<(TunnelOffer, mpsc::Receiver<TunnelEvent>)> {
        let mut entries = self.inner.entries.lock().expect("tunnel registry poisoned");
        if entries
            .values()
            .filter(|entry| entry.token == token)
            .count()
            >= MAX_ACTIVE_TUNNELS_PER_SESSION
        {
            bail!("a session may have at most {MAX_ACTIVE_TUNNELS_PER_SESSION} active tunnels");
        }
        let id = loop {
            let bytes = iroh::SecretKey::generate().to_bytes();
            let mut id = [0; TUNNEL_ID_LEN];
            id.copy_from_slice(&bytes[..TUNNEL_ID_LEN]);
            if !entries.contains_key(&id) {
                break id;
            }
        };
        let (cancel, _) = watch::channel(false);
        let (events, event_rx) = mpsc::channel(256);
        entries.insert(
            id,
            Registration {
                token,
                port,
                cancel,
                events,
                permits: Arc::new(tokio::sync::Semaphore::new(MAX_CONCURRENT_CONNECTIONS)),
            },
        );
        Ok((TunnelOffer { id, port }, event_rx))
    }

    pub fn remove(&self, id: TunnelId) {
        if let Some(entry) = self
            .inner
            .entries
            .lock()
            .expect("tunnel registry poisoned")
            .remove(&id)
        {
            let _ = entry.cancel.send(true);
        }
    }

    pub fn lookup(&self, token: &SessionToken, id: &TunnelId) -> Option<TunnelTarget> {
        let entries = self.inner.entries.lock().expect("tunnel registry poisoned");
        let entry = entries.get(id)?;
        if &entry.token != token {
            return None;
        }
        Some(TunnelTarget {
            port: entry.port,
            cancel: entry.cancel.subscribe(),
            events: entry.events.clone(),
            permits: entry.permits.clone(),
        })
    }

    pub fn offers_for(&self, token: &SessionToken) -> Vec<TunnelOffer> {
        self.inner
            .entries
            .lock()
            .expect("tunnel registry poisoned")
            .iter()
            .filter(|(_, entry)| &entry.token == token)
            .map(|(id, entry)| TunnelOffer {
                id: *id,
                port: entry.port,
            })
            .collect()
    }

    fn next_connection(&self) -> u64 {
        self.inner.next_connection.fetch_add(1, Ordering::Relaxed)
    }
}

pub fn new_control_secret() -> [u8; CONTROL_SECRET_LEN] {
    iroh::SecretKey::generate().to_bytes()
}

pub fn control_secret_hex(secret: &[u8; CONTROL_SECRET_LEN]) -> String {
    secret.iter().map(|byte| format!("{byte:02x}")).collect()
}

fn decode_control_secret(value: &str) -> Result<[u8; CONTROL_SECRET_LEN]> {
    if value.len() != CONTROL_SECRET_LEN * 2 {
        bail!("invalid Zuko tunnel control capability");
    }
    let mut secret = [0; CONTROL_SECRET_LEN];
    for (index, chunk) in value.as_bytes().chunks_exact(2).enumerate() {
        let text = std::str::from_utf8(chunk).context("tunnel control capability is not ASCII")?;
        secret[index] =
            u8::from_str_radix(text, 16).context("tunnel control capability is not hex")?;
    }
    Ok(secret)
}

pub async fn read_control_registration(
    stream: &mut TcpStream,
    expected_secret: &[u8; CONTROL_SECRET_LEN],
) -> Result<u16> {
    let mut magic = [0; CONTROL_MAGIC.len()];
    stream.read_exact(&mut magic).await?;
    if &magic != CONTROL_MAGIC {
        bail!("invalid Zuko tunnel control preface");
    }
    let mut secret = [0; CONTROL_SECRET_LEN];
    stream.read_exact(&mut secret).await?;
    if &secret != expected_secret {
        bail!("invalid Zuko tunnel control capability");
    }
    let port = stream.read_u16().await?;
    if port == 0 {
        bail!("tunnel port must not be zero");
    }
    Ok(port)
}

pub(crate) fn require_control_environment(
    command: &str,
) -> Result<(SocketAddr, [u8; CONTROL_SECRET_LEN])> {
    let addr = std::env::var(CONTROL_ADDR_ENV)
        .with_context(|| format!("`{command}` must run inside a shell opened through Zuko"))?;
    let addr: SocketAddr = addr
        .parse()
        .context("invalid Zuko tunnel control address")?;
    if !addr.ip().is_loopback() {
        bail!("Zuko tunnel control address is not loopback");
    }
    let secret = decode_control_secret(
        &std::env::var(CONTROL_SECRET_ENV).context("missing Zuko tunnel control capability")?,
    )?;
    Ok((addr, secret))
}

async fn register_with_host(port: u16) -> Result<TcpStream> {
    let (addr, secret) = require_control_environment("zuko tunnel")?;
    let mut stream = TcpStream::connect(addr)
        .await
        .context("connect to parent Zuko host")?;
    stream.write_all(CONTROL_MAGIC).await?;
    stream.write_all(&secret).await?;
    stream.write_u16(port).await?;
    stream.flush().await?;
    let ack = stream
        .read_u8()
        .await
        .context("parent Zuko host closed tunnel registration")?;
    if ack != 0 {
        bail!("parent Zuko host rejected tunnel registration");
    }
    Ok(stream)
}

/// Run `zuko tunnel PORT` in the hosted shell until Ctrl-C or parent exit.
pub async fn run(args: TunnelArgs) -> Result<()> {
    let mut control = register_with_host(args.port).await?;
    eprintln!(
        "zuko tunnel: forwarding a client loopback port to host 127.0.0.1:{}",
        args.port
    );
    eprintln!("zuko tunnel: press Ctrl-C to stop");

    let mut active = 0u64;
    let mut connections = 0u64;
    let mut uploaded = 0u64;
    let mut downloaded = 0u64;
    let result = loop {
        tokio::select! {
            signal = tokio::signal::ctrl_c() => {
                signal.context("listen for Ctrl-C")?;
                break Ok(());
            }
            event = read_event(&mut control) => match event {
                Ok(TunnelEvent::Opened { connection }) => {
                    active += 1;
                    connections += 1;
                    eprintln!("zuko tunnel: connection {connection} opened ({active} active)");
                }
                Ok(TunnelEvent::Closed { connection, uploaded: up, downloaded: down }) => {
                    active = active.saturating_sub(1);
                    uploaded = uploaded.saturating_add(up);
                    downloaded = downloaded.saturating_add(down);
                    eprintln!(
                        "zuko tunnel: connection {connection} closed (up {}, down {}, {active} active)",
                        format_bytes(up),
                        format_bytes(down),
                    );
                }
                Err(error) => break Err(error).context("parent Zuko host stopped the tunnel"),
            }
        }
    };

    drop(control);
    eprintln!(
        "zuko tunnel: stopped ({connections} connections, up {}, down {})",
        format_bytes(uploaded),
        format_bytes(downloaded),
    );
    result
}

pub async fn write_event<W: AsyncWriteExt + Unpin>(
    writer: &mut W,
    event: TunnelEvent,
) -> io::Result<()> {
    match event {
        TunnelEvent::Opened { connection } => {
            writer.write_u8(EVENT_OPENED).await?;
            writer.write_u64(connection).await?;
        }
        TunnelEvent::Closed {
            connection,
            uploaded,
            downloaded,
        } => {
            writer.write_u8(EVENT_CLOSED).await?;
            writer.write_u64(connection).await?;
            writer.write_u64(uploaded).await?;
            writer.write_u64(downloaded).await?;
        }
    }
    writer.flush().await
}

async fn read_event<R: AsyncReadExt + Unpin>(reader: &mut R) -> io::Result<TunnelEvent> {
    match reader.read_u8().await? {
        EVENT_OPENED => Ok(TunnelEvent::Opened {
            connection: reader.read_u64().await?,
        }),
        EVENT_CLOSED => Ok(TunnelEvent::Closed {
            connection: reader.read_u64().await?,
            uploaded: reader.read_u64().await?,
            downloaded: reader.read_u64().await?,
        }),
        kind => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("unknown tunnel event {kind}"),
        )),
    }
}

fn format_bytes(bytes: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = bytes as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{bytes} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}

/// Serve one authenticated `zuko/tunnel/1` connection on the persistent host.
pub async fn serve_connection(conn: Connection, registry: TunnelRegistry) -> Result<()> {
    let (mut send, mut recv) = tokio::time::timeout(HANDSHAKE_TIMEOUT, conn.accept_bi())
        .await
        .context("timed out waiting for tunnel handshake")?
        .context("accept tunnel handshake stream")?;
    let first = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_one_frame(&mut recv))
        .await
        .context("timed out waiting for tunnel handshake frame")??;
    if first.typ != TYPE_TUNNEL_ATTACH {
        send.write_all(&wire::error_frame(
            ERR_PROTOCOL,
            "first frame must be TUNNEL_ATTACH",
        ))
        .await?;
        let _ = send.finish();
        bail!("first tunnel frame must be TUNNEL_ATTACH");
    }
    let (token, id) = parse_tunnel_attach(&first.payload).context("malformed TUNNEL_ATTACH")?;
    if let Err(error) = crate::store::ensure_client_authorized(&token) {
        send.write_all(&wire::error_frame(ERR_AUTHORIZATION, &error.to_string()))
            .await?;
        let _ = send.finish();
        return Err(error);
    }
    let mut target = match registry.lookup(&token, &id) {
        Some(target) => target,
        None => {
            send.write_all(&wire::error_frame(
                ERR_AUTHORIZATION,
                "tunnel is unavailable",
            ))
            .await?;
            let _ = send.finish();
            bail!("unknown or mismatched tunnel");
        }
    };
    send.write_all(&wire::tunnel_attached_frame(id)).await?;
    let _ = send.finish();

    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            changed = target.cancel.changed() => {
                if changed.is_err() || *target.cancel.borrow() {
                    break;
                }
            }
            accepted = conn.accept_bi() => match accepted {
                Ok((send, recv)) => {
                    let Ok(permit) = target.permits.clone().try_acquire_owned() else {
                        drop(send);
                        drop(recv);
                        continue;
                    };
                    let connection = registry.next_connection();
                    let _ = target
                        .events
                        .send(TunnelEvent::Opened { connection })
                        .await;
                    let port = target.port;
                    let events = target.events.clone();
                    connections.spawn(async move {
                        let _permit = permit;
                        let (uploaded, downloaded) = proxy_to_host(send, recv, port)
                            .await
                            .unwrap_or_default();
                        let _ = events.send(TunnelEvent::Closed {
                            connection,
                            uploaded,
                            downloaded,
                        }).await;
                    });
                }
                Err(_) => break,
            },
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    conn.close(0u32.into(), b"tunnel stopped");
    connections.abort_all();
    while connections.join_next().await.is_some() {}
    Ok(())
}

async fn proxy_to_host(
    mut send: iroh::endpoint::SendStream,
    mut recv: iroh::endpoint::RecvStream,
    port: u16,
) -> Result<(u64, u64)> {
    let tcp = TcpStream::connect((Ipv4Addr::LOCALHOST, port))
        .await
        .with_context(|| format!("connect host loopback port {port}"))?;
    let (mut tcp_read, mut tcp_write) = tcp.into_split();
    let upload = async {
        let bytes = tokio::io::copy(&mut recv, &mut tcp_write).await?;
        tcp_write.shutdown().await?;
        Ok::<u64, io::Error>(bytes)
    };
    let download = async {
        let bytes = tokio::io::copy(&mut tcp_read, &mut send).await?;
        send.finish().map_err(io::Error::other)?;
        Ok::<u64, io::Error>(bytes)
    };
    tokio::try_join!(upload, download).map_err(Into::into)
}

#[derive(Clone, Copy, Debug)]
pub enum ClientTunnelEvent {
    Open(TunnelOffer),
    Close(TunnelId),
}

pub async fn run_client_events(
    mut events: mpsc::Receiver<ClientTunnelEvent>,
    endpoint: Endpoint,
    addr: EndpointAddr,
    token: SessionToken,
) {
    let mut active: HashMap<TunnelId, JoinHandle<()>> = HashMap::new();
    while let Some(event) = events.recv().await {
        match event {
            ClientTunnelEvent::Open(offer) => {
                if active
                    .get(&offer.id)
                    .is_some_and(|task| !task.is_finished())
                {
                    continue;
                }
                if let Some(old) = active.remove(&offer.id) {
                    old.abort();
                }
                let endpoint = endpoint.clone();
                let addr = addr.clone();
                let id = offer.id;
                let task = tokio::spawn(async move {
                    if let Err(error) = serve_client_loopback(endpoint, addr, token, offer).await {
                        eprintln!("\r\nzuko tunnel: {error:#}\r");
                    }
                });
                active.insert(id, task);
            }
            ClientTunnelEvent::Close(id) => {
                if let Some(task) = active.remove(&id) {
                    task.abort();
                }
            }
        }
    }
    for (_, task) in active {
        task.abort();
    }
}

async fn serve_client_loopback(
    endpoint: Endpoint,
    addr: EndpointAddr,
    token: SessionToken,
    offer: TunnelOffer,
) -> Result<()> {
    let conn = endpoint
        .connect(addr, TUNNEL_ALPN)
        .await
        .context("connect tunnel")?;
    let (mut send, mut recv) = conn.open_bi().await.context("open tunnel handshake")?;
    send.write_all(&tunnel_attach_frame(token, offer.id))
        .await?;
    send.finish().map_err(io::Error::other)?;
    let reply = tokio::time::timeout(HANDSHAKE_TIMEOUT, read_one_frame(&mut recv))
        .await
        .context("timed out waiting for tunnel")??;
    match reply.typ {
        TYPE_TUNNEL_ATTACHED if parse_tunnel_id(&reply.payload) == Some(offer.id) => {}
        TYPE_ERROR => {
            let (_, message) = parse_error(&reply.payload).unwrap_or_default();
            bail!("host rejected tunnel: {message}");
        }
        _ => bail!("invalid tunnel handshake reply"),
    }

    let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0))
        .await
        .context("bind client tunnel listener")?;
    let local = listener.local_addr()?;
    let url = format!("http://{local}/");
    eprintln!(
        "\r\nzuko tunnel: client {local} -> host 127.0.0.1:{}\r",
        offer.port
    );
    if std::env::var_os("ZUKO_NO_BROWSER").is_none()
        && let Err(error) = webbrowser::open(&url)
    {
        eprintln!("\r\nzuko tunnel: could not open browser ({error}); open {url}\r");
    }

    let mut connections = JoinSet::new();
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, peer) = accepted.context("accept client tunnel connection")?;
                if !peer.ip().is_loopback() {
                    continue;
                }
                let conn = conn.clone();
                connections.spawn(async move {
                    if let Err(error) = proxy_from_client(stream, conn).await {
                        tracing::debug!("client tunnel connection ended: {error:#}");
                    }
                });
            }
            _ = conn.closed() => break,
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    }
    connections.abort_all();
    while connections.join_next().await.is_some() {}
    Ok(())
}

async fn proxy_from_client(mut tcp: TcpStream, conn: Connection) -> Result<()> {
    let (mut send, mut recv) = conn.open_bi().await.context("open tunnel stream")?;
    let (mut tcp_read, mut tcp_write) = tcp.split();
    let upload = async {
        tokio::io::copy(&mut tcp_read, &mut send).await?;
        send.finish().map_err(io::Error::other)
    };
    let download = async {
        tokio::io::copy(&mut recv, &mut tcp_write).await?;
        tcp_write.shutdown().await
    };
    tokio::try_join!(upload, download).context("proxy tunnel bytes")?;
    Ok(())
}

async fn read_one_frame(recv: &mut iroh::endpoint::RecvStream) -> Result<wire::ParsedFrame> {
    let mut acc = Vec::with_capacity(256);
    let mut chunk = [0u8; 1024];
    loop {
        if let Some(frame) = try_parse_frame(&mut acc) {
            return Ok(frame);
        }
        match recv.read(&mut chunk).await? {
            Some(read) => acc.extend_from_slice(&chunk[..read]),
            None => bail!("stream closed before a complete frame arrived"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn registry_scopes_tunnels_to_terminal_tokens_and_cancels() {
        let registry = TunnelRegistry::default();
        let token = [7; wire::SESSION_TOKEN_LEN];
        let other = [8; wire::SESSION_TOKEN_LEN];
        let (offer, _) = registry.register(token, 8000).unwrap();
        let target = registry.lookup(&token, &offer.id).unwrap();
        assert_eq!(target.port, 8000);
        assert!(registry.lookup(&other, &offer.id).is_none());
        assert_eq!(registry.offers_for(&token), vec![offer]);
        let mut cancelled = target.cancel;
        registry.remove(offer.id);
        assert!(*cancelled.borrow_and_update());
    }

    #[test]
    fn registry_limits_active_tunnels_per_session() {
        let registry = TunnelRegistry::default();
        let token = [7; wire::SESSION_TOKEN_LEN];
        for port in 1..=MAX_ACTIVE_TUNNELS_PER_SESSION as u16 {
            registry.register(token, port).unwrap();
        }
        assert!(registry.register(token, 9000).is_err());
        assert!(
            registry
                .register([8; wire::SESSION_TOKEN_LEN], 9000)
                .is_ok()
        );
    }

    #[test]
    fn separate_connections_share_one_tunnel_limiter() {
        let registry = TunnelRegistry::default();
        let token = [7; wire::SESSION_TOKEN_LEN];
        let (offer, _) = registry.register(token, 8000).unwrap();
        let first = registry.lookup(&token, &offer.id).unwrap();
        let second = registry.lookup(&token, &offer.id).unwrap();
        let permits: Vec<_> = (0..MAX_CONCURRENT_CONNECTIONS)
            .map(|_| first.permits.clone().try_acquire_owned().unwrap())
            .collect();
        assert!(second.permits.clone().try_acquire_owned().is_err());
        drop(permits);
        assert!(second.permits.clone().try_acquire_owned().is_ok());
    }

    #[tokio::test]
    async fn control_registration_rejects_wrong_capability() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let addr = listener.local_addr().unwrap();
        let client = tokio::spawn(async move {
            let mut stream = TcpStream::connect(addr).await.unwrap();
            stream.write_all(CONTROL_MAGIC).await.unwrap();
            stream.write_all(&[2; CONTROL_SECRET_LEN]).await.unwrap();
            stream.write_u16(8000).await.unwrap();
        });
        let (mut stream, _) = listener.accept().await.unwrap();
        let error = read_control_registration(&mut stream, &[1; CONTROL_SECRET_LEN])
            .await
            .unwrap_err();
        assert!(error.to_string().contains("capability"));
        client.await.unwrap();
    }

    #[tokio::test]
    async fn traffic_events_round_trip() {
        let (mut left, mut right) = tokio::io::duplex(128);
        let expected = TunnelEvent::Closed {
            connection: 4,
            uploaded: 1024,
            downloaded: 2048,
        };
        write_event(&mut left, expected).await.unwrap();
        assert_eq!(read_event(&mut right).await.unwrap(), expected);
    }

    #[test]
    fn formats_traffic_counts() {
        assert_eq!(format_bytes(12), "12 B");
        assert_eq!(format_bytes(1536), "1.5 KiB");
        assert_eq!(format_bytes(2 * 1024 * 1024), "2.0 MiB");
    }
}
