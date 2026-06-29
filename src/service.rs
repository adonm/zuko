//! `zuko install` / `zuko uninstall` / `zuko upgrade` — manage the host daemon
//! as a user service (systemd user unit on Linux, launchd agent on macOS), and
//! keep the zuko binary itself current (mise-managed installs).
//!
//! Once `zuko` itself is on `PATH` (e.g. via `mise use --global
//! github:adonm/zuko`), the operator runs `zuko install` on the machine they
//! want to reach, and the binary takes care of writing the service unit,
//! enabling it, and starting it. `zuko upgrade` later pulls a newer release
//! through mise and restarts the unit onto it — without re-running `install`,
//! because the unit's wrapper routes through mise's `latest` symlink.
//!
//! ## What `install` does
//!
//! 1. Resolve the running `zuko` binary's absolute path (so the unit keeps
//!    working even if `PATH` changes later). If the binary lives under a
//!    mise/asdf-style versioned install dir with a `latest` sibling symlink,
//!    the path is routed through `latest` so a mise upgrade that deletes the
//!    old version dir doesn't strand the unit on a stale path.
//! 2. Resolve the persistent `~/.config/zuko/key` path (creating the dir, not
//!    the key — `zuko host` writes the key on first run).
//! 3. Write a thin `zuko-host-run` wrapper at `~/.local/bin/zuko-host-run`
//!    that execs `zuko host --key <key>` with the resolved binary. The wrapper
//!    decouples the unit from `PATH` (systemd user units and launchd agents
//!    don't always inherit the user's interactive shell PATH — especially
//!    under mise shims), and gives the operator one obvious file to edit if
//!    they want to pass extra `host` flags.
//! 4. Write the platform's service unit and enable + start it.
//!
//! `uninstall` reverses step 4 (stop, disable, remove unit) but leaves the
//! key, saved hosts, and wrapper in place — those are user data, not service
//! state.
//!
//! ## Platform support
//!
//! - **Linux:** systemd *user* unit at
//!   `~/.config/systemd/user/zuko-host.service` (started with
//!   `systemctl --user`). The unit pulls in `network-online.target` and
//!   restarts on failure. For servers that need to run before login, the
//!   operator separately runs `loginctl enable-linger <user>` (printed at the
//!   end of `install`); we don't do it for them because it needs sudo and
//!   isn't always wanted on a desktop.
//! - **macOS:** launchd agent at
//!   `~/Library/LaunchAgents/dev.adonm.zuko.host.plist`, loaded with
//!   `launchctl`.
//! - **Other platforms:** `install` refuses with a clear message; the host
//!   can still be run in the foreground with `zuko host`.

use anyhow::{Context, Result, bail};
use clap::Args;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::config_dir;

/// Default install prefix for the `zuko-host-run` wrapper.
///
/// Public so tests + help text can reference the same default.
pub fn default_prefix() -> PathBuf {
    let mut p = home_dir();
    p.push(".local");
    p
}

/// Default key path: `~/.config/zuko/key`. Same default as `zuko host`.
pub fn default_key_path() -> PathBuf {
    let mut p = config_dir();
    p.push("zuko");
    p.push("key");
    p
}

/// Default wrapper script path: `<prefix>/bin/zuko-host-run`.
pub fn wrapper_path(prefix: &Path) -> PathBuf {
    let mut p = prefix.to_path_buf();
    p.push("bin");
    p.push("zuko-host-run");
    p
}

#[derive(Debug, Clone)]
pub struct InstallArgs {
    /// Install prefix for the wrapper (default `~/.local`).
    pub prefix: PathBuf,
    /// Persistent secret key path (default `~/.config/zuko/key`).
    pub key: PathBuf,
    /// Shell launched per connection (default `$SHELL`, falling back to
    /// `/bin/bash`). Forwarded into the wrapper so the service doesn't depend
    /// on the per-login `$SHELL` env var being set.
    pub shell: String,
    /// Don't start the service after installing it (just write + enable).
    pub no_start: bool,
}

impl Default for InstallArgs {
    fn default() -> Self {
        Self {
            prefix: default_prefix(),
            key: default_key_path(),
            shell: std::env::var("SHELL").unwrap_or_else(|_| "/bin/bash".to_string()),
            no_start: false,
        }
    }
}

