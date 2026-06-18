//! zuko — reach your machines over [Iroh](https://www.iroh.computer/).
//!
//! One binary, a few jobs:
//! - `zuko host`     serve this machine's shell over Iroh (what the iOS app and
//!   `zuko connect` dial into).
//! - `zuko connect`  attach a local terminal to a remote `zuko host`.
//! - `zuko share`    hand the host's ticket to a new device via a short,
//!   memorable code (croc-style). The other device runs `zuko claim <code>`.
//!
//! Saved hosts (`zuko add`/`zuko ls`/`zuko rm`) live at `~/.config/zuko/hosts`,
//! mirroring the iOS app's connection list.
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
//! See [`wire`], [`host`], and [`client`] for the implementations.

mod client;
mod host;
mod share;
mod store;
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
    /// Shortcut for `zuko connect <target>`: a saved host name or a raw ticket.
    target: Option<String>,

    #[command(subcommand)]
    command: Option<Command>,
}

#[derive(Subcommand)]
enum Command {
    /// Serve this machine's shell over Iroh. Prints a ticket clients use to dial in.
    Host(HostArgs),

    /// Connect to a zuko host by saved name or raw ticket.
    Connect { target: String },

    /// Save a host ticket under a name: `zuko add <name> <ticket>`.
    Add { name: String, ticket: String },

    /// List saved hosts.
    Ls,

    /// Remove a saved host by name.
    Rm { name: String },

    /// Hand this host's ticket to a new device via a short, memorable code.
    /// The other device runs `zuko claim <code>` to fetch and save it.
    Share(ShareArgs),

    /// Claim a ticket from a `zuko share` code: fetch it, save it, and by
    /// default connect immediately.
    Claim {
        /// The code printed by `zuko share`. Dashes, spaces, or bare letters
        /// all work; case is ignored.
        code: String,

        /// Save the claimed host under this name (default: the host's label).
        #[arg(long, value_name = "NAME")]
        r#as: Option<String>,

        /// Don't connect after claiming — just fetch (and save, unless
        /// `--no-save`).
        #[arg(long)]
        no_connect: bool,

        /// Don't save — print the fetched ticket to stdout instead.
        #[arg(long)]
        no_save: bool,

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

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Some(Command::Host(args)) => host::run(args).await,
        Some(Command::Connect { target }) => {
            let ticket = store::resolve_ticket(Some(target))?;
            client::connect(&ticket).await
        }
        Some(Command::Add { name, ticket }) => {
            store::add(&name, &ticket)?;
            println!("saved {name}");
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
        Some(Command::Share(args)) => share::share(&args).await,
        Some(Command::Claim {
            code,
            r#as,
            no_connect,
            no_save,
            timeout,
        }) => share::claim(&code, r#as, no_connect, no_save, timeout).await,
        None => {
            // Bare `zuko` (no subcommand): treat any positional target as a
            // connect shortcut, or read the ticket from stdin if piped.
            let ticket = store::resolve_ticket(cli.target)?;
            client::connect(&ticket).await
        }
    }
}

/// The zuko config dir: `$XDG_CONFIG_HOME` if set, else `$HOME/.config`.
/// All persistent state lives here: the host's secret `key` and the client's
/// saved `hosts`.
fn config_dir() -> std::path::PathBuf {
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        return std::path::PathBuf::from(xdg);
    }
    let mut h = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    h.push(".config");
    h
}
