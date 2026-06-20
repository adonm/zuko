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

#[cfg(not(target_os = "ios"))]
pub mod client;
#[cfg(not(target_os = "ios"))]
pub mod control;
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
    let mut h = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
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