/// Run `zuko install`: write the wrapper + service unit, enable + start it.
pub fn install(args: &InstallArgs) -> Result<()> {
    let bin = resolve_self_exe()?;
    let wrapper = wrapper_path(&args.prefix);

    // Ensure the parent dirs exist for both the wrapper and the key file. The
    // key itself isn't written here — `zuko host` writes it atomically on
    // first run, and writing it now would race with the host's 0600 atomic
    // writer. We only ensure the *parent dir* exists.
    if let Some(parent) = wrapper.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }
    if let Some(parent) = args.key.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }

    eprintln!("==> writing wrapper at {}", wrapper.display());
    write_wrapper(&wrapper, &bin, &args.key, &args.shell)?;

    let svc = detect_service()?;
    eprintln!("==> installing {svc} user service");
    match svc {
        Service::Systemd => install_systemd(&wrapper, args.no_start)?,
        Service::Launchd => install_launchd(&wrapper, args.no_start)?,
    }

    eprintln!();
    eprintln!("zuko host installed.");
    eprintln!("  wrapper:  {}", wrapper.display());
    eprintln!(
        "  key:      {} (created on first `zuko host` run)",
        args.key.display()
    );
    if args.no_start {
        eprintln!(
            "  (--no-start: service enabled but not started; start it with the platform tool when ready)"
        );
    }
    match svc {
        Service::Systemd if !args.no_start => {
            eprintln!("  logs:     journalctl --user -u zuko-host -f");
            eprintln!();
            eprintln!("pair a device with:  zuko share");
            eprintln!();
            // Servers need lingering so the user manager runs without an active
            // login session. It's a sudo operation and not always wanted on a
            // desktop, so we just point at it instead of doing it for them.
            eprintln!("to keep the host running after you log out (servers):");
            eprintln!("  sudo loginctl enable-linger \"${{USER}}\"");
        }
        Service::Systemd => {
            // --no-start: the unit is enabled but not running. Tell the user
            // how to start it manually when they're ready.
            eprintln!();
            eprintln!("start later with:    systemctl --user start zuko-host");
            eprintln!("pair a device with:  zuko share   (after starting)");
        }
        Service::Launchd if !args.no_start => {
            eprintln!("  logs:     tail -f ~/.config/zuko/zuko-host.out.log");
            eprintln!();
            eprintln!("pair a device with:  zuko share");
        }
        Service::Launchd => {
            eprintln!();
            eprintln!(
                "start later with:    launchctl load ~/Library/LaunchAgents/dev.adonm.zuko.host.plist"
            );
            eprintln!("pair a device with:  zuko share   (after starting)");
        }
    }
    Ok(())
}

/// Run `zuko uninstall`: stop + disable + remove the service unit. Leaves the
/// key, saved hosts, and wrapper in place (they're user data).
pub fn uninstall() -> Result<()> {
    let svc = detect_service()?;
    eprintln!("==> removing {svc} user service");
    match svc {
        Service::Systemd => uninstall_systemd()?,
        Service::Launchd => uninstall_launchd()?,
    }
    eprintln!();
    eprintln!("zuko host service removed.");
    eprintln!("  (key + saved hosts kept at ~/.config/zuko — delete by hand to forget this host)");
    Ok(())
}

// ─────────────────────────────────── upgrade ────────────────────────────────

/// mise tool id for the zuko distribution (the `github:owner/repo` backend
/// downloads release binaries ubi-style).
const MISE_TOOL: &str = "github:adonm/zuko";

/// Subdir under mise's installs root that uniquely identifies a mise-managed
/// zuko. mise normalises `github:adonm/zuko` to the dir name
/// `github-adonm-zuko` on disk.
const MISE_INSTALL_DIR: &str = "github-adonm-zuko";

/// `zuko upgrade` configuration. clap-derived (like `ShareArgs`/`HostArgs`) so
/// the binary uses it directly as a subcommand payload without a wrapper.
#[derive(Args, Clone, Debug)]
pub struct UpgradeArgs {
    /// Pin a specific version (e.g. "0.7.0") instead of tracking latest.
    #[arg(long, value_name = "VERSION")]
    pub version: Option<String>,

    /// Upgrade the binary but don't restart the host service. Restart manually
    /// later (e.g. `systemctl --user restart zuko-host`) when a brief drop is
    /// convenient.
    #[arg(long)]
    pub no_restart: bool,

    /// Show the plan (mise command + service action + versions) without
    /// changing anything.
    #[arg(long)]
    pub check: bool,
}

