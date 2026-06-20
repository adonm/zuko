//! `zuko share` / `zuko claim` — croc-style ticket handoff over Iroh.
//!
//! This is the **only** way a new device learns a host's ticket: the host
//! operator runs `zuko share`, reads off a short memorable code, and the new
//! device runs `zuko claim <code>` to fetch the real ticket over an
//! end-to-end encrypted Iroh connection — then saves it and connects, all in
//! one command. There is no `zuko add <name> <ticket>` any more, because that
//! path is exactly how long-lived bearer secrets leak (shell history,
//! scrollback, copy/paste into chat).
//!
//! ## How it stays safe
//!
//! The memorable code is a **one-time symmetric secret** for the handoff (the
//! croc model), never the host's identity. `zuko share` derives a *throwaway*
//! Iroh [`SecretKey`] from the code, binds a *second*, ephemeral endpoint with
//! that key, and uses it solely to deliver the host's real ticket. The real
//! host key (at `~/.config/zuko/key`) is unrelated and stays strong.
//!
//! Both sides derive the same key from the code, so:
//! - the host's throwaway endpoint proves ownership of the derived private key
//!   via the QUIC/TLS handshake;
//! - the claimer dials the throwaway node id (= the derived public key) and
//!   reads the ticket off a single unidirectional stream.
//!
//! Whoever has the code can claim — that's the point. The code has ~28 bits of
//! entropy, memory-hardened through Argon2id (see [`crate::code`]), which is
//! far beyond reach for online guessing during the minutes-long window before
//! `zuko share` exits after the first claim.
//!
//! ## Wire (ALPN `zuko/handoff/1`, one uni stream host -> client)
//!
//! The host opens a unidirectional stream and writes a tiny UTF-8 payload,
//! then closes the send side:
//!
//! ```text
//! <label>\n<ticket>
//! ```
//!
//! `label` has no newlines (sanitised), and tickets never contain whitespace,
//! so splitting on the first `\n` is unambiguous.

use anyhow::{anyhow, bail, Context, Result};
use backon::{ConstantBuilder, Retryable};
use iroh::{endpoint::presets, Endpoint};
use std::io::IsTerminal;
use std::time::Duration;
use tracing::{info, warn};

use crate::code::{default_label, derive_key, generate_code, sanitize_label};
use crate::ticket_file::{read_current_ticket, wait_for_current_ticket};
use crate::ShareArgs;

/// ALPN for the throwaway handoff endpoint (distinct from the terminal `zuko/1`).
const HANDOFF_ALPN: &[u8] = b"zuko/handoff/1";

/// Cap a handoff payload so a misbehaving peer can't make us allocate forever.
const MAX_HANDOFF_PAYLOAD: usize = 8 * 1024;

// ────────────────────────── share (host side) ──────────────────────────────

/// Resolve the live ticket for `zuko share`, offering to install + start the
/// host service if `current_ticket` is missing (interactive / TTY only).
///
/// `share` needs a running host to hand a ticket off — without one there's
/// nothing to share. Rather than bail with a hint and make the user run a
/// second command, on a TTY we offer to install + start the service in place:
/// one prompt, then we wait for the ticket the freshly-started host writes.
/// Non-interactive invocations (scripts, CI) get the original error so they
/// fail loudly instead of hanging on a prompt.
async fn ensure_current_ticket() -> Result<String> {
    match read_current_ticket() {
        Ok(ticket) => Ok(ticket),
        Err(read_err) => {
            if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
                // Non-interactive: surface the underlying read error so a
                // script sees *why* share can't proceed.
                return Err(read_err);
            }
            // Interactive: offer the one-command fix. Default to yes — the
            // user ran `zuko share`, so they want to share; the only reason
            // we're here is the host isn't up.
            let install = inquire::Confirm::new(
                "The host service isn't running (no current_ticket). \
                 Install + start it now?",
            )
            .with_default(true)
            .with_help_message("writes the systemd/launchd user unit + starts `zuko host`")
            .prompt();
            let accepted = match install {
                Ok(yes) => yes,
                Err(inquire::InquireError::OperationCanceled)
                | Err(inquire::InquireError::OperationInterrupted) => false,
                Err(e) => {
                    // Picker infra itself failed (rare). Surface and bail
                    // rather than guessing intent.
                    return Err(anyhow!("prompt failed: {e}")).with_context(|| read_err);
                }
            };
            if !accepted {
                return Err(read_err).context("declined to install the host service");
            }
            // Install + start. The started service runs `zuko host`, which
            // takes a few seconds to bind + write current_ticket.
            crate::service::install(&crate::service::InstallArgs::default())
                .context("install host service")?;
            wait_for_current_ticket(Duration::from_secs(60)).context(
                "host service was installed but didn't produce a ticket in time",
            )
        }
    }
}

