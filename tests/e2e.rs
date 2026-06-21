//! End-to-end smoke tests for `zuko`, run against the real Iroh network.
//!
//! Two flows are exercised, mirroring the former `scripts/e2e_test.py`:
//!
//! 1. **host ↔ connect (by saved name)** — spawn `zuko host`, read its ticket
//!    out of the on-disk `current_ticket` file (the daemon keeps the
//!    long-lived ticket off stdout), seed the test's isolated hosts file with
//!    that ticket under a name, and drive `zuko connect <name>` under a PTY
//!    (the client's raw-mode path needs a controlling terminal). This is the
//!    same path a real user hits after `zuko claim <code>`.
//!
//! 2. **share ↔ claim** — with the host still running, spawn `zuko share`,
//!    capture the memorable code it prints, run `zuko claim <code>
//!    --no-connect`, and confirm the claimed ticket matches the host's real
//!    one. **Also** asserts that `share` exits on its own (exit code 0) within
//!    a few seconds of `claim` returning — this catches the regression where
//!    `share` hung after a claim because the client never closed the handoff
//!    connection (see `src/handoff.rs::claim`).
//!
//! All zuko state (key, current_ticket, saved hosts) is isolated under a temp
//! `XDG_CONFIG_HOME` so the test never touches the operator's real config.
//!
//! ## Running
//!
//! These tests need network access to Iroh's public relays and a real PTY, so
//! they're gated behind `#[ignore]` — `cargo test` (the common CI fast path)
//! skips them. Run them explicitly:
//!
//! ```sh
//! cargo test --release --test e2e -- --ignored --nocapture
//! ```
//!
//! `--release` matches the runtime characteristics of a real `zuko` build.

// The host/connect test drives `/bin/sh` under a Unix PTY; the XDG_CONFIG_HOME
// convention is Unix-only too. The CI matrix runs ubuntu + macos, so this is
// not a loss in practice. portable-pty itself works on Windows, but the
// assumptions here don't.
#![cfg(unix)]

use std::io::{BufRead, BufReader, Read, Write};
use std::path::Path;
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};
use std::{fs, thread};

use anyhow::{bail, Context, Result};
use portable_pty::{native_pty_system, CommandBuilder as PtyCommand, PtySize};
use tempfile::TempDir;

const TOKEN: &str = "hello-zuko-ITEST";

// Generous timeouts: Iroh relay handshakes can be slow on CI runners.
const HOST_ONLINE_TIMEOUT: Duration = Duration::from_secs(60);
const CLIENT_WINDOW: Duration = Duration::from_secs(45);
const SHARE_CODE_TIMEOUT: Duration = Duration::from_secs(45);
const CLAIM_TIMEOUT: Duration = Duration::from_secs(90);
// After `claim` returns, `share` must exit on its own: the client closes the
// handoff connection once it has the payload (see `src/handoff.rs::claim`),
// which lets the host's `serve_handoff` return. Before that fix `share` hung
// for the whole session — invisible because the old Python harness
// unconditionally SIGTERM'd `share` in a `finally` block, so a hanging share
// looked identical to a clean one. This bound catches any regression.
// 20s is far beyond the host-side 5s `serve_handoff` close-wait; if we hit it,
// something is wrong.
const SHARE_EXIT_TIMEOUT: Duration = Duration::from_secs(20);

#[test]
#[ignore]
fn e2e() -> Result<()> {
    let zuko = zuko_bin()?;

    // Isolate ALL zuko state (key, current_ticket, hosts) in a tempdir so the
    // test is hermetic and never touches the operator's real config.
    let xdg = TempDir::new()?;
    eprintln!("XDG_CONFIG_HOME={}", xdg.path().display());

    let host = spawn_host(&zuko, xdg.path())?;
    // Hold the guard for the rest of the test; its Drop kills + reaps the
    // host even on early-return via `?` or a panicking assertion.
    let _host = ProcGuard::new(host);

    // The host keeps the long-lived ticket off stdout; read it from the
    // current_ticket file the daemon writes (the same source `zuko share`
    // reads).
    let ticket =
        wait_for_nonempty_file(&xdg.path().join("zuko/current_ticket"), HOST_ONLINE_TIMEOUT)?;
    eprintln!("host ticket: {}...", short(&ticket));

    // Run both checks; collect failures rather than bailing on the first so
    // a single run surfaces everything (matches the old Python harness).
    let mut failures: Vec<(&str, anyhow::Error)> = Vec::new();
    if let Err(e) = test_share_claim(&zuko, xdg.path(), &ticket) {
        failures.push(("share/claim", e));
    }
    if let Err(e) = test_host_connect(&zuko, xdg.path(), &ticket) {
        failures.push(("host/connect", e));
    }

    if failures.is_empty() {
        eprintln!("\nITEST OK: all end-to-end checks passed");
        Ok(())
    } else {
        for (name, e) in &failures {
            eprintln!("\n--- FAILED: {name} ---");
            eprintln!("{e:#}");
        }
        bail!("{} end-to-end check(s) failed", failures.len());
    }
}