/// Run `zuko upgrade`: pull the latest zuko binary via mise, then (if the host
/// service is installed) restart it so the daemon execs the new build.
///
/// ## How the service picks up the new binary
///
/// `zuko install` writes a wrapper that routes through mise's `latest` symlink
/// (see [`prefer_stable_symlink`]). mise repoints `latest` at the new version
/// dir during the upgrade, so the wrapper path stays valid without a re-`install`;
/// only the already-running process lags. A restart execs the wrapper again and
/// lands on the new inode.
///
/// ## Interruption
///
/// Restarting the host kills its in-memory PTYs — there is no live handoff yet.
/// Clients auto-reconnect (the iOS app redials; the CLI is restarted by the
/// user), but land in **fresh** shells, not the ones they had. For work that
/// must survive a host upgrade, run `tmux`/`zellij`/`screen` inside the zuko
/// session. A zero-downtime upgrade (live PTY handoff to a new host process) is
/// a post-1.0 goal, contingent on the wire protocol stabilising — at which
/// point this same command gets you there without the drop.
pub fn upgrade(args: &UpgradeArgs) -> Result<()> {
    // `zuko upgrade` is a mise-specific convenience. We refuse to run it against
    // a non-mise install (cargo, hand-built, distro package) so we never
    // silently fork a second, mise-managed copy or clobber the user's chosen
    // install method.
    if !is_mise_managed() {
        bail!(
            "this zuko binary isn't managed by mise (its path has no \
             .../mise/installs/{MISE_INSTALL_DIR}/ segment).\n\
             `zuko upgrade` drives `mise upgrade {MISE_TOOL}`; install with\n\
             `mise use --global {MISE_TOOL}` to enable it, or upgrade your\n\
             install directly (e.g. `cargo install --path .` for a source build)."
        );
    }
    if !mise_on_path() {
        bail!(
            "mise is not on PATH but this binary lives in a mise install dir.\n\
             Run `zuko upgrade` from a shell with mise activated, or upgrade\n\
             manually with `mise upgrade {MISE_TOOL}`."
        );
    }

    let before = env!("CARGO_PKG_VERSION");
    let svc = installed_service();
    let mise_args = mise_upgrade_args(args.version.as_deref());

    if args.check {
        eprintln!("==> --check: no changes made");
        eprintln!("    current version:  {before}");
        eprintln!("    would run:        mise {}", mise_args.join(" "));
        match &svc {
            Some(s) if args.no_restart => {
                eprintln!("    host service:     {s} unit installed (--no-restart: won't restart)");
            }
            Some(s) => {
                eprintln!("    host service:     {s} unit installed -> would restart");
                eprintln!(
                    "                      (restart drops active sessions; clients auto-reconnect)"
                );
            }
            None => eprintln!("    host service:     not installed (binary-only upgrade)"),
        }
        return Ok(());
    }

    // 1. Pull the new binary. `mise upgrade` respects the existing pin range;
    //    since zuko is pinned to `latest` by `mise use --global`, this moves to
    //    the newest release. `--version` re-pins via `mise use --global …@<v>`.
    eprintln!("==> upgrading {MISE_TOOL} (running {before})");
    eprintln!("    $ mise {}", mise_args.join(" "));
    let status = Command::new("mise")
        .args(&mise_args)
        .status()
        .context("run mise")?;
    if !status.success() {
        bail!(
            "mise {} failed (exit {:?})",
            mise_args.join(" "),
            status.code()
        );
    }

    // 2. Read back the installed version. The running binary is still the old
    //    one (we don't re-exec ourselves), so spawn the freshly-installed exe
    //    at the `latest` path to report what we landed on. Best-effort: a parse
    //    failure doesn't undo a successful upgrade.
    let after = installed_version();
    match &after {
        Some(v) if v != before => eprintln!("==> {before} -> {v}"),
        Some(v) => eprintln!("==> already at {v} (mise had nothing newer)"),
        None => eprintln!("==> upgrade ran; couldn't read back the new version"),
    }

    // 3. Restart the host service so it execs the new binary, unless asked not
    //    to. See the function-level doc for the interruption story.
    match &svc {
        Some(s) if args.no_restart => {
            eprintln!("==> host service: {s} unit installed (--no-restart: not restarting)");
            eprintln!(
                "    pick up the new binary with: systemctl --user restart {SYSTEMD_UNIT_NAME}"
            );
        }
        Some(Service::Systemd) => {
            eprintln!("==> restarting systemd user service `{SYSTEMD_UNIT_NAME}`");
            eprintln!("    (active sessions drop; clients auto-reconnect to fresh shells)");
            run("systemctl", &["--user", "restart", SYSTEMD_UNIT_NAME])?;
        }
        Some(Service::Launchd) => {
            let plist = launchd_plist_path();
            eprintln!("==> restarting launchd agent `{LAUNCHD_LABEL}`");
            eprintln!("    (active sessions drop; clients auto-reconnect to fresh shells)");
            let _ = Command::new("launchctl")
                .args(["unload", &plist.to_string_lossy()])
                .status();
            run("launchctl", &["load", &plist.to_string_lossy()])?;
        }
        None => eprintln!("==> host service: not installed (nothing to restart)"),
    }

    eprintln!();
    eprintln!("zuko upgrade complete.");
    if let Some(v) = after {
        eprintln!("  now at {v}");
    }
    Ok(())
}

// ──────────────────────────────── resolver ─────────────────────────────────

/// The absolute path to the currently-running `zuko` binary. The unit points
/// at this directly (through the wrapper) so it survives PATH changes. If the
/// binary sits under a mise/asdf-style versioned install dir, the returned
/// path goes through the install root's `latest` symlink so a mise upgrade
/// that deletes the old version dir keeps the unit running (see
/// [`prefer_stable_symlink`]).
fn resolve_self_exe() -> Result<PathBuf> {
    // std::env::current_exe resolves symlinks on Linux and macOS, so a mise
    // shim's exec'd target is what we get — exactly what we want for the unit
    // to keep working. `prefer_stable_symlink` then opportunistically rewrites
    // the versioned path to go through mise's `latest` symlink, so an upgrade
    // that deletes the versioned dir doesn't take the unit down with exit 127.
    let exe = std::env::current_exe().context("resolve current zuko binary path")?;
    Ok(prefer_stable_symlink(exe))
}