/// Serve this host's ticket to the first claimer (or `--count` claimers) over
/// a throwaway, code-derived endpoint. Reads the live ticket from
/// `~/.config/zuko/current_ticket` unless `--ticket` is given.
pub async fn share(args: &ShareArgs) -> Result<()> {
    // `zuko share` is a foreground server; logs go to stderr so the code on
    // stdout stays clean for piping/copying.
    tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "zuko=info,iroh=warn".into()),
        )
        .init();

    let ticket = match &args.ticket {
        Some(t) => t.trim().to_string(),
        None => ensure_current_ticket().await?,
    };
    let label_owned = args.label.clone().unwrap_or_else(default_label);
    let label = sanitize_label(&label_owned);

    let code = generate_code();
    let secret = derive_key(&code)?;
    let node_id = secret.public();

    let endpoint = Endpoint::builder(presets::N0)
        .secret_key(secret)
        .alpns(vec![HANDOFF_ALPN.to_vec()])
        .bind()
        .await
        .context("bind handoff endpoint")?;
    endpoint.online().await;

    // The claimer dials this throwaway endpoint by node id alone, resolved
    // through the N0 DNS address-lookup. iroh publishes the endpoint's address
    // to that lookup shortly after coming online; give it a short head start so
    // a fast claimer doesn't lose a race with propagation.
    tokio::time::sleep(Duration::from_secs(2)).await;

    eprintln!();
    eprintln!("share this code (serves {n}, then exits):", n = args.count);
    println!("{code}");
    eprintln!("  on the other machine:");
    eprintln!("    zuko claim {code}");
    let timeout_hint = if args.timeout > 0 {
        format!(", or wait {}s", args.timeout)
    } else {
        String::new()
    };
    eprintln!("  (waiting — ctrl-c to cancel{timeout_hint})");
    eprintln!();
    info!(%node_id, "serving handoff on alpn {:?}", String::from_utf8_lossy(HANDOFF_ALPN));

    let max = args.count.max(1);
    let mut claims = 0usize;
    loop {
        let incoming = match accept_with_timeout(&endpoint, args.timeout).await? {
            AcceptOutcome::Incoming(i) => i,
            AcceptOutcome::Closed => break,
            AcceptOutcome::TimedOut => {
                eprintln!("share: timed out after {}s", args.timeout);
                break;
            }
        };
        match serve_handoff(*incoming, &label, &ticket).await {
            Ok(()) => {
                claims += 1;
                eprintln!("claim {claims}/{max} served");
                if claims >= max {
                    break;
                }
            }
            Err(e) => {
                // One bad peer shouldn't kill a multi-claim share; keep waiting.
                warn!("handoff to peer failed: {e:#}");
            }
        }
    }
    eprintln!("share: done");
    Ok(())
}

enum AcceptOutcome {
    // `iroh::endpoint::Incoming` is ~392 bytes; box it so the two tiny
    // sentinel variants don't balloon the enum's footprint.
    Incoming(Box<iroh::endpoint::Incoming>),
    Closed,
    TimedOut,
}