// ───────────────────────────── helpers ───────────────────────────────────

/// Resolve the `zuko` binary path. Cargo sets `CARGO_BIN_EXE_zuko` when the
/// test is built via `cargo test`; fall back to `target/release/zuko` so the
/// test also works if someone runs it against a prebuilt binary.
fn zuko_bin() -> Result<String> {
    if let Some(s) = option_env!("CARGO_BIN_EXE_zuko") {
        return Ok(s.to_string());
    }
    let candidate = Path::new("target/release/zuko");
    if candidate.exists() {
        return Ok(candidate.display().to_string());
    }
    bail!(
        "zuko binary not found. Build it first: `cargo build --release`, or \
         run via `cargo test --release --test e2e -- --ignored`."
    );
}

/// Build a `Command` for `zuko` with `XDG_CONFIG_HOME` isolated to `xdg` and
/// `RUST_LOG=info` so failures surface useful diagnostics on stderr.
fn zuko_cmd(zuko: &str, xdg: &Path) -> Command {
    let mut cmd = Command::new(zuko);
    cmd.env("XDG_CONFIG_HOME", xdg).env("RUST_LOG", "info");
    cmd
}

fn short(s: &str) -> &str {
    s.get(..32).unwrap_or(s)
}

/// Wait until `path` exists and has non-empty trimmed contents, polling every
/// 250ms. Returns the trimmed contents.
fn wait_for_nonempty_file(path: &Path, timeout: Duration) -> Result<String> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Ok(s) = fs::read_to_string(path) {
            let trimmed = s.trim();
            if !trimmed.is_empty() {
                return Ok(trimmed.to_string());
            }
        }
        if Instant::now() >= deadline {
            bail!(
                "timed out after {:?} waiting for {}",
                timeout,
                path.display()
            );
        }
        thread::sleep(Duration::from_millis(250));
    }
}

/// Poll `child.try_wait()` until it exits or `timeout` elapses; on timeout,
/// kill the child (so it doesn't leak) and bail.
fn wait_for_exit(child: &mut Child, timeout: Duration) -> Result<ExitStatus> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(status) = child.try_wait().context("poll child")? {
            return Ok(status);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("timed out after {:?} waiting for child to exit", timeout);
        }
        thread::sleep(Duration::from_millis(100));
    }
}

/// Read the first non-blank line from a child's piped stdout, with an overall
/// timeout. Runs the blocking `read_line` on a worker thread so the timeout
/// is enforced from the caller's side.
fn first_nonblank_line(stdout: std::process::ChildStdout, timeout: Duration) -> Result<String> {
    let (tx, rx) = mpsc::channel::<Option<String>>();
    thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line) {
                Ok(0) => break, // EOF
                Ok(_) => {
                    let trimmed = line.trim();
                    if !trimmed.is_empty() {
                        let _ = tx.send(Some(trimmed.to_string()));
                        return;
                    }
                    // else: blank line, keep reading.
                }
                Err(_) => break,
            }
        }
        let _ = tx.send(None);
    });
    match rx.recv_timeout(timeout) {
        Ok(Some(s)) => Ok(s),
        Ok(None) => bail!("stdout closed with no non-blank line"),
        Err(_) => bail!("timed out after {:?} waiting for stdout line", timeout),
    }
}

/// RAII guard: kills + reaps the child on drop so a test failure can never
/// leak a process. (Drop, not a method, so it fires even on `?` returns.)
struct ProcGuard(Option<Child>);

impl ProcGuard {
    fn new(child: Child) -> Self {
        Self(Some(child))
    }
    fn get_mut(&mut self) -> &mut Child {
        self.0.as_mut().expect("ProcGuard used after drop")
    }
}

