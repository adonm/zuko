use anyhow::{Context, Result, anyhow};
use argon2::{Algorithm, Argon2, Params, Version};
use iroh::{Endpoint, EndpointAddr, endpoint::presets};
use iroh_tickets::endpoint::EndpointTicket;
use n0_future::{StreamExt, boxed::BoxStream, task, time::Duration};
use serde::Serialize;
use sha2::{Digest, Sha256};
use tokio::io::AsyncReadExt as _;
use tracing::level_filters::LevelFilter;
use tracing_subscriber_wasm::MakeConsoleWriter;
use wasm_bindgen::{JsError, prelude::wasm_bindgen};
use wasm_streams::{ReadableStream, readable::sys::ReadableStream as JsReadableStream};

const ALPN_V2: &[u8] = b"zuko/2";
const HANDOFF_ALPN: &[u8] = b"zuko/handoff/1";
const SESSION_TOKEN_LEN: usize = 16;
const MAX_PAYLOAD_LEN: usize = u16::MAX as usize;
const MAX_HANDOFF_PAYLOAD: usize = 8 * 1024;
const KDF_SALT: &[u8] = b"zuko-share-handoff-v1";

const TYPE_DATA: u8 = 0x00;
const TYPE_RESIZE: u8 = 0x01;
const TYPE_PING: u8 = 0x04;
const TYPE_PONG: u8 = 0x05;
const TYPE_ATTACH: u8 = 0x06;
const TYPE_ATTACHED: u8 = 0x07;
const TYPE_AUTHORIZE: u8 = 0x08;
const TYPE_ERROR: u8 = 0x09;

type SessionToken = [u8; SESSION_TOKEN_LEN];

#[wasm_bindgen(start)]
fn start() {
    console_error_panic_hook::set_once();
    let _ = tracing_subscriber::fmt()
        .with_max_level(LevelFilter::INFO)
        .with_writer(MakeConsoleWriter::default().map_trace_level_to(tracing::Level::DEBUG))
        .without_time()
        .with_ansi(false)
        .try_init();
}

#[wasm_bindgen]
pub struct ZukoClient {
    endpoint: Endpoint,
    secret_key: iroh::SecretKey,
}

#[wasm_bindgen]
impl ZukoClient {
    pub async fn spawn(client_key: Vec<u8>) -> Result<ZukoClient, JsError> {
        let secret = secret_from_bytes(&client_key).map_err(to_js_err)?;
        let endpoint = Endpoint::builder(presets::N0)
            .secret_key(secret.clone())
            .bind()
            .await
            .map_err(to_js_err)?;
        endpoint.online().await;
        Ok(Self {
            endpoint,
            secret_key: secret,
        })
    }

    pub fn endpoint_id(&self) -> String {
        self.endpoint.id().to_string()
    }

    pub async fn claim(
        &self,
        code: String,
        label: String,
        timeout_secs: u64,
    ) -> Result<ClaimResult, JsError> {
        claim(
            &self.endpoint,
            &self.secret_key,
            &code,
            &label,
            timeout_secs,
        )
        .await
        .map_err(to_js_err)
    }

    pub async fn connect(
        &self,
        ticket: String,
        client_key: Vec<u8>,
        cols: u16,
        rows: u16,
        pixel_width: u16,
        pixel_height: u16,
    ) -> Result<ZukoSession, JsError> {
        connect(
            self.endpoint.clone(),
            &ticket,
            &client_key,
            cols,
            rows,
            pixel_width,
            pixel_height,
        )
        .await
        .map_err(to_js_err)
    }
}

#[wasm_bindgen]
#[derive(Debug, Clone)]
pub struct ClaimResult {
    label: String,
    ticket: String,
    token_hex: String,
}

#[wasm_bindgen]
impl ClaimResult {
    #[wasm_bindgen(getter)]
    pub fn label(&self) -> String {
        self.label.clone()
    }

    #[wasm_bindgen(getter)]
    pub fn ticket(&self) -> String {
        self.ticket.clone()
    }

    #[wasm_bindgen(getter, js_name = tokenHex)]
    pub fn token_hex(&self) -> String {
        self.token_hex.clone()
    }
}

#[wasm_bindgen]
pub struct ZukoSession {
    commands: async_channel::Sender<SessionCommand>,
    events: Option<async_channel::Receiver<SessionEvent>>,
    connection: iroh::endpoint::Connection,
}