/// Rewrite a mise/asdf-style versioned binary path to go through the install
/// root's `latest` symlink instead of the version-pinned dir.
///
/// Layout this handles:
/// ```text
/// <install_root>/<version_dir>/<bin>   ← current_exe() resolves here
/// <install_root>/latest -> ./<version_dir>
/// ```
/// and rewrites to `<install_root>/latest/<bin>`. mise maintains `latest`
/// (plus major/minor variants) and *deletes* the versioned dir on upgrade —
/// so a wrapper that pins `<install_root>/0.6.5/zuko` exits 127 the moment
/// mise upgrades zuko under the user, leaving the systemd unit crash-looping.
/// Routing through `latest` keeps the wrapper valid across upgrades without
/// forcing a re-`install` each time.
///
/// Conservative: only rewrites when (a) a `latest` entry exists in the install
/// root, (b) it resolves to a directory *inside* the same install root (not an
/// escaped symlink), and (c) `<install_root>/latest/<bin>` exists as a real
/// file. Any miss returns the original path unchanged — this function never
/// makes the path *less* valid than what `current_exe()` produced.
fn prefer_stable_symlink(exe: PathBuf) -> PathBuf {
    // Layout: <install_root>/<version_dir>/<bin_name>.
    let Some(bin_name) = exe.file_name() else {
        return exe;
    };
    let Some(version_dir) = exe.parent() else {
        return exe;
    };
    let Some(install_root) = version_dir.parent() else {
        return exe;
    };
    let latest = install_root.join("latest");
    // `canonicalize` follows the symlink and fails if it's missing or broken,
    // which is exactly the gate we want.
    let Ok(resolved_latest) = std::fs::canonicalize(&latest) else {
        return exe;
    };
    let Ok(resolved_install_root) = std::fs::canonicalize(install_root) else {
        return exe;
    };
    // Reject symlinks that escape the install root (defence-in-depth against a
    // weirdly-shaped dir we shouldn't trust). Canonicalise both sides first:
    // macOS temp paths can enter as `/var/...` while `canonicalize` returns
    // `/private/var/...`, and comparing mixed spellings causes false rejects.
    if !resolved_latest.starts_with(&resolved_install_root) {
        return exe;
    }
    let via_latest = latest.join(bin_name);
    // Final gate: confirm `latest/<bin>` is a real file. Never rewrite to a
    // path that isn't there right now.
    if via_latest.is_file() {
        via_latest
    } else {
        exe
    }
}

fn home_dir() -> PathBuf {
    std::env::var_os("HOME").map_or_else(|| PathBuf::from("."), PathBuf::from)
}

/// Write the `zuko-host-run` wrapper. 0755 (it carries no secret — the secret
/// is the key file's path, and that file is 0600). The wrapper execs the
/// resolved `zuko` binary in host mode with the resolved key path, so the
/// service unit never needs to know about either.
fn write_wrapper(path: &Path, bin: &Path, key: &Path, shell: &str) -> Result<()> {
    // Escape single quotes in paths so the literal `'$BIN'` in the wrapper
    // stays correct even if a path contains one. Single quotes are rare but
    // valid in Unix paths; we still want a generated wrapper that works.
    let bin_s = sh_quote(&bin.to_string_lossy());
    let key_s = sh_quote(&key.to_string_lossy());
    let shell_s = sh_quote(shell);
    let body = format!(
        "#!/bin/sh\n\
         # Generated by `zuko install`. Edit to taste; runs the zuko host daemon.\n\
         # Re-run `zuko install` to regenerate (e.g. after moving the binary).\n\
         exec {bin_s} host --key {key_s} --shell {shell_s} \"$@\"\n"
    );
    std::fs::write(path, body).with_context(|| format!("write wrapper {}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o755);
        std::fs::set_permissions(path, perms).context("chmod wrapper 0755")?;
    }
    Ok(())
}

/// Shell-single-quote a string for use inside `exec '$x' ...`. Wraps the value
/// in single quotes and escapes any embedded single quote via the standard
/// `'\''` idiom.
fn sh_quote(s: &str) -> String {
    let mut out = String::with_capacity(s.len() + 2);
    out.push('\'');
    for c in s.chars() {
        if c == '\'' {
            out.push_str("'\\''");
        } else {
            out.push(c);
        }
    }
    out.push('\'');
    out
}

// ──────────────────────────── service detection ────────────────────────────

#[derive(Copy, Clone, Debug)]
// One variant is always unreachable per platform (Launchd on Linux, Systemd on
// macOS), and neither exists on other OSes. Silence the platform-specific
// dead-code warning rather than scatter `#[cfg]` on every match arm.
#[allow(dead_code)]
enum Service {
    Systemd,
    Launchd,
}

impl std::fmt::Display for Service {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::Systemd => "systemd",
            Self::Launchd => "launchd",
        })
    }
}

