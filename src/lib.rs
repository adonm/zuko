//! zuko — reach your machines over [Iroh](https://www.iroh.computer/).
//!
//! This crate is both a **library** (the host/client/handoff/protocol modules,
//! plus an FFI surface for mobile clients) and a **binary** (`src/main.rs`,
//! the `zuko` CLI). The binary is a thin dispatcher over the library; see
//! [`main.rs`](../src/main.rs) for the command surface.
//!
//! # The FFI surface
//!
//! The crate also builds as a `staticlib` with [uniffi] bindings that mobile
//! clients (the iOS app, future Android) consume via an XCFramework. This lets
//! the mobile app reuse the **exact same** key-derivation code
//! (`code::derive_key`) as the CLI — no second Argon2id implementation to
//! drift. Built with the same `uniffi` version (0.31) as `iroh-ffi`, so both
//! XCFrameworks can link into the same app without runtime symbol conflicts.
//!
//! [uniffi]: https://mozilla.github.io/uniffi.rs/

// uniffi scaffolding MUST live at the crate root — `#[uniffi::export]` in
// submodules looks for `crate::UniFfiTag` which the macro generates here.
uniffi::setup_scaffolding!();

// `code` and `ffi` are the only modules the iOS FFI build needs. Everything
// else (host/client/handoff/service/store) pulls in desktop-only deps
// (portable-pty, crossterm, clap, inquire, etc.) that either don't compile
// for iOS or are pointless there. Target-cfg'ing them keeps the CLI build
// unchanged while letting `cargo build --lib --target *-apple-ios*` succeed
// with just the key-derivation surface.
pub mod code;
pub mod ffi;

#[cfg(all(target_os = "linux", feature = "gui-app"))]
pub mod app;
#[cfg(not(target_os = "ios"))]
pub mod client;
#[cfg(not(target_os = "ios"))]
pub mod handoff;
#[cfg(not(target_os = "ios"))]
pub mod host;
#[cfg(not(target_os = "ios"))]
pub mod secret;
#[cfg(not(target_os = "ios"))]
pub mod service;
#[cfg(not(target_os = "ios"))]
pub mod store;
#[cfg(not(target_os = "ios"))]
pub mod ticket_file;
#[cfg(not(target_os = "ios"))]
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
/// args straight through. Desktop-only (clap is target-cfg'd out of iOS).
#[cfg(not(target_os = "ios"))]
#[derive(clap::Args, Clone)]
pub struct ShareArgs {
    /// Use this ticket instead of reading `~/.config/zuko/current_ticket`
    /// (which `zuko host` maintains). Handy for handing off a ticket captured
    /// elsewhere without the daemon running.
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
/// consumes it directly. Desktop-only (same target-cfg reason as `ShareArgs`).
#[cfg(not(target_os = "ios"))]
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

    /// Maximum terminal frame ship rate. Rendering/damage can run faster; this
    /// caps the expensive readback + Kitty output path.
    #[arg(long, default_value_t = 16)]
    pub fps: u16,

    /// Scale the hosted app's logical output before rendering to the terminal.
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
        required_unless_present_any = ["list", "test_pattern"],
        trailing_var_arg = true,
        allow_hyphen_values = true,
        value_name = "COMMAND"
    )]
    pub command: Vec<String>,
}