impl Drop for ProcGuard {
    fn drop(&mut self) {
        if let Some(child) = self.0.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

// ─────────────────────────── spawn host ──────────────────────────────────

/// Spawn `zuko host --shell /bin/sh` under the isolated XDG dir. `sh` keeps
/// the connect test deterministic (no per-shell rc quirks). Stdout/stderr are
/// dropped: the ticket comes from the on-disk file, not the daemon's output,
/// and the daemon is chatty on stderr in ways that would only obscure test
/// output. (Failures show up as the host never writing `current_ticket`.)
fn spawn_host(zuko: &str, xdg: &Path) -> Result<Child> {
    zuko_cmd(zuko, xdg)
        .args(["host", "--shell", "/bin/sh"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("spawn {zuko} host"))
}

// ─────────────────────────── share ↔ claim ───────────────────────────────

fn test_share_claim(zuko: &str, xdg: &Path, expected_ticket: &str) -> Result<()> {
    eprintln!("\n=== test: share ↔ claim ===");

    let mut share = zuko_cmd(zuko, xdg)
        .args([
            "share",
            "--count",
            "1",
            "--timeout",
            "120",
            "--label",
            "e2e-host",
        ])
        .stdout(Stdio::piped()) // the code lands on stdout
        .stderr(Stdio::inherit()) // banner visible under --nocapture
        .spawn()
        .context("spawn zuko share")?;
    // Take stdout now so we can read it on the main thread; the guard holds
    // the rest of the child and will kill+reap on drop.
    let share_stdout = share.stdout.take().expect("piped stdout");
    let mut share = ProcGuard::new(share);

    // The first non-blank stdout line is the code; share's banner goes to
    // stderr (so it doesn't pollute piping the code).
    let code = first_nonblank_line(share_stdout, SHARE_CODE_TIMEOUT)
        .context("no code printed by `zuko share`")?;
    eprintln!("share code: {code}");

    // `zuko claim <code> --no-connect`: fetches the ticket, saves it under
    // --as, and skips the PTY session. The bare `zuko <code>` shorthand
    // dispatches to the same `handoff::claim` Rust function — verified by
    // unit tests for `code::looks_like_code`, so we don't need a second
    // network round-trip here. Stderr inherits so its diagnostics show up
    // under --nocapture; we don't need stdout.
    let mut claim = zuko_cmd(zuko, xdg)
        .args([
            "claim",
            &code,
            "--no-connect",
            "--as",
            "e2e-claimed",
            "--timeout",
            &CLAIM_TIMEOUT.as_secs().to_string(),
        ])
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit())
        .spawn()
        .context("spawn zuko claim")?;
    let claim_status = wait_for_exit(
        &mut claim,
        // Wall-time bound slightly above the inner --timeout so the inner
        // one is the binding constraint in normal operation; this just
        // guards against zuko itself wedging.
        CLAIM_TIMEOUT + Duration::from_secs(30),
    )?;
    if !claim_status.success() {
        bail!("`zuko claim` exited {}", claim_status.code().unwrap_or(-1));
    }

    // Confirm it landed in the saved-hosts file under the right name+ticket.
    // (`zuko ls` only prints names, so read the hosts file directly to also
    // verify the saved ticket matches.)
    let hosts_path = xdg.join("zuko/hosts");
    let hosts = fs::read_to_string(&hosts_path)
        .with_context(|| format!("read {}", hosts_path.display()))?;
    eprintln!("---- saved hosts file ----\n{hosts}---------------------------");

    for line in hosts.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() == 2 && parts[0] == "e2e-claimed" {
            if parts[1] != expected_ticket {
                bail!(
                    "claimed ticket != host ticket\n  claimed: {}\n  host:    {}",
                    parts[1],
                    expected_ticket
                );
            }
            eprintln!("OK: share/claim delivered the real ticket");

            // Regression guard: `share` must exit on its own now that `claim`
            // has returned. The client closes the handoff connection after
            // reading the payload (`src/handoff.rs::claim`), which lets the
            // host's `serve_handoff` return and `share`'s loop terminate.
            // Before that fix this assertion would hang — invisible in the
            // old Python harness because its `finally` always SIGTERM'd share.
            eprintln!(
                "waiting for `share` to exit on its own (≤{:?})…",
                SHARE_EXIT_TIMEOUT
            );
            let status = wait_for_exit(share.get_mut(), SHARE_EXIT_TIMEOUT)
                .context("`share` did not exit on its own after claim")?;
            if !status.success() {
                bail!(
                    "`share` exited {} after claim (expected 0)",
                    status.code().unwrap_or(-1)
                );
            }
            eprintln!(
                "OK: `share` exited cleanly (code {:?}) after the claim",
                status.code()
            );
            return Ok(());
        }
    }
    bail!("e2e-claimed not in saved-hosts file");
}

// ─────────────────────────── host ↔ connect ──────────────────────────────

fn test_host_connect(zuko: &str, xdg: &Path, ticket: &str) -> Result<()> {
    eprintln!("\n=== test: host ↔ connect (by saved name) ===");

    // Seed the saved-hosts file directly so we can exercise `zuko connect`
    // without going through the OTP handoff (the share/claim test covers
    // that). Format must stay in sync with `store::write_hosts`:
    // `<name>\t<ticket>\n`.
    let zuko_dir = xdg.join("zuko");
    fs::create_dir_all(&zuko_dir).context("mkdir zuko dir")?;
    let seeded = format!("# zuko saved hosts (seeded by e2e test)\ne2e-direct\t{ticket}\n");
    fs::write(zuko_dir.join("hosts"), seeded).context("seed hosts file")?;

    // Fork `zuko connect e2e-direct` on a PTY: crossterm's enable_raw_mode on
    // stdin needs a controlling terminal, which the PTY provides. portable-pty
    // is already a dependency (the host uses it for the shell PTY), so no new
    // crate is needed.
    let pty = native_pty_system();
    let pair = pty
        .openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .context("open pty")?;

    // Clone the reader BEFORE spawning the child (portable-pty requirement:
    // the slave-side spawn dup's the master, so the reader must exist first).
    let reader = pair.master.try_clone_reader().context("clone pty reader")?;
    let mut writer = pair.master.take_writer().context("take pty writer")?;

    let mut cmd = PtyCommand::new(zuko);
    cmd.args(["connect", "e2e-direct"]);
    cmd.env("XDG_CONFIG_HOME", xdg.as_os_str());
    cmd.env("RUST_LOG", "");
    let mut child = pair
        .slave
        .spawn_command(cmd)
        .context("spawn zuko connect under pty")?;
    // Dropping the slave closes the controlling-terminal fd in this process;
    // the child already has its copy. The master stays open so we can read.
    drop(pair.slave);

    // Shared output buffer: the reader thread appends, the main thread peeks
    // to detect the echoed token. (Mutex is fine — throughput is tiny.)
    let out_buf: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::with_capacity(8 * 1024)));
    let reader_buf = Arc::clone(&out_buf);
    let reader_handle = thread::spawn(move || {
        let mut reader = reader;
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    if let Ok(mut o) = reader_buf.lock() {
                        o.extend_from_slice(&buf[..n]);
                    }
                }
                Err(_) => break,
            }
        }
    });

    // Drive the session: wait for the remote shell to come up, type the
    // command once, watch for the echo, then leave cleanly. Matches the old
    // Python harness's timing so behaviour is directly comparable.
    let start = Instant::now();
    let token_bytes = TOKEN.as_bytes();
    let mut typed = false;
    let mut success = false;
    while start.elapsed() < CLIENT_WINDOW {
        // Child exited on its own (e.g. shell died) — stop polling.
        if child.try_wait().ok().flatten().is_some() {
            break;
        }
        // Give the remote shell a moment to come up, then type the command
        // once. 3s matches the old Python harness.
        if !typed && start.elapsed() > Duration::from_secs(3) {
            let _ = writer.write_all(b"echo ");
            let _ = writer.write_all(TOKEN.as_bytes());
            let _ = writer.write_all(b"\r");
            typed = true;
        }
        // Once the token is echoed back, leave the shell cleanly.
        if typed {
            let saw_token = out_buf
                .lock()
                .map(|o| o.windows(token_bytes.len()).any(|w| w == token_bytes))
                .unwrap_or(false);
            if saw_token {
                let _ = writer.write_all(b"exit\r");
                // Give the shell a moment to honour `exit`, then reap.
                thread::sleep(Duration::from_secs(1));
                let _ = child.wait();
                success = true;
                break;
            }
        }
        thread::sleep(Duration::from_millis(200));
    }

    // Reap the reader thread (returns once the master side is closed, which
    // happens when the child exits and the kernel tears down the slave).
    drop(writer);
    let _ = reader_handle.join();
    let out = Arc::try_unwrap(out_buf)
        .map(|m| m.into_inner().unwrap_or_default())
        .unwrap_or_default();

    let tail = String::from_utf8_lossy(&out);
    let tail = tail.get(tail.len().saturating_sub(300)..).unwrap_or(&tail);
    eprintln!("---- client output (tail) ----\n{tail}-------------------------------");

    if !success {
        bail!("client window elapsed without the session completing");
    }
    if !out.windows(token_bytes.len()).any(|w| w == token_bytes) {
        bail!("token {TOKEN:?} not seen in client output");
    }
    eprintln!("OK: client saw the shell's echo output");
    Ok(())
}