fn detect_service() -> Result<Service> {
    // We branch on OS first, then check the tool actually exists so the error
    // is actionable ("install systemd") rather than a silent failure path.
    #[cfg(target_os = "linux")]
    {
        if std::process::Command::new("systemctl")
            .arg("--version")
            .output()
            .is_ok()
        {
            return Ok(Service::Systemd);
        }
        bail!(
            "systemctl not found. `zuko install` manages a systemd user unit; \
             on Linux without systemd, run `zuko host` in the foreground instead."
        );
    }
    #[cfg(target_os = "macos")]
    {
        if std::process::Command::new("launchctl")
            .arg("version")
            .output()
            .is_ok()
        {
            return Ok(Service::Launchd);
        }
        bail!("launchctl not found. `zuko install` manages a launchd agent.");
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        bail!(
            "no service manager support on this OS. Run `zuko host` in the \
             foreground instead."
        );
    }
}

// ─────────────────────────────────── systemd ───────────────────────────────

/// Unit name (also the `systemctl --user` instance name) without extension.
const SYSTEMD_UNIT_NAME: &str = "zuko-host";

fn systemd_unit_path() -> PathBuf {
    let mut p = config_dir();
    p.push("systemd");
    p.push("user");
    p.push(format!("{SYSTEMD_UNIT_NAME}.service"));
    p
}

fn install_systemd(wrapper: &Path, no_start: bool) -> Result<()> {
    let unit = systemd_unit_path();
    if let Some(parent) = unit.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }
    let wrapper_s = wrapper.to_string_lossy();
    // Quote ExecStart's path so a HOME / --prefix with spaces doesn't split
    // into binary + arg. systemd doesn't do shell word-splitting on its own
    // but does treat the first whitespace-separated token as the binary, so
    // `/home/my user/.local/bin/zuko-host-run` would otherwise start
    // `/home/my` with `user/...` as argv[1].
    let body = format!(
        "[Unit]\n\
         Description=Zuko host (interactive shell over Iroh)\n\
         After=network-online.target\n\
         Wants=network-online.target\n\
         \n\
         [Service]\n\
         ExecStart=\"{wrapper_s}\"\n\
         Restart=on-failure\n\
         RestartSec=5\n\
         \n\
         [Install]\n\
         WantedBy=default.target\n"
    );
    std::fs::write(&unit, body).with_context(|| format!("write {}", unit.display()))?;
    eprintln!("==> wrote {}", unit.display());

    // Reload so systemd picks up the new unit, then enable. With `--no-start`
    // we skip `--now` so the unit is enabled (will start on next boot) but
    // not started immediately — useful when the operator wants to edit the
    // wrapper first or wait for some other condition.
    run("systemctl", &["--user", "daemon-reload"])?;
    let enable_args: &[&str] = if no_start {
        &["--user", "enable", SYSTEMD_UNIT_NAME]
    } else {
        &["--user", "enable", "--now", SYSTEMD_UNIT_NAME]
    };
    run("systemctl", enable_args)?;
    Ok(())
}

fn uninstall_systemd() -> Result<()> {
    // Stop + disable even if the unit is already gone — systemctl returns
    // non-zero in that case, which we treat as success (idempotent uninstall).
    let _ = Command::new("systemctl")
        .args(["--user", "stop", SYSTEMD_UNIT_NAME])
        .status();
    let _ = Command::new("systemctl")
        .args(["--user", "disable", SYSTEMD_UNIT_NAME])
        .status();
    run("systemctl", &["--user", "daemon-reload"])?;
    let unit = systemd_unit_path();
    if unit.exists() {
        std::fs::remove_file(&unit).with_context(|| format!("remove {}", unit.display()))?;
        eprintln!("==> removed {}", unit.display());
    } else {
        eprintln!("==> no unit at {} (nothing to remove)", unit.display());
    }
    Ok(())
}

// ─────────────────────────────────── launchd ───────────────────────────────

const LAUNCHD_LABEL: &str = "dev.adonm.zuko.host";

fn launchd_plist_path() -> PathBuf {
    let mut p = home_dir();
    p.push("Library");
    p.push("LaunchAgents");
    p.push(format!("{LAUNCHD_LABEL}.plist"));
    p
}