/// Wrap `endpoint.accept()` in an optional overall timeout. `timeout_secs == 0`
/// means wait forever (until the endpoint closes or Ctrl-C).
async fn accept_with_timeout(endpoint: &Endpoint, timeout_secs: u64) -> Result<AcceptOutcome> {
    if timeout_secs == 0 {
        return Ok(match endpoint.accept().await {
            Some(i) => AcceptOutcome::Incoming(Box::new(i)),
            None => AcceptOutcome::Closed,
        });
    }
    match tokio::time::timeout(Duration::from_secs(timeout_secs), endpoint.accept()).await {
        Ok(Some(i)) => Ok(AcceptOutcome::Incoming(Box::new(i))),
        Ok(None) => Ok(AcceptOutcome::Closed),
        Err(_) => Ok(AcceptOutcome::TimedOut),
    }
}

async fn serve_handoff(
    incoming: iroh::endpoint::Incoming,
    label: &str,
    ticket: &str,
) -> Result<()> {
    let conn = incoming
        .accept()
        .context("accept handoff connection")?
        .await
        .context("complete handoff connection")?;
    // Host is the initiator: open_uni + write makes the client's accept_uni
    // resolve (a stream is only "accepted" once the initiator sends data).
    let mut send = conn.open_uni().await.context("open handoff stream")?;
    let payload = format!("{label}\n{ticket}");
    send.write_all(payload.as_bytes())
        .await
        .context("send handoff payload")?;
    send.finish()?;
    drop(send);

    // Hold the connection open briefly so the client has time to read the
    // payload. The client closes the connection as soon as it finishes
    // reading (see `claim`); once it does, this resolves immediately.
    // Returning immediately would tear down the endpoint and race the
    // client's `accept_uni`, sometimes aborting the stream before the
    // payload is read — manifesting as a spurious "timed out". The bound
    // is defense-in-depth: without it, a buggy or hostile peer that holds
    // the connection open (or a future regression in `claim`'s close)
    // would hang `share` indefinitely. Five seconds is far longer than
    // the few-hundred-byte payload needs to be ack'd across any link.
    let _ = tokio::time::timeout(Duration::from_secs(5), conn.closed()).await;
    Ok(())
}

// ────────────────────────── claim (client side) ────────────────────────────

/// Resolve a `zuko share` code to the host's real ticket, **save it** under a
/// name, and (by default) connect immediately. Saving is mandatory — the
/// long-lived ticket never goes to stdout. Bare `zuko <code>` is the
/// shortcut for this command on a first-run client.
pub async fn claim(
    code: &str,
    name: Option<String>,
    no_connect: bool,
    timeout_secs: u64,
) -> Result<()> {
    // No tracing subscriber here: if we connect, the terminal goes raw and any
    // log output would corrupt it. Status goes to stderr; nothing to stdout.
    let secret = derive_key(code)?;
    let node_id = secret.public();

    let endpoint = Endpoint::builder(presets::N0)
        .bind()
        .await
        .context("bind local endpoint")?;
    endpoint.online().await;

    // The throwaway endpoint is dialed by node id and resolved via the N0 DNS
    // address-lookup, which can lag a few seconds behind `zuko share` coming
    // online. Retry the dial with backoff so a fast claimer rides out the
    // propagation delay instead of failing immediately.
    let conn = dial_throwaway(&endpoint, node_id, timeout_secs)
        .await
        .context(
            "couldn't reach the sharing host — is `zuko share` still running and the code correct?",
        )?;

    let mut recv = conn.accept_uni().await.context("accept handoff stream")?;
    let payload = read_to_end(&mut recv, MAX_HANDOFF_PAYLOAD).await?;
    // We have the payload; actively close the handoff connection so the host's
    // `serve_handoff` returns and `share` can exit (or serve the next claim).
    // Without this, `conn` is held in scope by `claim` until it returns — and
    // when connecting that's when the user logs out of the terminal. Iroh's
    // keepalive pings keep the connection alive in the meantime, so the host
    // never sees a close and `share` hangs for the whole session. (The e2e
    // test misses this because it uses `--no-connect`, so `claim` returns
    // immediately and `conn` drops.)
    conn.close(0u32.into(), b"claimed");
    let payload = String::from_utf8(payload).context("handoff payload wasn't utf-8")?;

    let (label, ticket) = payload
        .split_once('\n')
        .unwrap_or(("host", payload.as_str()));
    // `share` sanitizes its label before sending, but treat the received
    // bytes as untrusted — a misbehaving peer could send whitespace or a
    // leading '#' that would then make `store::add` reject the save name.
    // Sanitizing here keeps the two sides symmetric.
    let label = sanitize_label(label);
    let ticket = ticket.trim();
    if ticket.is_empty() {
        bail!("received an empty ticket");
    }

    eprintln!("claimed host: {label}");
    // Always save — the raw ticket is a long-lived bearer secret and must not
    // be printed to stdout (it would land in scrollback / shell history /
    // piped files).
    let save_name = name.unwrap_or(label);
    crate::store::add(&save_name, ticket)?;
    eprintln!("saved as {save_name}  (run `zuko {save_name}` to reconnect)");

    if !no_connect {
        crate::client::connect(ticket).await?;
    }
    Ok(())
}

