//! zuko — reach your machines over [Iroh](https://www.iroh.computer/).
//!
//! One binary, a few jobs:
//! - `zuko host`      serve this machine's shell over Iroh (what the iOS app
//!   and other clients dial into).
//! - `zuko install`   install `host` as a systemd/launchd user service.
//!   `uninstall` undoes it. The service runs `zuko host` under the user's key.
//! - `zuko share`     mint a one-time code that lets a new device pair.
//! - `zuko connect`   attach a local terminal to a saved host by name.
//!   Bare `zuko` is a shortcut — and it also accepts a pairing code, so the
//!   very first connection is `zuko <code>`.
//!
//! New hosts are added only through the OTP-style pairing (`share`/`claim`):
//! the host's full ticket stays off the CLI surface (no arguments, no stdin,
//! nothing printed by `zuko host`).
//!
//! Saved hosts (`zuko ls`/`rm`) live at `~/.config/zuko/hosts`, mirroring the
//! iOS app's connection list.
//!
//! The host/client/handoff/protocol logic lives in the library (`src/lib.rs`);
//! this file is just the CLI dispatcher. The library also builds an optional
//! FFI surface (`--features ffi`) for mobile clients — see [`zuko::ffi`].
//!
//! ## Wire protocol (single bidirectional Iroh stream, ALPN `zuko/1`)
//!
//! Every message is length-prefixed so the frame types share an ordering and
//! nothing leaks into the terminal as in-band escape sequences:
//!
//! ```text
//! [type: u8][len: u16 big-endian][payload: `len` bytes]
//!   0x00 DATA    payload = raw terminal bytes (keystrokes up, PTY output down)
//!   0x01 RESIZE  payload = [cols: u16 BE][rows: u16 BE]   (client -> host, also first frame)
//!   0x04 PING    payload = [nonce: u64 BE]   (bidirectional heartbeat)
//!   0x05 PONG    payload = [nonce: u64 BE]   (bidirectional heartbeat)
//! ```
//!
//! v0.6 dropped session resume (the mosh-style ring buffer + session
//! registry) — each connection mints a fresh PTY on the host, killed when
//! the connection ends. Users who want resumability run `tmux`/`zellij`/
//! `screen` inside the zuko session.

use anyhow::Result;
use clap::{Args, Parser, Subcommand};
use inquire::{InquireError, Select};
use std::io::IsTerminal;

use zuko::{HostArgs, ShareArgs, client, code, handoff, host, service, store};

#[derive(Parser)]
#[command(
    name = "zuko",
    version,
    about = "Reach your machines over Iroh — serve a shell or connect to one"
)]
struct Cli {
    /// Shortcut: a saved host name to connect to, or a `zuko share` pairing
    /// code (an adjective-noun pair like `iridescent-hilton`) to claim. zuko
    /// tells them apart by shape.
    name: Option<String>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Serve this machine's shell over Iroh. Other devices pair with `zuko
    /// claim` against a code from `zuko share`.
    Host(HostArgs),

    /// Connect to a saved host by name.
    Connect {
        /// Saved host name (from `zuko ls`). Use `zuko claim <code>` to add one.
        name: String,
    },

    /// Install the host daemon as a user service (systemd on Linux, launchd
    /// on macOS).
    Install(InstallArgs),

    /// Stop and remove the host service. Leaves the key + saved hosts in
    /// `~/.config/zuko` so a later `zuko install` or `zuko host` resumes.
    Uninstall,

    /// List saved hosts.
    Ls,

    /// Remove a saved host by name.
    Rm { name: String },

    /// Hand this host's ticket to a new device via a short, memorable code.
    /// The other device runs `zuko claim <code>` (or bare `zuko <code>`) to
    /// fetch and save it.
    Share(ShareArgs),

    /// Claim a ticket from a `zuko share` code: fetch it, save it under a
    /// name, and (by default) connect immediately. Bare `zuko <code>` is the
    /// shorthand form (with default flags).
    Claim {
        /// The code printed by `zuko share`. Dashes, spaces, or bare letters
        /// all work; case is ignored.
        code: String,

        /// Save the claimed host under this name (default: the host's label).
        #[arg(long, value_name = "NAME")]
        r#as: Option<String>,

        /// Don't connect after claiming — just fetch + save.
        #[arg(long)]
        no_connect: bool,

        /// Give up reaching the sharing host after this many seconds
        /// (default 60; 0 = wait forever).
        #[arg(long, default_value_t = 60)]
        timeout: u64,
    },
}

#[derive(Args, Clone, Debug)]
struct InstallArgs {
    /// Install prefix for the wrapper (default `~/.local`).
    #[arg(long)]
    prefix: Option<std::path::PathBuf>,

    /// Persistent secret key path (default `~/.config/zuko/key`).
    #[arg(long)]
    key: Option<std::path::PathBuf>,

    /// Shell launched per connection (default `$SHELL`).
    #[arg(long)]
    shell: Option<String>,

    /// Don't auto-start the service after installing it.
    #[arg(long)]
    no_start: bool,
}