#[wasm_bindgen]
impl ZukoSession {
    pub fn events(&mut self) -> Result<JsReadableStream, JsError> {
        let events = self
            .events
            .take()
            .ok_or_else(|| JsError::new("events stream already taken"))?;
        Ok(into_js_readable_stream(Box::pin(events)))
    }

    pub async fn send(&self, data: Vec<u8>) -> Result<(), JsError> {
        match self
            .commands
            .send(SessionCommand::Frame(data_frame(&data)))
            .await
        {
            Ok(()) => Ok(()),
            // Browser input/resize can race with a closed Iroh stream. Treat it
            // as an idempotent no-op so stale key events don't surface as
            // unhandled promise rejections in the UI.
            Err(_) => Ok(()),
        }
    }

    pub async fn resize(
        &self,
        cols: u16,
        rows: u16,
        pixel_width: u16,
        pixel_height: u16,
    ) -> Result<(), JsError> {
        match self
            .commands
            .send(SessionCommand::Frame(resize_frame(
                cols,
                rows,
                pixel_width,
                pixel_height,
            )))
            .await
        {
            Ok(()) => Ok(()),
            Err(_) => Ok(()),
        }
    }

    pub fn close(&self) {
        let _ = self.commands.try_send(SessionCommand::Close);
        self.connection.close(0u32.into(), b"browser closed");
    }
}

enum SessionCommand {
    Frame(Vec<u8>),
    Close,
}

#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
enum SessionEvent {
    Connected,
    Attached { token_hex: String },
    Data { bytes: Vec<u8> },
    Error { code: u8, message: String },
    Closed { error: Option<String> },
}

async fn claim(
    endpoint: &Endpoint,
    client_secret: &iroh::SecretKey,
    code: &str,
    label: &str,
    timeout_secs: u64,
) -> Result<ClaimResult> {
    let secret = derive_handoff_key(code)?;
    let node_id = secret.public();
    let conn = dial_throwaway(endpoint, node_id, timeout_secs).await?;

    let mut recv = conn.accept_uni().await.context("accept handoff stream")?;
    let payload = read_to_end(&mut recv, MAX_HANDOFF_PAYLOAD).await?;
    let payload = String::from_utf8(payload).context("handoff payload wasn't utf-8")?;
    let (remote_label, ticket) = payload
        .split_once('\n')
        .unwrap_or(("host", payload.as_str()));
    let remote_label = sanitize_label(remote_label);
    let ticket = ticket.trim().to_string();
    if ticket.is_empty() {
        anyhow::bail!("received an empty ticket");
    }

    let ticket_addr = endpoint_addr(&ticket)?;
    let token = derive_session_token(client_secret, &ticket_addr);
    if let Ok(mut send) = conn.open_uni().await {
        send.write_all(&authorize_frame(token, &sanitize_label(label)))
            .await
            .context("send pairing client authorization")?;
        send.finish()?;
        // Match the native claimer: give the host a chance to accept/read the
        // AUTHORIZE uni stream before we close the handoff connection. Closing
        // immediately races the host's `accept_uni()` and leaves the browser's
        // token out of `authorized_clients`, so the later shell ATTACH is
        // rejected as "connection lost".
        n0_future::future::race(n0_future::time::sleep(Duration::from_secs(2)), async {
            let _ = send.stopped().await;
        })
        .await;
    }
    conn.close(0u32.into(), b"claimed");

    Ok(ClaimResult {
        label: remote_label,
        ticket,
        token_hex: hex(&token),
    })
}