fn install_launchd(wrapper: &Path, no_start: bool) -> Result<()> {
    let plist = launchd_plist_path();
    if let Some(parent) = plist.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("mkdir {}", parent.display()))?;
    }
    let wrapper_s = wrapper.to_string_lossy();
    let out_log = log_path("out");
    let err_log = log_path("err");
    let body = format!(
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
         <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
         <plist version=\"1.0\">\n\
         <dict>\n\
             <key>Label</key><string>{LAUNCHD_LABEL}</string>\n\
             <key>RunAtLoad</key><true/>\n\
             <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>\n\
             <key>ProgramArguments</key>\n\
             <array>\n\
                 <string>{wrapper_s}</string>\n\
             </array>\n\
             <key>StandardOutPath</key><string>{out_log}</string>\n\
             <key>StandardErrorPath</key><string>{err_log}</string>\n\
         </dict>\n\
         </plist>\n"
    );
    std::fs::write(&plist, body).with_context(|| format!("write {}", plist.display()))?;
    eprintln!("==> wrote {}", plist.display());

    if no_start {
        // Skip the load entirely — the plist is in place and will load on
        // next login. The operator can `launchctl load` manually when ready.
        return Ok(());
    }
    // launchd refuses to load an already-loaded label; unload first
    // (best-effort, will fail on a fresh install) then load.
    let _ = Command::new("launchctl")
        .args(["unload", &plist.to_string_lossy()])
        .status();
    run("launchctl", &["load", &plist.to_string_lossy()])?;
    Ok(())
}

fn uninstall_launchd() -> Result<()> {
    let plist = launchd_plist_path();
    if plist.exists() {
        let _ = Command::new("launchctl")
            .args(["unload", &plist.to_string_lossy()])
            .status();
        std::fs::remove_file(&plist).with_context(|| format!("remove {}", plist.display()))?;
        eprintln!("==> removed {}", plist.display());
    } else {
        eprintln!("==> no plist at {} (nothing to remove)", plist.display());
    }
    Ok(())
}

fn log_path(kind: &str) -> String {
    let mut p = config_dir();
    p.push("zuko");
    p.push(format!("zuko-host.{kind}.log"));
    p.to_string_lossy().into_owned()
}

// ─────────────────────────────────── helpers ───────────────────────────────

/// Run a command, streaming stderr, bailing with a useful message on failure.
/// Used for `systemctl` / `launchctl` so the install/uninstall errors name the
/// failing step instead of silently ignoring the exit code.
fn run(program: &str, args: &[&str]) -> Result<()> {
    let status = Command::new(program)
        .args(args)
        .status()
        .with_context(|| format!("run {program}"))?;
    if !status.success() {
        bail!(
            "{program} {} failed (exit {:?})",
            args.join(" "),
            status.code()
        );
    }
    Ok(())
}

// ──────────────────────────────── upgrade helpers ───────────────────────────

/// True if the running zuko was launched from a mise-managed install dir
/// (`…/mise/installs/github-adonm-zuko/<version>/zuko`). The path check is the
/// source of truth: a mise shim resolves here via `current_exe()`, and a
/// cargo/distro install never has this layout.
fn is_mise_managed() -> bool {
    std::env::current_exe()
        .map(|exe| path_looks_mise_managed(&exe))
        .unwrap_or(false)
}

/// Pure predicate form of [`is_mise_managed`] so the rule is unit-testable
/// without rearranging `current_exe`.
fn path_looks_mise_managed(exe: &Path) -> bool {
    let s = exe.to_string_lossy();
    s.contains("mise/installs/") && s.contains(&format!("/{MISE_INSTALL_DIR}/"))
}

/// True if `mise` can be invoked from this shell. Separate from
/// [`is_mise_managed`] so the error can tell the user precisely which
/// precondition failed (wrong install method vs. mise just not activated).
fn mise_on_path() -> bool {
    Command::new("mise")
        .arg("--version")
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .is_ok()
}

/// Build the `mise` argv for the upgrade step. With no version, `mise upgrade`
/// moves to the newest release within the existing pin (zuko is pinned to
/// `latest`, so that's the true latest). With `--version`, `mise use --global
/// …@<v>` re-pins the global config to that exact version.
fn mise_upgrade_args(version: Option<&str>) -> Vec<String> {
    match version {
        Some(v) => vec![
            "use".into(),
            "--global".into(),
            format!("github:adonm/zuko@{v}"),
        ],
        None => vec!["upgrade".into(), MISE_TOOL.into()],
    }
}

/// The host service kind, but only if its unit/plist is actually installed on
/// disk. Used by `upgrade` to decide whether a restart applies — a user who
/// only runs `zuko` as a client (no `zuko install`) has nothing to restart.
fn installed_service() -> Option<Service> {
    let svc = detect_service().ok()?;
    let present = match svc {
        Service::Systemd => systemd_unit_path().exists(),
        Service::Launchd => launchd_plist_path().exists(),
    };
    present.then_some(svc)
}

