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
//! ## Wire protocol (single bidirectional Iroh stream, ALPN `zuko/1`)
//!
//! Every message is length-prefixed so resize and data stay ordered and nothing
//! leaks into the terminal as in-band escape sequences:
//!
//! ```text
//! [type: u8][len: u16 big-endian][payload: `len` bytes]
//!   0x00 DATA   payload = raw terminal bytes (keystrokes up, PTY output down)
//!   0x01 RESIZE payload = [cols: u16 BE][rows: u16 BE]   (client -> host)
//! ```
//!
//! See [`wire`], [`host`], [`client`], and [`handoff`] for the implementations.

mod client;
mod code;
mod handoff;
mod host;
mod secret;
mod service;
mod store;
mod ticket_file;
mod wire;

use anyhow::Result;
use clap::{Args, Parser, Subcommand};

#[derive(Parser)]
#[command(
    name = "zuko",
    version,
    about = "Reach your machines over Iroh — serve a shell or connect to one"
)]
struct Cli {
    /// Shortcut: a saved host name to connect to, or a `zuko share` pairing
    /// code (4 short words) to claim. zuko tells them apart by shape.
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

#[derive(Args, Clone)]
struct ShareArgs {
    /// Use this ticket instead of reading `~/.config/zuko/current_ticket`
    /// (which `zuko host` maintains). Handy for handing off a ticket captured
    /// elsewhere without the daemon running.
    #[arg(long)]
    ticket: Option<String>,

    /// Label shown to the claimer and used as the default save name. Defaults
    /// to the system hostname.
    #[arg(long)]
    label: Option<String>,

    /// Number of claims to serve before exiting (default 1).
    #[arg(long, default_value_t = 1)]
    count: usize,

    /// Overall timeout in seconds. 0 = no timeout (default 300).
    #[arg(long, default_value_t = 300)]
    timeout: u64,
}

#[derive(Args, Clone)]
struct HostArgs {
    /// Path to the persistent secret key file. A stable key keeps the node id
    /// stable across restarts so saved connections keep working.
    #[arg(long)]
    key: Option<std::path::PathBuf>,

    /// Shell to launch for new connections. Defaults to `$SHELL`.
    #[arg(long, default_value = "$SHELL")]
    shell: String,

    /// Extra args passed to the shell.
    #[arg(long, num_args = 0.., default_values_t = Vec::<String>::new())]
    shell_args: Vec<String>,

    /// Directory to start the shell in.
    #[arg(long)]
    cwd: Option<std::path::PathBuf>,
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
        Some(Command::Connect { name }) => {
            let ticket = store::lookup_ticket_or_bail(&name)?;
            client::connect(&ticket).await
        }
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
            // names never look like a 4×CVCV code, so the disambiguation is
            // unambiguous. See [`code::looks_like_code`] for the rule.
            Some(input) => match store::lookup(input.trim()) {
                Some(ticket) => client::connect(&ticket).await,
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
            None => {
                print_bare_zuko_hint();
                Ok(())
            }
        },
    }
}

/// Bare `zuko` (no subcommand): an actionable menu. The function name is
/// neutral because the behavior branches on saved-hosts state — it lists
/// saved hosts by name when any exist (the common case after the first claim),
/// or prints the first-run pairing/serve menu when there are none.
fn print_bare_zuko_hint() {
    let saved = store::saved_names();
    if !saved.is_empty() {
        // Most-common case after the first claim: list names and let the user
        // pick one. Tickets are deliberately not echoed (long-lived secret).
        eprintln!("saved hosts:");
        for name in saved {
            eprintln!("  {name}");
        }
        eprintln!();
        eprintln!("connect with:  zuko <name>");
        return;
    }
    // Genuine first run: no saved hosts. Lay out the two paths (serve this
    // machine, or pair with a host) so the user sees both at once.
    eprintln!("zuko — reach your machines over Iroh.");
    eprintln!();
    eprintln!("  pair with a host:");
    eprintln!("    on the host:    zuko share");
    eprintln!("    then here:      zuko <code>     # e.g. zuko wowu-hiva-fiki-rufu");
    eprintln!();
    eprintln!("  serve THIS machine's shell:");
    eprintln!("    zuko install                    # set up the daemon + service");
    eprintln!();
    eprintln!("see also:  zuko ls · zuko rm <name> · zuko --help");
}

/// The zuko config dir: `$XDG_CONFIG_HOME` if set, else `$HOME/.config`.
/// All persistent state lives here: the host's secret `key` and the client's
/// saved `hosts`.
pub(crate) fn config_dir() -> std::path::PathBuf {
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        return std::path::PathBuf::from(xdg);
    }
    let mut h = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    h.push(".config");
    h
}
