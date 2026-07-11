//! zuko — reach your machines over [Iroh](https://www.iroh.computer/).
//!
//! This crate is both a **library** (the host/client/handoff/protocol modules)
//! and a **binary** (`src/main.rs`, the `zuko` CLI). The binary is a thin
//! dispatcher over the library; see
//! [`main.rs`](../src/main.rs) for the command surface.

pub mod code;

#[cfg(target_os = "linux")]
pub mod app;
pub mod client;
pub mod handoff;
pub mod host;
pub mod secret;
pub mod service;
pub mod store;
pub mod ticket_file;
pub mod tunnel;
pub mod wire;

use std::path::PathBuf;

/// The zuko config dir: `$XDG_CONFIG_HOME` if set, else `$HOME/.config`.
/// All persistent state lives here: the host's secret `key` and the client's
/// saved `hosts`.
pub fn config_dir() -> PathBuf {
    if let Some(xdg) = std::env::var_os("XDG_CONFIG_HOME") {
        return PathBuf::from(xdg);
    }
    let mut h = std::env::var_os("HOME").map_or_else(|| PathBuf::from("."), PathBuf::from);
    h.push(".config");
    h
}

/// `zuko share` configuration. Lives in the library (not just the CLI) because
/// [`handoff::share`] consumes it directly — the binary passes clap-parsed
/// args straight through.
#[derive(clap::Args, Clone)]
pub struct ShareArgs {
    /// Use this ticket instead of reading `~/.config/zuko/current_ticket`
    /// (which `zuko host` maintains). Advanced escape hatch: command-line
    /// arguments may be visible in process listings and shell history.
    #[arg(long)]
    pub ticket: Option<String>,

    /// Label shown to the claimer and used as the default save name. Defaults
    /// to the system hostname.
    #[arg(long)]
    pub label: Option<String>,

    /// Number of claims to serve before exiting (default 1).
    #[arg(long, default_value_t = 1)]
    pub count: usize,

    /// Overall timeout in seconds. 0 = no timeout (default 300).
    #[arg(long, default_value_t = 300)]
    pub timeout: u64,
}

/// `zuko host` configuration. Lives in the library because [`host::run`]
/// consumes it directly.
#[derive(clap::Args, Clone)]
pub struct HostArgs {
    /// Path to the persistent secret key file. A stable key keeps the node id
    /// stable across restarts so saved connections keep working.
    #[arg(long)]
    pub key: Option<PathBuf>,

    /// Shell to launch for new connections. Defaults to `$SHELL`.
    #[arg(long, default_value = "$SHELL")]
    pub shell: String,

    /// Extra args passed to the shell.
    #[arg(long, num_args = 0.., default_values_t = Vec::<String>::new())]
    pub shell_args: Vec<String>,

    /// Directory to start the shell in.
    #[arg(long)]
    pub cwd: Option<PathBuf>,
}

/// `zuko tunnel` configuration. The command runs inside a hosted shell and
/// forwards a client-loopback TCP port to the selected host-loopback port.
#[derive(clap::Args, Clone, Debug)]
pub struct TunnelArgs {
    /// TCP port listening on 127.0.0.1 on the host.
    #[arg(value_parser = clap::value_parser!(u16).range(1..))]
    pub port: u16,
}

/// `zuko app` configuration: run one Wayland GUI app inside a terminal by
/// spawning cage (headless, software-rendered) and streaming its output as
/// Kitty graphics. Linux-only — cage + wlr-screencopy are Linux/Wayland.
#[cfg(target_os = "linux")]
#[derive(clap::Args, Clone, Debug)]
pub struct AppArgs {
    /// List discoverable desktop/Flatpak app aliases and exit.
    #[arg(long)]
    pub list: bool,

    /// Print the resolved launch command/env and exit without starting the
    /// compositor. Useful when a Flatpak shows a blank screen.
    #[arg(long)]
    pub dry_run: bool,

    /// Draw a generated Kitty graphics test pattern and exit. This does not
    /// start cage/Wayland or the child app; use it first to prove terminal
    /// graphics survive the local terminal / zuko PTY path.
    #[arg(long)]
    pub test_pattern: bool,

    /// Check zuko app runtime capabilities (cage, Wayland protocols, terminal
    /// geometry) and exit without entering TUI mode.
    #[arg(long)]
    pub doctor: bool,

    /// Let the child app write stdout/stderr to this terminal. Normal mode
    /// suppresses child logs so they do not corrupt the Kitty graphics stream.
    #[arg(long)]
    pub debug_child: bool,

    /// Disable common browser subprocess sandboxes. Useful on hosts/containers
    /// where Firefox logs `CanCreateUserNamespace() clone() failure: EPERM`.
    #[arg(long)]
    pub no_sandbox: bool,

    /// Hide the pointer crosshair overlay. By default `zuko app` draws a small
    /// inverted crosshair at the pointer position (the captured frames have no
    /// compositor cursor of their own), so touch/imprecise clicks can be aimed.
    #[arg(long)]
    pub no_cursor: bool,

    /// Maximum terminal frame ship rate. zuko adapts down when frames are
    /// unchanged or encode/output is slower than this cap.
    #[arg(long, default_value_t = 30)]
    pub fps: u16,

    /// Approximate max Kitty graphics bandwidth in Mbit/s. zuko adapts FPS down
    /// when full-motion frames exceed this budget. 0 disables the bandwidth cap.
    #[arg(long, default_value_t = 80.0)]
    pub max_mbps: f64,

    /// Kitty graphics payload codec. `auto` uses PNG for UI/static frames and
    /// raw RGB for high-entropy video-like frames to avoid PNG CPU cost.
    #[arg(long, value_enum, default_value_t = KittyGraphicsCodec::Auto)]
    pub graphics_codec: KittyGraphicsCodec,

    /// Scale multiplier for the hosted app output relative to terminal pixels.
    /// Default 1.0 makes cage match the terminal pixel size.
    #[arg(long, default_value_t = 1.0)]
    pub scale: f32,

    /// Force software rendering inside the child app (e.g. `MOZ_WEBRENDER=software`,
    /// `LIBGL_ALWAYS_SOFTWARE=1`). Cage already renders headless with pixman; this
    /// coaxes the child onto a software path too.
    #[arg(long)]
    pub software: bool,

    /// Child command and arguments. Put zuko app flags before the command; use
    /// `--` before child flags, e.g. `zuko app --fps 5 -- firefox --new-window`.
    #[arg(
        required_unless_present_any = ["list", "test_pattern", "doctor"],
        trailing_var_arg = true,
        allow_hyphen_values = true,
        value_name = "COMMAND"
    )]
    pub command: Vec<String>,
}

#[cfg(target_os = "linux")]
#[derive(clap::ValueEnum, Clone, Copy, Debug, Default, Eq, PartialEq)]
pub enum KittyGraphicsCodec {
    #[default]
    Auto,
    Png,
    Rgb,
}