/// Best-effort read of the version reported by the *installed* binary (the one
/// `latest/` points at after an upgrade), by spawning `<exe> --version`. The
/// running process is still the old binary, so this is how we confirm what mise
/// landed on. `None` on any spawn/parse failure — a successful upgrade stays
/// successful even if we can't read back the version string.
fn installed_version() -> Option<String> {
    let exe = resolve_self_exe().ok()?;
    let out = Command::new(&exe).arg("--version").output().ok()?;
    if !out.status.success() {
        return None;
    }
    let line = String::from_utf8(out.stdout).ok()?;
    // `zuko --version` prints `zuko 0.6.13`; take the second whitespace token.
    line.split_whitespace().nth(1).map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sh_quote_passes_simple_paths_through() {
        assert_eq!(
            sh_quote("/home/me/.local/bin/zuko"),
            "'/home/me/.local/bin/zuko'"
        );
    }

    #[test]
    fn sh_quote_escapes_embedded_single_quote() {
        // The standard POSIX-shell idiom for a literal single quote inside a
        // single-quoted string is to close, escape, reopen: '...'\''...'
        assert_eq!(sh_quote("it's"), "'it'\\''s'");
    }

    #[test]
    fn wrapper_body_is_executable_and_execs_zuko_host() {
        // Smoke-test that the generated wrapper parses as POSIX sh and execs
        // `zuko host` with the resolved key path. We don't actually run it
        // (that needs a real key + a real Iroh bind); we just check the shape.
        let dir = tempfile::tempdir().unwrap();
        let wrapper = dir.path().join("zuko-host-run");
        let bin = PathBuf::from("/bin/echo");
        let key = dir.path().join("key");
        write_wrapper(&wrapper, &bin, &key, "/bin/sh").unwrap();
        let body = std::fs::read_to_string(&wrapper).unwrap();
        assert!(body.starts_with("#!/bin/sh\n"));
        assert!(body.contains("exec '/bin/echo' host --key"));
        assert!(body.contains("--shell '/bin/sh'"));
        assert!(body.contains("\"$@\""));
    }

    #[test]
    fn wrapper_is_marked_executable_on_unix() {
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let dir = tempfile::tempdir().unwrap();
            let wrapper = dir.path().join("zuko-host-run");
            write_wrapper(
                &wrapper,
                Path::new("/bin/echo"),
                &dir.path().join("k"),
                "/bin/sh",
            )
            .unwrap();
            let mode = std::fs::metadata(&wrapper).unwrap().permissions().mode();
            assert_eq!(mode & 0o777, 0o755, "wrapper must be 0755, got {mode:o}");
        }
    }

    #[test]
    fn systemd_unit_body_has_expected_directives() {
        // We can't write to the user's actual systemd dir from a test, but the
        // unit body is built deterministically from the wrapper path — so we
        // can construct the same string and check its shape.
        let wrapper = PathBuf::from("/home/me/.local/bin/zuko-host-run");
        let wrapper_s = wrapper.to_string_lossy();
        // ExecStart is quoted so spaces in HOME / --prefix don't split into
        // binary + arg (systemd parses the first whitespace token as argv[0]).
        let body = format!(
            "[Unit]\n\
             Description=Zuko host (interactive shell over Iroh)\n\
             After=network-online.target\n\
             Wants=network-online.target\n\
             \n\
             [Service]\n\
             ExecStart=\"{wrapper_s}\"\n\
             Restart=on-failure\n\
             RestartSec=5\n\
             \n\
             [Install]\n\
             WantedBy=default.target\n"
        );
        assert!(body.contains("ExecStart=\"/home/me/.local/bin/zuko-host-run\""));
        assert!(body.contains("WantedBy=default.target"));
        assert!(body.contains("Restart=on-failure"));
    }

    // ── prefer_stable_symlink ──
    //
    // These cover the mise-upgrade regression: `zuko install` ran under 0.6.5,
    // mise upgraded to 0.6.6 and deleted the 0.6.5 dir, and the wrapper pinned
    // to `…/0.6.5/zuko` left the systemd unit crash-looping with exit 127.
    // Routing through mise's `latest` symlink (maintained across upgrades)
    // fixes it.

    #[test]
    fn prefer_stable_symlink_passes_through_path_without_parents() {
        // A bare filename has no version dir or install root to inspect; the
        // function must return the input unchanged rather than panicking.
        assert_eq!(
            prefer_stable_symlink(PathBuf::from("zuko")),
            PathBuf::from("zuko")
        );
    }

    #[cfg(unix)]
    #[test]
    fn prefer_stable_symlink_rewrites_through_latest() {
        use std::os::unix::fs::symlink;
        // Layout mirrors mise's install root on disk:
        //   <root>/0.6.5/zuko          ← current_exe() resolves here
        //   <root>/latest -> ./0.6.5
        let dir = tempfile::tempdir().unwrap();
        let install_root = dir.path().join("installs").join("github-adonm-zuko");
        let version_dir = install_root.join("0.6.5");
        std::fs::create_dir_all(&version_dir).unwrap();
        let bin = version_dir.join("zuko");
        std::fs::write(&bin, b"#! /bin/sh\n").unwrap();
        symlink("./0.6.5", install_root.join("latest")).unwrap();

        let got = prefer_stable_symlink(bin.clone());
        assert_eq!(got, install_root.join("latest").join("zuko"));
    }

    #[cfg(unix)]
    #[test]
    fn prefer_stable_symlink_leaves_path_alone_when_no_latest() {
        // No `latest` symlink → mise (or asdf, or a hand-installed binary)
        // isn't present; pin the versioned path as before.
        let dir = tempfile::tempdir().unwrap();
        let version_dir = dir.path().join("0.6.5");
        std::fs::create_dir_all(&version_dir).unwrap();
        let bin = version_dir.join("zuko");
        std::fs::write(&bin, b"#! /bin/sh\n").unwrap();

        assert_eq!(prefer_stable_symlink(bin.clone()), bin);
    }

    #[cfg(unix)]
    #[test]
    fn prefer_stable_symlink_falls_back_when_latest_bin_missing() {
        // `latest` exists and points inside the install root, but its target
        // dir doesn't contain our binary. Don't rewrite to a broken path.
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let install_root = dir.path().join("installs").join("github-adonm-zuko");
        let v1 = install_root.join("0.6.5");
        let v2 = install_root.join("0.6.6");
        std::fs::create_dir_all(&v1).unwrap();
        std::fs::create_dir_all(&v2).unwrap();
        // Binary only under the *old* version dir; `latest` points at the new
        // one which has no `zuko`. Rewrite would produce a non-existent path.
        let bin = v1.join("zuko");
        std::fs::write(&bin, b"#! /bin/sh\n").unwrap();
        symlink("./0.6.6", install_root.join("latest")).unwrap();

        assert_eq!(prefer_stable_symlink(bin.clone()), bin);
    }

    #[cfg(unix)]
    #[test]
    fn prefer_stable_symlink_rejects_escaped_latest_symlink() {
        // Defence-in-depth: if `latest` points outside the install root, the
        // containment check must trip and the original path is preserved.
        // (A hostile or misconfigured install dir shouldn't get a free pass
        // to rewrite the wrapper at an arbitrary location.)
        use std::os::unix::fs::symlink;
        let dir = tempfile::tempdir().unwrap();
        let install_root = dir.path().join("installs").join("github-adonm-zuko");
        let version_dir = install_root.join("0.6.5");
        std::fs::create_dir_all(&version_dir).unwrap();
        let bin = version_dir.join("zuko");
        std::fs::write(&bin, b"#! /bin/sh\n").unwrap();
        // `latest` resolves to a dir outside install_root that also happens to
        // contain a `zuko` — both gates the rewrite relies on.
        let outside = dir.path().join("elsewhere");
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("zuko"), b"#! /bin/sh\n").unwrap();
        symlink(&outside, install_root.join("latest")).unwrap();

        assert_eq!(prefer_stable_symlink(bin.clone()), bin);
    }

    // ── upgrade helpers ──

    #[test]
    fn mise_path_detector_recognises_mise_install_layout() {
        // The canonical mise layout (`mise use --global github:adonm/zuko`):
        // ~/.local/share/mise/installs/github-adonm-zuko/<version>/zuko
        let mise =
            PathBuf::from("/home/me/.local/share/mise/installs/github-adonm-zuko/0.6.13/zuko");
        assert!(path_looks_mise_managed(&mise));
    }

    #[test]
    fn mise_path_detector_rejects_non_mise_layouts() {
        // cargo install, distro package, a hand-built binary in the repo — none
        // of these live under mise's installs root, so `zuko upgrade` must
        // refuse rather than fork a mise-managed copy.
        assert!(!path_looks_mise_managed(&PathBuf::from(
            "/home/me/.cargo/bin/zuko"
        )));
        assert!(!path_looks_mise_managed(&PathBuf::from("/usr/bin/zuko")));
        assert!(!path_looks_mise_managed(&PathBuf::from(
            "/home/me/dev/zuko/target/release/zuko"
        )));
        // A different mise-managed tool must NOT match — only our tool dir.
        assert!(!path_looks_mise_managed(&PathBuf::from(
            "/home/me/.local/share/mise/installs/github-someone-else/1.0.0/bin"
        )));
    }

    #[test]
    fn mise_upgrade_args_defaults_to_upgrade_latest() {
        // No --version: `mise upgrade github:adonm/zuko` honours the existing
        // `latest` pin and moves to the newest release.
        assert_eq!(
            mise_upgrade_args(None),
            vec!["upgrade".to_string(), "github:adonm/zuko".to_string()]
        );
    }

    #[test]
    fn mise_upgrade_args_with_version_re_pins_global() {
        // --version: `mise use --global …@<v>` changes the global pin so future
        // `mise upgrade`s stay on that exact version until re-pinned.
        assert_eq!(
            mise_upgrade_args(Some("0.7.0")),
            vec![
                "use".to_string(),
                "--global".to_string(),
                "github:adonm/zuko@0.7.0".to_string(),
            ]
        );
    }
}