async fn connect(
    endpoint: Endpoint,
    ticket: &str,
    client_key: &[u8],
    cols: u16,
    rows: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> Result<ZukoSession> {
    let addr = endpoint_addr(ticket)?;
    let secret = secret_from_bytes(client_key)?;
    let token = derive_session_token(&secret, &addr);
    let connection = endpoint.connect(addr, ALPN_V2).await.context("dial host")?;
    let (mut send, mut recv) = connection.open_bi().await.context("open zuko stream")?;
    send.write_all(&attach_frame(token, cols, rows, pixel_width, pixel_height))
        .await
        .context("send ATTACH")?;

    let (command_tx, command_rx) = async_channel::bounded::<SessionCommand>(128);
    let (event_tx, event_rx) = async_channel::bounded::<SessionEvent>(128);
    event_tx.send(SessionEvent::Connected).await.ok();

    task::spawn({
        let event_tx = event_tx.clone();
        async move {
            while let Ok(cmd) = command_rx.recv().await {
                match cmd {
                    SessionCommand::Frame(frame) => {
                        if let Err(e) = send.write_all(&frame).await {
                            event_tx
                                .send(SessionEvent::Closed {
                                    error: Some(e.to_string()),
                                })
                                .await
                                .ok();
                            return;
                        }
                    }
                    SessionCommand::Close => {
                        let _ = send.finish();
                        return;
                    }
                }
            }
        }
    });

    task::spawn({
        let command_tx = command_tx.clone();
        async move {
            let mut pending = Vec::new();
            let mut buf = [0u8; 8192];
            loop {
                match recv.read(&mut buf).await {
                    Ok(None) => {
                        event_tx
                            .send(SessionEvent::Closed { error: None })
                            .await
                            .ok();
                        return;
                    }
                    Ok(Some(n)) => {
                        pending.extend_from_slice(&buf[..n]);
                        while let Some(frame) = try_parse_frame(&mut pending) {
                            match frame.typ {
                                TYPE_DATA => event_tx
                                    .send(SessionEvent::Data {
                                        bytes: frame.payload,
                                    })
                                    .await
                                    .ok(),
                                TYPE_ATTACHED => parse_attached(&frame.payload)
                                    .map(|token| SessionEvent::Attached {
                                        token_hex: hex(&token),
                                    })
                                    .map(|event| event_tx.try_send(event).ok())
                                    .flatten(),
                                TYPE_ERROR => parse_error(&frame.payload)
                                    .map(|(code, message)| SessionEvent::Error { code, message })
                                    .map(|event| event_tx.try_send(event).ok())
                                    .flatten(),
                                TYPE_PING => command_tx
                                    .try_send(SessionCommand::Frame(pong_frame(decode_nonce(
                                        &frame.payload,
                                    ))))
                                    .ok(),
                                _ => None,
                            };
                        }
                    }
                    Err(e) => {
                        event_tx
                            .send(SessionEvent::Closed {
                                error: Some(e.to_string()),
                            })
                            .await
                            .ok();
                        return;
                    }
                }
            }
        }
    });

    Ok(ZukoSession {
        commands: command_tx,
        events: Some(event_rx),
        connection,
    })
}

async fn dial_throwaway(
    endpoint: &Endpoint,
    node_id: iroh::PublicKey,
    timeout_secs: u64,
) -> Result<iroh::endpoint::Connection> {
    let started = js_sys::Date::now();
    loop {
        match endpoint.connect(node_id, HANDOFF_ALPN).await {
            Ok(conn) => return Ok(conn),
            Err(e) => {
                if timeout_secs > 0
                    && (js_sys::Date::now() - started) / 1000.0 >= timeout_secs as f64
                {
                    return Err(anyhow!(e)).context(format!("timed out after {timeout_secs}s"));
                }
                n0_future::time::sleep(Duration::from_secs(2)).await;
            }
        }
    }
}

fn endpoint_addr(ticket: &str) -> Result<EndpointAddr> {
    let ticket = ticket
        .parse::<EndpointTicket>()
        .with_context(|| "that doesn't look like a ticket")?;
    Ok(ticket.into())
}

fn secret_from_bytes(bytes: &[u8]) -> Result<iroh::SecretKey> {
    if bytes.len() != 32 {
        anyhow::bail!("client key must be 32 bytes");
    }
    let mut arr = [0u8; 32];
    arr.copy_from_slice(bytes);
    Ok(iroh::SecretKey::from_bytes(&arr))
}

fn normalize_code(code: &str) -> String {
    code.trim()
        .to_lowercase()
        .chars()
        .filter(char::is_ascii_lowercase)
        .collect()
}

fn derive_handoff_key(code: &str) -> Result<iroh::SecretKey> {
    let params = Params::new(
        Params::DEFAULT.m_cost(),
        Params::DEFAULT.t_cost(),
        Params::DEFAULT.p_cost(),
        Some(32),
    )
    .expect("valid Argon2 params");
    let kdf = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    let material = normalize_code(code);
    let mut seed = [0u8; 32];
    kdf.hash_password_into(material.as_bytes(), KDF_SALT, &mut seed)
        .map_err(|e| anyhow!("argon2 derivation failed: {e}"))?;
    Ok(iroh::SecretKey::from_bytes(&seed))
}

fn derive_session_token(secret: &iroh::SecretKey, addr: &EndpointAddr) -> SessionToken {
    let mut hasher = Sha256::new();
    hasher.update(b"zuko-session-token-v1");
    hasher.update(secret.to_bytes());
    hasher.update(addr.id.as_bytes());
    let out = hasher.finalize();
    let mut tok = [0u8; SESSION_TOKEN_LEN];
    tok.copy_from_slice(&out[..SESSION_TOKEN_LEN]);
    tok
}

struct ParsedFrame {
    typ: u8,
    payload: Vec<u8>,
}

fn frame(typ: u8, payload: &[u8]) -> Vec<u8> {
    assert!(payload.len() <= MAX_PAYLOAD_LEN);
    let mut f = Vec::with_capacity(3 + payload.len());
    f.push(typ);
    f.extend_from_slice(&(payload.len() as u16).to_be_bytes());
    f.extend_from_slice(payload);
    f
}

fn data_frame(bytes: &[u8]) -> Vec<u8> {
    frame(TYPE_DATA, bytes)
}

fn resize_frame(cols: u16, rows: u16, pixel_width: u16, pixel_height: u16) -> Vec<u8> {
    let payload = [
        cols.to_be_bytes(),
        rows.to_be_bytes(),
        pixel_width.to_be_bytes(),
        pixel_height.to_be_bytes(),
    ]
    .concat();
    frame(TYPE_RESIZE, &payload)
}

fn attach_frame(
    token: SessionToken,
    cols: u16,
    rows: u16,
    pixel_width: u16,
    pixel_height: u16,
) -> Vec<u8> {
    let mut payload = Vec::with_capacity(SESSION_TOKEN_LEN + 8);
    payload.extend_from_slice(&token);
    payload.extend_from_slice(&cols.to_be_bytes());
    payload.extend_from_slice(&rows.to_be_bytes());
    payload.extend_from_slice(&pixel_width.to_be_bytes());
    payload.extend_from_slice(&pixel_height.to_be_bytes());
    frame(TYPE_ATTACH, &payload)
}

fn authorize_frame(token: SessionToken, label: &str) -> Vec<u8> {
    let label = label.as_bytes();
    let max_label = MAX_PAYLOAD_LEN.saturating_sub(SESSION_TOKEN_LEN);
    let label = &label[..label.len().min(max_label)];
    let mut payload = Vec::with_capacity(SESSION_TOKEN_LEN + label.len());
    payload.extend_from_slice(&token);
    payload.extend_from_slice(label);
    frame(TYPE_AUTHORIZE, &payload)
}

fn pong_frame(nonce: u64) -> Vec<u8> {
    frame(TYPE_PONG, &nonce.to_be_bytes())
}

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

fn parse_attached(payload: &[u8]) -> Option<SessionToken> {
    if payload.len() != SESSION_TOKEN_LEN {
        return None;
    }
    let mut token = [0u8; SESSION_TOKEN_LEN];
    token.copy_from_slice(payload);
    Some(token)
}

fn parse_error(payload: &[u8]) -> Option<(u8, String)> {
    let (&code, rest) = payload.split_first()?;
    Some((code, String::from_utf8_lossy(rest).into_owned()))
}

fn decode_nonce(payload: &[u8]) -> u64 {
    if payload.len() >= 8 {
        u64::from_be_bytes(payload[..8].try_into().unwrap_or([0u8; 8]))
    } else {
        0
    }
}

async fn read_to_end<R: tokio::io::AsyncRead + Unpin>(r: &mut R, max: usize) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    let mut buf = [0u8; 1024];
    loop {
        let n = r.read(&mut buf).await?;
        if n == 0 {
            return Ok(out);
        }
        if out.len() + n > max {
            anyhow::bail!("peer sent more than {max} bytes");
        }
        out.extend_from_slice(&buf[..n]);
    }
}

fn sanitize_label(s: &str) -> String {
    let cleaned: String = s
        .trim()
        .chars()
        .map(|c| if c.is_whitespace() { '-' } else { c })
        .collect();
    let cleaned = cleaned.trim_matches('-');
    if cleaned.is_empty() || cleaned.starts_with('#') {
        "host".to_string()
    } else {
        cleaned.to_string()
    }
}

fn hex(bytes: &[u8]) -> String {
    const CHARS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        out.push(CHARS[(b >> 4) as usize] as char);
        out.push(CHARS[(b & 0x0f) as usize] as char);
    }
    out
}

fn to_js_err(err: impl Into<anyhow::Error>) -> JsError {
    let err: anyhow::Error = err.into();
    JsError::new(&err.to_string())
}

fn into_js_readable_stream<T: Serialize + 'static>(stream: BoxStream<T>) -> JsReadableStream {
    let stream = stream.map(|event| Ok(serde_wasm_bindgen::to_value(&event).unwrap()));
    ReadableStream::from_stream(stream).into_raw()
}