impl InstallArgs {
    /// Merge CLI overrides onto the platform defaults. Centralised here so
    /// `service::install` gets a fully-resolved config and the dispatch in
    /// `main` stays boring.
    fn resolve(self) -> service::InstallArgs {
        let mut args = service::InstallArgs::default();
        if let Some(prefix) = self.prefix {
            args.prefix = prefix;
        }
        if let Some(key) = self.key {
            args.key = key;
        }
        if let Some(shell) = self.shell {
            args.shell = shell;
        }
        args.no_start = self.no_start;
        args
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Some(Command::Host(args)) => host::run(args).await,
        Some(Command::Connect { name }) => connect_by_name(&name).await,
        Some(Command::Install(args)) => {
            service::install(&args.resolve())?;
            Ok(())
        }
        Some(Command::Uninstall) => {
            service::uninstall()?;
            Ok(())
        }
        Some(Command::Ls) => {
            store::list();
            Ok(())
        }
        Some(Command::Rm { name }) => {
            store::remove(&name)?;
            println!("removed {name}");
            Ok(())
        }
        Some(Command::Share(args)) => handoff::share(&args).await,
        Some(Command::Claim {
            code,
            r#as,
            no_connect,
            timeout,
        }) => handoff::claim(&code, r#as, no_connect, timeout).await,
        None => match cli.name {
            // Bare `zuko <input>`: the power-user shortcut. Distinguish a
            // saved-host name (the common case after the first claim) from a
            // raw `zuko share` code (the first-run case) by shape — saved
            // names never look like a petname adjective-noun code, so the
            // disambiguation is unambiguous. See [`code::looks_like_code`] for the rule.
            Some(input) => match store::lookup(input.trim()) {
                Some(_) => connect_by_name(input.trim()).await,
                None if code::looks_like_code(&input) => {
                    handoff::claim(
                        &input, /*as*/ None, /*no_connect*/ false, /*timeout*/ 60,
                    )
                    .await
                }
                None => {
                    // Neither a known name nor a code. Bail with the same
                    // hint `connect` gives so the next step is obvious.
                    store::lookup_ticket_or_bail(input.trim())?;
                    unreachable!("lookup_ticket_or_bail always bails")
                }
            },
            None => bare_zuko_menu().await,
        },
    }
}

/// Look up a saved host by name, connect, and on success promote it to the
/// front of the saved list (so `zuko` with no args surfaces hosts you
/// actually use). The touch is best-effort: a failure to rewrite the hosts
/// file must not undo a session that already connected.
async fn connect_by_name(name: &str) -> Result<()> {
    let ticket = store::lookup_ticket_or_bail(name)?;
    let result = client::connect(&ticket).await;
    if result.is_ok() {
        let _ = store::touch(name);
    }
    result
}

/// Bare `zuko` (no subcommand, no shorthand input). An actionable menu whose
/// shape branches on saved-hosts state and whether we're on a TTY:
///
/// - **No saved hosts** → first-run pairing/serve hint (unchanged).
/// - **Saved hosts, non-TTY** (piped/scripted) → name listing + hint, so
///   scripts don't hang waiting for picker input.
/// - **Saved hosts, TTY, exactly one** → connect to it directly (no point
///   showing a one-item picker).
/// - **Saved hosts, TTY, two or more** → interactive `inquire::Select`
///   picker; on cancel (Esc) we exit cleanly without connecting.
async fn bare_zuko_menu() -> Result<()> {
    let saved = store::saved_names();
    if saved.is_empty() {
        print_first_run_hint();
        return Ok(());
    }
    if !std::io::stdin().is_terminal() || !std::io::stdout().is_terminal() {
        // Non-interactive (piped/scripted): keep the listing so `zuko` in a
        // script never blocks on a picker. The user picks the next step.
        print_saved_hosts_listing(&saved);
        return Ok(());
    }
    if saved.len() == 1 {
        let name = saved.into_iter().next().expect("len == 1");
        eprintln!("connecting to {name} (the only saved host)");
        return connect_by_name(&name).await;
    }
    // Interactive TTY with 2+ hosts: arrow-key picker with type-to-filter.
    match Select::new("Select a host to connect:", saved).prompt() {
        Ok(name) => connect_by_name(&name).await,
        Err(InquireError::OperationCanceled | InquireError::OperationInterrupted) => {
            eprintln!("cancelled");
            Ok(())
        }
        Err(e) => {
            // Unexpected (IO error, terminal weirdness). Fall back to the
            // listing so the user still has a path forward via `zuko <name>`.
            eprintln!("host picker unavailable: {e:#}");
            print_saved_hosts_listing(&store::saved_names());
            Ok(())
        }
    }
}

/// Bare `zuko` with no saved hosts (genuine first run): lay out the two
/// paths (serve this machine, or pair with a host) so the user sees both.
fn print_first_run_hint() {
    eprintln!("zuko — reach your machines over Iroh.");
    eprintln!();
    eprintln!("  pair with a host:");
    eprintln!("    on the host:    zuko share");
    eprintln!("    then here:      zuko <code>     # e.g. zuko iridescent-hilton");
    eprintln!();
    eprintln!("  serve THIS machine's shell:");
    eprintln!("    zuko install                    # set up the daemon + service");
    eprintln!();
    eprintln!("see also:  zuko ls · zuko rm <name> · zuko --help");
}

/// Bare `zuko` with saved hosts but no TTY (piped/scripted), or as a
/// fallback when the interactive picker can't run. Lists names — tickets are
/// deliberately not echoed (long-lived secret) — and reminds the user how to
/// connect.
fn print_saved_hosts_listing(saved: &[String]) {
    eprintln!("saved hosts:");
    for name in saved {
        eprintln!("  {name}");
    }
    eprintln!();
    eprintln!("connect with:  zuko <name>");
}