/// Dial the throwaway host, retrying with constant backoff. The throwaway
/// endpoint is resolved via the N0 DNS address-lookup, which can lag a couple
/// seconds behind `zuko share` coming online; backon handles the tenacity.
///
/// `timeout_secs > 0` bounds the *total* wall time (across all attempts) via an
/// outer deadline; `timeout_secs == 0` retries indefinitely (matches the
/// `Claim --timeout` help and `share`'s `--timeout 0` semantics).
async fn dial_throwaway(
    endpoint: &Endpoint,
    node_id: iroh::PublicKey,
    timeout_secs: u64,
) -> Result<iroh::endpoint::Connection> {
    // Constant 2s between attempts: long enough for DNS propagation, short
    // enough that the outer deadline still allows many tries.
    const DELAY: Duration = Duration::from_secs(2);

    // `timeout_secs == 0` means "wait forever" — drop the retry cap so the
    // only bound is the user's patience (or Ctrl-C). With a deadline we still
    // cap retries so the backoff loop terminates even if every dial fails
    // instantly; without one, the user has explicitly opted into forever.
    let retry = (|| async { endpoint.connect(node_id, HANDOFF_ALPN).await }).retry(
        ConstantBuilder::default()
            .with_delay(DELAY)
            .with_max_times(if timeout_secs == 0 {
                usize::MAX
            } else {
                // ~2x the worst-case wall time (DELAY * attempts) so the
                // outer deadline is always the binding constraint.
                30
            }),
    );

    if timeout_secs == 0 {
        return retry.await.context("dial throwaway endpoint");
    }
    tokio::time::timeout(Duration::from_secs(timeout_secs), retry)
        .await
        .map_err(|_| anyhow::anyhow!("timed out after {timeout_secs}s"))?
        .context("dial throwaway endpoint")
}

/// Read a uni recv stream to end, bailing if it exceeds `max` bytes.
async fn read_to_end(recv: &mut iroh::endpoint::RecvStream, max: usize) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    let mut tmp = [0u8; 4096];
    loop {
        match recv.read(&mut tmp).await {
            Ok(Some(n)) => {
                buf.extend_from_slice(&tmp[..n]);
                if buf.len() > max {
                    bail!("handoff payload exceeded {max} bytes");
                }
            }
            Ok(None) => return Ok(buf),
            Err(e) => return Err(e).context("read handoff payload"),
        }
    }
}
