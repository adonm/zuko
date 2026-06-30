//! Linux-only implementation of `zuko app` (the cage + wlr-screencopy backend).
//!
//! See [`super`] for the cross-platform shell + reusable helpers. This module
//! pulls in the wayland-client stack (feature-gated under `gui-app`).

use std::io::Write;
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use std::{env, fs};

use anyhow::{Context, Result, bail};
use crossterm::event::{
    self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers, MouseButton, MouseEvent,
    MouseEventKind,
};
use memmap2::MmapMut;
use rustix::fs::{MemfdFlags, memfd_create};
use wayland_client::{
    Connection, Dispatch, EventQueue, QueueHandle,
    globals::{GlobalListContents, registry_queue_init},
    protocol::{wl_buffer, wl_output, wl_pointer, wl_registry, wl_seat, wl_shm, wl_shm_pool},
};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1::{self, ZwpVirtualKeyboardManagerV1},
    zwp_virtual_keyboard_v1::{self, ZwpVirtualKeyboardV1},
};
use wayland_protocols_wlr::screencopy::v1::client::{
    zwlr_screencopy_frame_v1::{self, ZwlrScreencopyFrameV1},
    zwlr_screencopy_manager_v1::{self, ZwlrScreencopyManagerV1},
};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1::{self, ZwlrVirtualPointerManagerV1},
    zwlr_virtual_pointer_v1::{self, ZwlrVirtualPointerV1},
};

// Reusable helpers from the parent (Kitty graphics, app discovery, terminal
// guard). Child modules can reach the parent's private items.
use super::{
    DEFAULT_OUTPUT, Launch, TerminalModeGuard, encode_rgba_png, encode_test_pattern,
    kitty_clear_screen, kitty_emit_png, print_discovered_apps, print_launch, resolve_launch,
    validate_args,
};
use crate::AppArgs;

/// An XKB text keymap (us layout). cage's libxkbcommon parses this when we
/// create the virtual keyboard. Embedded (not compiled at runtime) so zuko has
/// no libxkbcommon build/link dependency — cage supplies that. The
/// char→keycode table below is consistent with this keymap, so the round-trip
/// is correct regardless of the user's physical layout (their terminal already
/// resolved the keypress to a character before we see it).
const KEYMAP_US: &str = include_str!("keymap_us.xkb");

/// How long to wait for cage to bind its Wayland socket at startup.
const SOCKET_WAIT: Duration = Duration::from_secs(5);
/// How long to wait for the XTWINOPS `CSI 16 t` cell-size reply. Round-trips
/// through the Iroh relay when `zuko app` runs over `zuko <host>`, so this is
/// generous; override with `ZUKO_PIXEL_PROBE_MS`. On timeout we fall back to
/// cell-precision mouse (no sub-cell accuracy).
const PIXEL_PROBE: Duration = Duration::from_millis(500);

pub fn run(args: AppArgs) -> Result<()> {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "zuko=info".into()),
        )
        .try_init();

    validate_args(&args)?;

    if args.test_pattern {
        let _terminal = TerminalModeGuard::enter().context("enter terminal app mode")?;
        let (w, h) = DEFAULT_OUTPUT;
        kitty_clear_screen().ok();
        let png = encode_test_pattern(w as usize, h as usize)?;
        let placement = term_cell_size().map(|(c, r)| {
            compute_placement(u32::from(c), u32::from(r), None, (w as u32, h as u32))
        });
        kitty_emit_png(w as u32, h as u32, &png, true, placement)?;
        eprintln!("zuko app: Kitty test pattern rendered at {w}x{h}; press Enter to exit");
        let mut buf = String::new();
        let _ = std::io::stdin().read_line(&mut buf);
        return Ok(());
    }

    if args.list {
        print_discovered_apps()?;
        return Ok(());
    }

    let launch = resolve_launch(&args, args.software, args.no_sandbox)
        .context("resolve app launch command")?;

    if args.dry_run {
        print_launch(&launch);
        return Ok(());
    }

    let mut terminal = TerminalModeGuard::enter().context("enter terminal app mode")?;

    // Probe the terminal's pixel geometry so we can switch mouse reporting to
    // SGR-pixel (1016) — pixel-accurate clicks/cursor instead of ~1-cell
    // quantization. Best-effort: if the terminal won't tell us (or a slow relay
    // beats the probe), keep cell coords and the cursor just snaps to cells.
    let cell_px = probe_terminal_cell_pixels(PIXEL_PROBE);
    if term_pixel_dims(cell_px).is_some() {
        let _ = terminal.enable_pixel_mouse();
    } else {
        eprintln!(
            "zuko app: terminal pixel size unavailable within {:?}; \
             cursor/clicks resolve to cell precision (set ZUKO_PIXEL_PROBE_MS to extend)",
            PIXEL_PROBE
        );
    }

    // cage runs in the real XDG_RUNTIME_DIR (so Flatpak children reach the
    // session); it auto-names its socket, so snapshot first and discover the
    // new name after spawn rather than assuming wayland-0.
    let xdg_runtime = make_xdg_runtime_dir()?;
    let sockets_before = snapshot_wayland_sockets(&xdg_runtime);

    // In-cage xdg-desktop-portal (default: auto, when the host has it). The
    // private D-Bus starts BEFORE cage so the app can inherit its address;
    // the portal daemons start AFTER cage's socket exists (the backend renders
    // into cage). PortalStack drops at end of run() to reap the daemons.
    let want_portal = if args.no_portal {
        false
    } else if args.portal {
        true
    } else {
        portal_available()
    };
    let mut portal_stack = PortalStack {
        dbus: None,
        portal: None,
        backend: None,
        dbus_pgid: None,
    };
    let portal_bus = if want_portal && let Ok((bus, dbus, pgid)) = start_portal_dbus(&xdg_runtime) {
        portal_stack.dbus = Some(dbus);
        portal_stack.dbus_pgid = Some(pgid);
        Some(bus)
    } else if want_portal {
        eprintln!(
            "zuko app: couldn't start the in-cage portal bus; portal dialogs \
             may appear on the host desktop instead of the TUI"
        );
        None
    } else {
        None
    };

    let mut cage = spawn_cage(&args, &launch, &xdg_runtime, portal_bus.as_deref())?;
    let socket = wait_for_socket(&mut cage, &xdg_runtime, &sockets_before)?;

    if let (Some(bus), Some(pgid)) = (&portal_bus, portal_stack.dbus_pgid)
        && let Ok((portal, backend)) = start_portal_backends(bus, &xdg_runtime, &socket, pgid)
    {
        portal_stack.portal = Some(portal);
        portal_stack.backend = Some(backend);
        eprintln!("zuko app: in-cage portal up (file dialogs will render in the TUI)");
    }

    eprintln!(
        "zuko app: cage running {} at {}x{} (pixman/headless) on {}; connecting…",
        launch.label, DEFAULT_OUTPUT.0, DEFAULT_OUTPUT.1, socket
    );

    // Point our own Wayland client env at cage's socket, then connect.
    // SAFETY: single-threaded at this point (before the Wayland event loop or
    // any input thread starts); no other thread can read these env vars
    // concurrently. Edition 2024 marks set_var unsafe for the data-race risk.
    unsafe {
        env::set_var("XDG_RUNTIME_DIR", &xdg_runtime);
        env::set_var("WAYLAND_DISPLAY", &socket);
    }
    let conn = Connection::connect_to_env().context("connect to cage Wayland socket")?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn)?;
    let qh = queue.handle();

    let mut state = State {
        shm: Some(globals.bind(&qh, 1..=2, ())?),
        output: Some(globals.bind(&qh, 1..=4, ())?),
        manager: Some(globals.bind(&qh, 1..=3, ())?),
        // Input protocols (all advertised by cage — verified). If any are
        // missing we proceed without that input device rather than aborting.
        seat: globals.bind(&qh, 5..=9, ()).ok(),
        vk_manager: globals.bind(&qh, 1..=1, ()).ok(),
        vp_manager: globals.bind(&qh, 1..=2, ()).ok(),
        cursor: !args.no_cursor,
        cell_px,
        ..Default::default()
    };

    // Create the virtual keyboard + pointer up front (best-effort; non-fatal).
    setup_input(&mut state, &qh);
    let _ = conn.flush();

    let frame_interval = Duration::from_millis((1000 / u64::from(args.fps)).max(1));
    let mut next_frame = Instant::now();
    let started_at = Instant::now();

    kitty_clear_screen().ok();

    let result = run_loop(
        &mut state,
        &conn,
        &mut queue,
        &mut cage,
        frame_interval,
        &mut next_frame,
        started_at,
    );

    // Best-effort cleanup. SIGTERM cage first (don't SIGKILL) so it runs its
    // wlroots teardown and reaps the app child; SIGKILL only as a fallback.
    // cage doesn't reliably unlink its Wayland socket on SIGTERM, so we remove
    // the socket + `.lock` ourselves after it exits (otherwise they accumulate
    // in the shared XDG_RUNTIME_DIR — the "wayland lock" leftover). The
    // TerminalModeGuard drop then restores the terminal + clears Kitty.
    shutdown_cage(&mut cage, &xdg_runtime, &socket);
    result
}

/// SIGTERM cage and give it ~1s to exit (reap its app child); SIGKILL only as a
/// fallback. Then unlink the Wayland socket + `.lock` it left in the runtime dir.
fn shutdown_cage(cage: &mut Child, xdg_runtime: &Path, socket: &str) {
    let pid = cage.id() as i32;
    if pid > 0 {
        // SAFETY: sending a signal to a PID we own. libc::kill is signal-safe.
        unsafe {
            libc::kill(pid, libc::SIGTERM);
        }
    }
    for _ in 0..50 {
        if cage.try_wait().ok().flatten().is_some() {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    if cage.try_wait().ok().flatten().is_none() {
        let _ = cage.kill();
        let _ = cage.wait();
    }
    // cage's SIGTERM teardown doesn't unlink its socket; do it for it.
    let _ = fs::remove_file(xdg_runtime.join(socket));
    let _ = fs::remove_file(format!("{}.lock", xdg_runtime.join(socket).display()));
}

// ──────────────────────── in-cage xdg-desktop-portal ────────────────────────
//
// When the host has xdg-desktop-portal + a backend installed, start a PRIVATE
// D-Bus session + xdg-desktop-portal + (gtk) backend against cage's Wayland,
// and point cage's child app at that bus. The app's portal calls (file open/
// save dialogs) then route to OUR portal-gtk, which renders the dialog on
// cage's output → captured → shown in the TUI. Without this, portal dialogs
// render on the host's own desktop (invisible/unusable over a remote link).

/// Resolve a binary: an explicit `$ZUKO_*` override, then common libexec/lib
/// dirs, then PATH.
fn find_bin(name: &str, override_var: &str) -> Option<PathBuf> {
    if let Some(p) = env::var_os(override_var)
        && PathBuf::from(&p).is_file()
    {
        return Some(PathBuf::from(p));
    }
    for dir in ["/usr/libexec", "/usr/lib", "/usr/lib/x86_64-linux-gnu"] {
        let p = PathBuf::from(dir).join(name);
        if p.is_file() {
            return Some(p);
        }
    }
    if let Ok(path) = env::var("PATH") {
        for dir in path.split(':') {
            let p = PathBuf::from(dir).join(name);
            if p.is_file() {
                return Some(p);
            }
        }
    }
    None
}

fn portal_daemon_bin() -> Option<PathBuf> {
    find_bin("xdg-desktop-portal", "ZUKO_PORTAL")
}

/// A backend that renders dialogs over Wayland (gtk is standalone; gnome/wlr
/// are fallbacks). portal-gtk is preferred because it doesn't need its desktop
/// environment running (cage is just a kiosk).
fn portal_backend_bin() -> Option<PathBuf> {
    find_bin("xdg-desktop-portal-gtk", "ZUKO_PORTAL_BACKEND")
        .or_else(|| find_bin("xdg-desktop-portal-gnome", "ZUKO_PORTAL_BACKEND"))
        .or_else(|| find_bin("xdg-desktop-portal-wlr", "ZUKO_PORTAL_BACKEND"))
}

/// Whether the host can run an in-cage portal (both the daemon + a backend
/// binary are present). Drives the auto-detect default for `--portal`.
fn portal_available() -> bool {
    portal_daemon_bin().is_some() && portal_backend_bin().is_some()
}

/// Held across the session so its `Drop` reaps the daemons; they're started in
/// two phases (D-Bus before cage, portal+backend after the Wayland socket).
/// `dbus_pgid` is the shared process group (D-Bus is the leader; the portal +
/// backend join it), so a `killpg` reaps any helpers the daemons activate too.
struct PortalStack {
    dbus: Option<Child>,
    portal: Option<Child>,
    backend: Option<Child>,
    dbus_pgid: Option<i32>,
}

impl PortalStack {
    fn kill_all(&mut self) {
        // Kill the whole group (D-Bus + portal + backend + any D-Bus-activated
        // helpers), then reap the three we have handles for.
        if let Some(pgid) = self.dbus_pgid
            && pgid > 0
        {
            // SAFETY: killpg on a group we created. Signal-safe.
            unsafe {
                libc::killpg(pgid, libc::SIGTERM);
            }
        }
        for child in [&mut self.backend, &mut self.portal, &mut self.dbus]
            .into_iter()
            .flatten()
        {
            let _ = child.wait();
        }
    }
}

impl Drop for PortalStack {
    fn drop(&mut self) {
        self.kill_all();
    }
}

/// Start the private D-Bus session bus (before cage, so the app can inherit
/// its address). Returns the bus address, the daemon child, and its process
/// group id (the portal daemons join it so they can be reaped together).
fn start_portal_dbus(xdg_runtime: &Path) -> Result<(String, Child, i32)> {
    use std::os::unix::process::CommandExt;
    let dbus_path = xdg_runtime.join(format!("zuko-dbus-{}", std::process::id()));
    let _ = fs::remove_file(&dbus_path); // clear any stale socket
    let bus = format!("unix:path={}", dbus_path.display());
    let mut cmd = Command::new("dbus-daemon");
    cmd.args(["--session", "--nofork", "--address", &bus])
        .process_group(0) // new group; this child's pid == its pgid
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let child = cmd
        .spawn()
        .context("spawn dbus-daemon for in-cage portal")?;
    let pgid = child.id() as i32;
    for _ in 0..50 {
        if dbus_path.exists() {
            return Ok((bus, child, pgid));
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    bail!(
        "dbus-daemon didn't create its socket at {}",
        dbus_path.display()
    );
}

/// Start xdg-desktop-portal + a backend on the private bus (in the D-Bus
/// process group), the backend rendering into cage's Wayland socket.
/// `XDG_CURRENT_DESKTOP` is emptied so the portal picks the standalone gtk
/// backend (not a desktop-mandated one).
fn start_portal_backends(
    bus: &str,
    xdg_runtime: &Path,
    socket: &str,
    dbus_pgid: i32,
) -> Result<(Child, Child)> {
    use std::os::unix::process::CommandExt;
    let daemon_bin = portal_daemon_bin().context("xdg-desktop-portal binary vanished")?;
    let backend_bin = portal_backend_bin().context("portal backend binary vanished")?;
    let portal = Command::new(&daemon_bin)
        .env("DBUS_SESSION_BUS_ADDRESS", bus)
        .env("XDG_CURRENT_DESKTOP", "")
        .process_group(dbus_pgid)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("spawn {}", daemon_bin.display()))?;
    let backend = Command::new(&backend_bin)
        .env("DBUS_SESSION_BUS_ADDRESS", bus)
        .env("XDG_RUNTIME_DIR", xdg_runtime)
        .env("WAYLAND_DISPLAY", socket)
        .env("XDG_CURRENT_DESKTOP", "")
        .process_group(dbus_pgid)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .with_context(|| format!("spawn {}", backend_bin.display()))?;
    Ok((portal, backend))
}

fn run_loop(
    state: &mut State,
    conn: &Connection,
    queue: &mut EventQueue<State>,
    cage: &mut Child,
    frame_interval: Duration,
    next_frame: &mut Instant,
    started_at: Instant,
) -> Result<()> {
    let mut placed = false;
    let mut last_cells: Option<(u16, u16)> = None;
    loop {
        if let Some(status) = cage.try_wait().context("poll cage process")? {
            eprintln!("zuko app: cage exited with {status}");
            break;
        }

        let now = Instant::now();
        if now >= *next_frame {
            *next_frame = now + frame_interval;
            if let Err(e) = capture_and_emit(state, conn, queue, &mut placed, &mut last_cells) {
                // A single frame failing shouldn't kill the session (e.g. the
                // app is mid-resize); log and continue. A broken connection,
                // however, surfaces from blocking_dispatch below.
                eprintln!("zuko app: frame skipped: {e:#}");
            }
        }

        pump_terminal_input(state, started_at)?;
        let _ = conn.flush();

        // Drain any pending Wayland events without blocking (e.g. late
        // screencopy callbacks, output changes). Ignore drain errors while cage
        // is still alive — the capture path reports real ones.
        let _ = queue.dispatch_pending(state);

        std::thread::sleep(Duration::from_millis(8));
    }
    Ok(())
}

/// Capture one frame from cage's headless output via wlr-screencopy and emit it
/// to the terminal as a Kitty PNG, scaled to fit the terminal's cell grid.
fn capture_and_emit(
    state: &mut State,
    conn: &Connection,
    queue: &mut EventQueue<State>,
    placed: &mut bool,
    last_cells: &mut Option<(u16, u16)>,
) -> Result<()> {
    // Re-place when the terminal cell grid changes (resize) so the c=/r=
    // scale-to-fit picks up the new size.
    let cells = term_cell_size();
    if cells != *last_cells {
        *placed = false;
        *last_cells = cells;
    }

    // Reset per-capture fields.
    state.dims = None;
    state.captured = None;
    state.done = None;

    let output = state.output.as_ref().context("no wl_output bound")?;
    let manager = state
        .manager
        .as_ref()
        .context("no screencopy manager bound")?;
    let frame = manager.capture_output(0, output, &queue.handle(), ());
    state.frame = Some(frame);
    conn.flush().ok();

    // Dispatch until the capture completes (Ready/Failed) or the connection
    // breaks. cage resolves a headless screencopy within a few milliseconds.
    let deadline = Instant::now() + Duration::from_secs(2);
    while state.done.is_none() {
        if Instant::now() > deadline {
            bail!("screencopy frame timed out");
        }
        queue.blocking_dispatch(state)?;
    }

    match state.done.take() {
        Some(Ok(())) => {}
        Some(Err(e)) => bail!("{e}"),
        None => bail!("capture ended without status"),
    }
    let (w, h, rgba) = state
        .captured
        .take()
        .context("capture Ready without frame bytes")?;
    // Dirty-frame "diff": if the new RGBA is byte-identical to the last emitted
    // frame AND the placement is already live, skip encode/emit — the terminal
    // is already showing exactly this. Always (re)emit when (re)placing.
    let needs_place = !*placed;
    *placed = true;
    let changed = state.prev_frame.as_deref() != Some(rgba.as_slice());
    if needs_place || changed {
        // Aspect-preserving (letterboxed) cell rectangle for this terminal.
        let placement = cells.map(|(c, r)| {
            compute_placement(
                u32::from(c),
                u32::from(r),
                state.cell_px,
                (w as u32, h as u32),
            )
        });
        let png = encode_rgba_png(&rgba, w, h)?;
        kitty_emit_png(w as u32, h as u32, &png, needs_place, placement)?;
        state.prev_frame = Some(rgba);
    }
    Ok(())
}

/// The current terminal cell grid (cols, rows) via TIOCGWINSZ. Always available
/// on a real tty; used to make the Kitty image scale to fit (c=/r=).
fn term_cell_size() -> Option<(u16, u16)> {
    let mut winsz = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut winsz) };
    if rc != 0 || winsz.ws_col == 0 || winsz.ws_row == 0 {
        return None;
    }
    Some((winsz.ws_col, winsz.ws_row))
}

/// Aspect-preserving placement: the largest source-aspect rectangle that fits
/// in the terminal's cell grid, centered, with letterbox offsets. Returns
/// `(span_cols, span_rows, off_col, off_row)`. Cell pixel size is the probed
/// `cell_px` (or a 1:2 w:h default — typical for monospace), since cells aren't
/// square and the source's pixel aspect must be preserved in the cell grid.
fn compute_placement(
    cols: u32,
    rows: u32,
    cell_px: Option<(u16, u16)>,
    src: (u32, u32),
) -> (u32, u32, u32, u32) {
    let (sw, sh) = (src.0.max(1), src.1.max(1));
    let (cw, ch) = cell_px
        .map(|(w, h)| (u32::from(w).max(1), u32::from(h).max(1)))
        .unwrap_or((1, 2));
    let avail_w = cols.saturating_mul(cw);
    let avail_h = rows.saturating_mul(ch);
    // Fit the source aspect into the available pixel area (letterbox, not stretch).
    let scale = (avail_w as f64 / sw as f64).min(avail_h as f64 / sh as f64);
    let disp_w_px = ((sw as f64 * scale).round() as u32).max(1);
    let disp_h_px = ((sh as f64 * scale).round() as u32).max(1);
    let span_cols = ((disp_w_px + cw / 2) / cw).clamp(1, cols);
    let span_rows = ((disp_h_px + ch / 2) / ch).clamp(1, rows);
    let off_col = (cols - span_cols) / 2;
    let off_row = (rows - span_rows) / 2;
    (span_cols, span_rows, off_col, off_row)
}

/// Terminal pixel dimensions, for SGR-pixel mouse mapping. Resolution:
/// 1. `ws_xpixel`/`ws_ypixel` (TIOCGWINSZ) — instant + relay-proof when the
///    terminal populates them.
/// 2. `cols × cell_px` / `rows × cell_px`, where `cell_px` is the probed
///    (CSI 16 t) per-cell device-pixel size — HiDPI-correct.
///
/// `None` when neither is available → caller falls back to cell-precision.
fn term_pixel_dims(cell_px: Option<(u16, u16)>) -> Option<(u32, u32)> {
    let mut winsz = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut winsz) };
    if rc == 0 && winsz.ws_xpixel > 0 && winsz.ws_ypixel > 0 {
        return Some((winsz.ws_xpixel as u32, winsz.ws_ypixel as u32));
    }
    if let Some((cw, ch)) = cell_px
        && winsz.ws_col > 0
        && winsz.ws_row > 0
    {
        return Some((
            u32::from(winsz.ws_col) * u32::from(cw),
            u32::from(winsz.ws_row) * u32::from(ch),
        ));
    }
    None
}

/// Probe the terminal's per-cell pixel size via the XTWINOPS `CSI 16 t` query.
/// Returns `(width, height)` in device pixels, or `None` if the terminal
/// doesn't answer within the timeout (then we use cell-precision mouse). Must
/// run in raw mode (the caller enters it via `TerminalModeGuard` first).
fn probe_terminal_cell_pixels(timeout: Duration) -> Option<(u16, u16)> {
    let timeout = env::var("ZUKO_PIXEL_PROBE_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .map(Duration::from_millis)
        .unwrap_or(timeout);
    let mut out = std::io::stdout();
    let _ = out.write_all(b"\x1b[16t");
    let _ = out.flush();

    set_stdin_nonblocking(true);
    let deadline = Instant::now() + timeout;
    let mut buf: Vec<u8> = Vec::with_capacity(64);
    let mut chunk = [0u8; 64];
    let mut found = None;
    while found.is_none() && Instant::now() < deadline {
        // Raw non-blocking read on stdin; >0 bytes, 0 on EOF, -1/EAGAIN if empty.
        let n = unsafe {
            libc::read(
                libc::STDIN_FILENO,
                chunk.as_mut_ptr() as *mut _,
                chunk.len(),
            )
        };
        if n > 0 {
            buf.extend_from_slice(&chunk[..n as usize]);
            found = parse_cell_size_reply(&buf);
        } else {
            std::thread::sleep(Duration::from_millis(3));
        }
    }
    // Drain residual bytes (e.g. a late reply over a slow relay) so the
    // crossterm event loop doesn't parse them as garbage events later.
    while unsafe {
        libc::read(
            libc::STDIN_FILENO,
            chunk.as_mut_ptr() as *mut _,
            chunk.len(),
        )
    } > 0
    {}
    set_stdin_nonblocking(false);
    found
}

/// Parse the XTWINOPS cell-size reply `CSI 6 ; <height> ; <width> t` out of an
/// arbitrary byte buffer. Returns `(width, height)` in pixels. Scans past
/// leading noise (other escape sequences arriving first).
fn parse_cell_size_reply(buf: &[u8]) -> Option<(u16, u16)> {
    let s = std::str::from_utf8(buf).ok()?;
    let after = s.split("\x1b[6;").nth(1)?;
    let end = after.find('t')?;
    let mut nums = after[..end].split(';');
    // Reply puts height before width: CSI 6 ; <height> ; <width> t.
    let h: u16 = nums.next()?.trim().parse().ok()?;
    let w: u16 = nums.next()?.trim().parse().ok()?;
    Some((w, h))
}

/// Toggle `O_NONBLOCK` on stdin so the cell-size probe can read with a deadline
/// instead of blocking forever on terminals that never answer.
fn set_stdin_nonblocking(on: bool) {
    unsafe {
        let fd = libc::STDIN_FILENO;
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 {
            return;
        }
        let new = if on {
            flags | libc::O_NONBLOCK
        } else {
            flags & !libc::O_NONBLOCK
        };
        let _ = libc::fcntl(fd, libc::F_SETFL, new);
    }
}

/// Draw a small inverted crosshair at `(px, py)` into a tight RGBA buffer.
/// Inverting (255 - channel) keeps it visible on any background without
/// obscuring content — it just flips a thin column + row of pixels. Radius is
/// ~10px so it survives the ~16× downscale to terminal cells (≈1 cell). The
/// center is inverted once (the vertical arm draws it; the horizontal arm skips
/// d=0 so it isn't double-flipped back to the original color).
fn draw_cursor(buf: &mut [u8], w: usize, h: usize, px: i32, py: i32) {
    const R: i32 = 10;
    let invert = |buf: &mut [u8], x: i32, y: i32| {
        if (0..w as i32).contains(&x) && (0..h as i32).contains(&y) {
            let i = (y as usize * w + x as usize) * 4;
            buf[i] = 255 - buf[i];
            buf[i + 1] = 255 - buf[i + 1];
            buf[i + 2] = 255 - buf[i + 2];
        }
    };
    invert(buf, px, py); // center (once)
    for d in 1..=R {
        invert(buf, px, py + d); // vertical arm
        invert(buf, px, py - d);
        invert(buf, px + d, py); // horizontal arm
        invert(buf, px - d, py);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_crosshair_inverts_a_thin_plus_and_clips_at_edges() {
        let (w, h) = (32usize, 32usize);
        let bg = [10, 20, 30, 255];
        let mut buf = vec![0u8; w * h * 4];
        for px in buf.chunks_exact_mut(4) {
            px.copy_from_slice(&bg);
        }
        draw_cursor(&mut buf, w, h, 16, 16);
        let pixel = |x: usize, y: usize| -> [u8; 4] {
            let i = (y * w + x) * 4;
            [buf[i], buf[i + 1], buf[i + 2], buf[i + 3]]
        };
        let inverted = [245, 235, 225, 255]; // 255 - bg
        assert_eq!(pixel(16, 16), inverted, "center inverted once");
        assert_eq!(pixel(16, 6), inverted, "vertical arm");
        assert_eq!(pixel(26, 16), inverted, "horizontal arm");
        assert_eq!(pixel(17, 17), bg, "off-arm pixel untouched");
        // Edge/clip safety: must not panic when the crosshair runs off-buffer.
        draw_cursor(&mut buf, w, h, 0, 0);
        draw_cursor(&mut buf, w, h, 31, 31);
        draw_cursor(&mut buf, w, h, -5, -5);
        draw_cursor(&mut buf, w, h, 100, 100);
    }
}

// ────────────────────────── crossterm → cage input ──────────────────────────
//
// Translate terminal key/mouse events into the virtual-keyboard /
// virtual-pointer requests cage receives. Ctrl-Alt-q is the escape hatch (it
// can't go to the app — terminals don't forward it cleanly anyway).

fn pump_terminal_input(state: &mut State, started_at: Instant) -> Result<()> {
    while event::poll(Duration::ZERO).context("poll terminal input")? {
        match event::read().context("read terminal input")? {
            Event::Key(key) if is_escape_chord(&key) => {
                bail!("zuko app interrupted by Ctrl-Alt-q");
            }
            Event::Key(key) => handle_key(state, key, started_at),
            Event::Mouse(mouse) => handle_mouse(state, mouse, started_at),
            _ => {}
        }
    }
    Ok(())
}

fn is_escape_chord(key: &KeyEvent) -> bool {
    matches!(key.kind, KeyEventKind::Press)
        && matches!(key.code, KeyCode::Char('q') | KeyCode::Char('Q'))
        && key.modifiers.contains(KeyModifiers::CONTROL)
        && key.modifiers.contains(KeyModifiers::ALT)
}

fn handle_key(state: &mut State, key: KeyEvent, started_at: Instant) {
    let Some(kb) = state.vkeyboard.as_ref() else {
        return;
    };
    let Some(code) = xkb_keycode_for(key.code) else {
        return;
    };
    let pressed = matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat);
    let time = started_at.elapsed().as_millis() as u32;

    // Press the active modifiers first (and release them after), so the app
    // sees e.g. Shift+a as 'A'. Compositor repeat is disabled; the terminal's
    // own key-repeat arrives as additional Press events.
    if pressed {
        for m in modifier_keycodes(key.modifiers) {
            kb.key(time, m, 1);
        }
    }
    kb.key(time, code, u32::from(pressed));
    if matches!(key.kind, KeyEventKind::Release | KeyEventKind::Press) {
        for m in modifier_keycodes(key.modifiers).into_iter().rev() {
            kb.key(time, m, 0);
        }
    }
}

fn handle_mouse(state: &mut State, mouse: MouseEvent, started_at: Instant) {
    let Some(ptr) = state.vpointer.as_ref() else {
        return;
    };
    let time = started_at.elapsed().as_millis() as u32;
    let (ow, oh) = (
        u32::try_from(DEFAULT_OUTPUT.0).unwrap_or(1),
        u32::try_from(DEFAULT_OUTPUT.1).unwrap_or(1),
    );
    // Map the click into the letterboxed image rectangle (off_*, span_*),
    // preserving the click's units: pixels when the cell size is known (mode
    // 1016 → sub-cell accuracy), else cells (mode 1006). Clicks in the
    // letterbox bars clamp to the image edge.
    let (cols, rows) = term_cell_size().unwrap_or((mouse.column.max(1), mouse.row.max(1)));
    let (span_cols, span_rows, off_col, off_row) =
        compute_placement(u32::from(cols), u32::from(rows), state.cell_px, (ow, oh));
    let (x, y, ex, ey) =
        if let Some((cw, ch)) = state.cell_px.map(|(w, h)| (u32::from(w), u32::from(h))) {
            let (img_x0, img_w) = (off_col * cw, span_cols * cw);
            let (img_y0, img_h) = (off_row * ch, span_rows * ch);
            let x = u32::from(mouse.column)
                .saturating_sub(img_x0)
                .min(img_w.saturating_sub(1));
            let y = u32::from(mouse.row)
                .saturating_sub(img_y0)
                .min(img_h.saturating_sub(1));
            (x, y, img_w.max(1), img_h.max(1))
        } else {
            let x = u32::from(mouse.column)
                .saturating_sub(off_col)
                .min(span_cols.saturating_sub(1));
            let y = u32::from(mouse.row)
                .saturating_sub(off_row)
                .min(span_rows.saturating_sub(1));
            (x, y, span_cols.max(1), span_rows.max(1))
        };
    ptr.motion_absolute(time, x, y, ex, ey);
    if state.cursor {
        state.pointer = Some((x * ow / ex.max(1), y * oh / ey.max(1)));
    }
    if let MouseEventKind::Down(btn) | MouseEventKind::Up(btn) = mouse.kind
        && let Some(btn) = linux_button_code(effective_button(btn, mouse.modifiers))
    {
        let pressed = matches!(mouse.kind, MouseEventKind::Down(_));
        let button_state = if pressed {
            wl_pointer::ButtonState::Pressed
        } else {
            wl_pointer::ButtonState::Released
        };
        ptr.button(time, btn, button_state);
    }
    ptr.frame();
}

/// Map a crossterm click to the button we send to the compositor.
///
/// Most terminals intercept plain right-click (their own context menu) and
/// Shift+click (text selection), so the hosted app never receives a
/// right-button press. Hold **Alt** while left-clicking: terminals forward
/// Alt+click with the modifier flag intact, and we turn it into a right-button
/// event.
fn effective_button(button: MouseButton, mods: KeyModifiers) -> MouseButton {
    match (button, mods.contains(KeyModifiers::ALT)) {
        (MouseButton::Left, true) => MouseButton::Right,
        (_, _) => button,
    }
}

fn linux_button_code(button: MouseButton) -> Option<u32> {
    match button {
        MouseButton::Left => Some(0x110),
        MouseButton::Right => Some(0x111),
        MouseButton::Middle => Some(0x112),
    }
}

fn modifier_keycodes(mods: KeyModifiers) -> Vec<u32> {
    let mut keys = Vec::new();
    if mods.contains(KeyModifiers::CONTROL) {
        keys.push(37); // left ctrl
    }
    if mods.contains(KeyModifiers::SHIFT) {
        keys.push(50); // left shift
    }
    if mods.contains(KeyModifiers::ALT) {
        keys.push(64); // left alt
    }
    keys
}

fn xkb_keycode_for(code: KeyCode) -> Option<u32> {
    Some(match code {
        KeyCode::Backspace => 22,
        KeyCode::Enter => 36,
        KeyCode::Left => 113,
        KeyCode::Right => 114,
        KeyCode::Up => 111,
        KeyCode::Down => 116,
        KeyCode::Home => 110,
        KeyCode::End => 115,
        KeyCode::PageUp => 112,
        KeyCode::PageDown => 117,
        KeyCode::Tab | KeyCode::BackTab => 23,
        KeyCode::Delete => 119,
        KeyCode::Insert => 118,
        KeyCode::Esc => 9,
        KeyCode::F(n @ 1..=10) => 66 + u32::from(n),
        KeyCode::F(11) => 95,
        KeyCode::F(12) => 96,
        KeyCode::Char(' ') => 65,
        KeyCode::Char(c) => char_xkb_keycode(c)?,
        _ => return None,
    })
}

fn char_xkb_keycode(c: char) -> Option<u32> {
    Some(match c.to_ascii_lowercase() {
        '1' => 10,
        '2' => 11,
        '3' => 12,
        '4' => 13,
        '5' => 14,
        '6' => 15,
        '7' => 16,
        '8' => 17,
        '9' => 18,
        '0' => 19,
        '-' => 20,
        '=' => 21,
        'q' => 24,
        'w' => 25,
        'e' => 26,
        'r' => 27,
        't' => 28,
        'y' => 29,
        'u' => 30,
        'i' => 31,
        'o' => 32,
        'p' => 33,
        '[' => 34,
        ']' => 35,
        'a' => 38,
        's' => 39,
        'd' => 40,
        'f' => 41,
        'g' => 42,
        'h' => 43,
        'j' => 44,
        'k' => 45,
        'l' => 46,
        ';' => 47,
        '\'' => 48,
        '`' => 49,
        '\\' => 51,
        'z' => 52,
        'x' => 53,
        'c' => 54,
        'v' => 55,
        'b' => 56,
        'n' => 57,
        'm' => 58,
        ',' => 59,
        '.' => 60,
        '/' => 61,
        _ => return None,
    })
}

// ────────────────────────── virtual device setup ────────────────────────────

/// Create the virtual keyboard + pointer on cage's seat and upload the keymap.
/// Best-effort: any missing global just means that input device is absent.
fn setup_input(state: &mut State, qh: &QueueHandle<State>) {
    if let (Some(mgr), Some(seat)) = (state.vk_manager.as_ref(), state.seat.as_ref()) {
        let kb = mgr.create_virtual_keyboard(seat, qh, ());
        if let Ok(fd) = memfd_with(KEYMAP_US.as_bytes()) {
            // virtual_keyboard keymap: format=1 (XKB_KEYMAP_FORMAT_TEXT_V1).
            kb.keymap(1, fd.as_fd(), KEYMAP_US.len() as u32);
            state._keymap_fd = Some(fd);
        }
        state.vkeyboard = Some(kb);
    }
    if let Some(mgr) = state.vp_manager.as_ref() {
        state.vpointer = Some(mgr.create_virtual_pointer(state.seat.as_ref(), qh, ()));
    }
}

/// Create a memfd, zero-padded to `bytes.len()`, with `bytes` written at the
/// start. Used for the virtual-keyboard keymap (and could back the screencopy
/// SHM buffer too).
fn memfd_with(bytes: &[u8]) -> Result<OwnedFd> {
    let fd = memfd_create(c"zuko", MemfdFlags::empty()).context("memfd_create")?;
    rustix::fs::ftruncate(fd.as_fd(), bytes.len() as u64).context("ftruncate")?;
    let mut mmap = unsafe { MmapMut::map_mut(&fd) }.context("mmap memfd")?;
    mmap[..bytes.len()].copy_from_slice(bytes);
    mmap.flush().context("flush keymap memfd")?;
    Ok(fd)
}

// ─────────────────────────── cage subprocess management ─────────────────────

fn cage_bin() -> String {
    if let Ok(p) = env::var("ZUKO_CAGE") {
        return p;
    }
    // Bundled location: $XDG_DATA_HOME/zuko/cage/cage (where the release lays
    // down cage + its libs, and where `mise use` delivers them).
    if let Some(prefix) = bundled_cage_prefix() {
        return prefix.join("cage").to_string_lossy().into_owned();
    }
    // Fall back to a cage on PATH (e.g. distro-packaged).
    "cage".to_string()
}

/// The bundled cage install dir, if present. Holds `cage` + the wlroots
/// `.so`s it links (libwlroots, libliftoff, libseat, libxcb-errors).
/// `LD_LIBRARY_PATH` is pointed here when spawning cage.
///
/// Lookup order:
/// 1. A `cage/` dir next to this binary — how the release lays it down and how
///    mise extracts the tarball (`install_dir/zuko` + `install_dir/cage`).
/// 2. `$XDG_DATA_HOME/zuko/cage` (or `~/.local/share/zuko/cage`) — the manual
///    install / local-dev layout.
fn bundled_cage_prefix() -> Option<PathBuf> {
    if let Ok(exe) = env::current_exe()
        && let Some(parent) = exe.parent()
    {
        let dir = parent.join("cage");
        if dir.join("cage").exists() {
            return Some(dir);
        }
    }
    let dir = if let Some(x) = env::var_os("XDG_DATA_HOME") {
        PathBuf::from(x)
    } else {
        let home = env::var_os("HOME")?;
        PathBuf::from(home).join(".local").join("share")
    }
    .join("zuko")
    .join("cage");
    dir.join("cage").exists().then_some(dir)
}

fn make_xdg_runtime_dir() -> Result<PathBuf> {
    // Use the REAL XDG_RUNTIME_DIR when there is one, so cage's children —
    // especially Flatpaks — can reach the user's session: D-Bus, the portal,
    // and the per-instance `.flatpak/<id>/bwrapinfo.json` all live there. (A
    // private dir breaks Flatpaks: `flatpak run` writes its instance info into
    // the inherited dir, but the sandboxed app looks it up in the real session
    // dir → "Failed to open bwrapinfo.json" + cascading portal errors.)
    // cage auto-names its Wayland socket, so sharing the dir is fine — we
    // discover the name rather than assuming `wayland-0`. A private fallback
    // only when there's no session dir at all (truly headless; no session to
    // reach anyway).
    if let Some(dir) = env::var_os("XDG_RUNTIME_DIR")
        && PathBuf::from(&dir).is_dir()
    {
        return Ok(PathBuf::from(dir));
    }
    let dir = std::env::temp_dir().join(format!("zuko-app-{}", std::process::id()));
    fs::create_dir_all(&dir)
        .with_context(|| format!("create XDG_RUNTIME_DIR {}", dir.display()))?;
    eprintln!(
        "zuko app: no XDG_RUNTIME_DIR session dir; using private {} \
         (Flatpaks won't reach a session here)",
        dir.display()
    );
    Ok(dir)
}

/// List `wayland-*` socket names in a dir (excluding `*.lock`). Used to spot
/// the new socket cage creates via `wl_display_add_socket_auto` (it picks the
/// first free `wayland-N` and sets `WAYLAND_DISPLAY` for its children — we
/// can't predict N, so we diff the directory).
fn snapshot_wayland_sockets(dir: &Path) -> Vec<String> {
    fs::read_dir(dir)
        .map(|rd| {
            rd.filter_map(|e| e.ok())
                .filter_map(|e| e.file_name().into_string().ok())
                .filter(|n| n.starts_with("wayland-") && !n.contains('.'))
                .collect()
        })
        .unwrap_or_default()
}

/// Wait for cage to create a NEW `wayland-*` socket (one not in `before`),
/// returning its name; or fail fast if cage dies first (missing lib, etc.).
fn wait_for_socket(cage: &mut Child, dir: &Path, before: &[String]) -> Result<String> {
    let deadline = Instant::now() + SOCKET_WAIT;
    while Instant::now() < deadline {
        if let Some(name) = snapshot_wayland_sockets(dir)
            .into_iter()
            .find(|n| !before.contains(n))
        {
            return Ok(name);
        }
        if let Ok(Some(status)) = cage.try_wait() {
            bail!(
                "cage exited before binding its Wayland socket (status: {status}).\n\
                 Usually that means a missing runtime library — cage's error message above names\n\
                 which one. `zuko app` needs cage's deps (libwayland, libxkbcommon, libdrm,\n\
                 libxcb, libinput, libudev, …), present on GUI-capable hosts. The rest of zuko\n\
                 (host/connect) is unaffected — only `zuko app` needs them."
            );
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    bail!(
        "cage did not create a Wayland socket in {} within {SOCKET_WAIT:?}",
        dir.display()
    );
}

fn spawn_cage(
    args: &AppArgs,
    launch: &Launch,
    xdg_runtime: &Path,
    portal_bus: Option<&str>,
) -> Result<Child> {
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new(cage_bin());
    cmd.env("WLR_BACKENDS", "headless")
        .env("WLR_RENDERER", "pixman")
        .env("WLR_HEADLESS_OUTPUTS", "1")
        .env("XDG_RUNTIME_DIR", xdg_runtime);
    // If the in-cage portal is enabled, route the app's portal calls (save/open
    // dialogs) to the cage-side portal via a private D-Bus session — so dialogs
    // render into cage (captured → TUI) instead of the host desktop.
    if let Some(bus) = portal_bus {
        cmd.env("DBUS_SESSION_BUS_ADDRESS", bus);
    }
    // Bundled-lib path: prefer the release layout (next to the bundled cage
    // binary); allow an explicit override for dev/testing. Harmless if empty.
    let lib_dir = bundled_cage_prefix().map(|p| p.to_string_lossy().into_owned());
    let lib_dir = lib_dir.or_else(|| env::var("ZUKO_CAGE_LIB_DIR").ok());
    if let Some(dir) = lib_dir.filter(|d| !d.is_empty()) {
        cmd.env("LD_LIBRARY_PATH", dir);
    }
    // App-tuning env inherited by cage's child (the GUI app).
    for (k, v) in &launch.env {
        cmd.env(k, v);
    }
    // Ask the kernel to SIGTERM cage if zuko (its parent) dies — including a
    // hard SIGKILL of zuko (which can't run cleanup). Without this, closing the
    // terminal wedges zuko and leaves cage + the app running as orphans, which
    // hold the Wayland socket + `.lock` and show up as a "wayland lock" issue /
    // leftover socket on the next run. cage handles SIGTERM (wlroots teardown),
    // which also reaps its app child.
    // SAFETY: pre_exec runs in the forked child before exec; prctl is a
    // signal-safe syscall. PR_SET_PDEATHSIG is Linux-only (this code is too).
    unsafe {
        cmd.pre_exec(|| {
            let _ = libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
            Ok(())
        });
    }
    // cage <flags> -- <application> [args...]
    cmd.arg("--").arg(&launch.program).args(&launch.args);
    if args.debug_child {
        cmd.stdout(Stdio::inherit()).stderr(Stdio::inherit());
    } else {
        cmd.stdout(Stdio::null()).stderr(Stdio::inherit()); // keep cage logs on stderr
    }
    cmd.spawn()
        .with_context(|| format!("spawn cage ({})", cage_bin()))
}

// ──────────────────────────── Wayland client state ──────────────────────────
//
// Mirrors the proven spike: bind wl_shm + wl_output + screencopy manager once;
// per capture, create a frame + SHM buffer, copy, wait for Ready. cage's
// headless output is 1280×720 XRGB8888 (stride == width*4), so the tight RGBA
// conversion below is the only transform needed.

#[derive(Default)]
struct State {
    shm: Option<wl_shm::WlShm>,
    output: Option<wl_output::WlOutput>,
    manager: Option<ZwlrScreencopyManagerV1>,
    frame: Option<ZwlrScreencopyFrameV1>,
    dims: Option<(u32, u32, u32)>, // w, h, stride
    _pool: Option<wl_shm_pool::WlShmPool>,
    _buffer: Option<wl_buffer::WlBuffer>,
    mmap: Option<Arc<Mutex<MmapMut>>>,
    captured: Option<(usize, usize, Vec<u8>)>, // w, h, tight RGBA
    done: Option<Result<(), String>>,
    // Input devices + a keymap memfd kept alive for the session.
    seat: Option<wl_seat::WlSeat>,
    vk_manager: Option<ZwpVirtualKeyboardManagerV1>,
    vp_manager: Option<ZwlrVirtualPointerManagerV1>,
    vkeyboard: Option<ZwpVirtualKeyboardV1>,
    vpointer: Option<ZwlrVirtualPointerV1>,
    _keymap_fd: Option<OwnedFd>,
    // Pointer overlay: draw an inverted crosshair at the last pointer position
    // so touch/imprecise clicks can be aimed. `pointer` is in output pixels.
    cursor: bool,
    pointer: Option<(u32, u32)>,
    // Probed terminal per-cell pixel size (CSI 16 t), used to compute terminal
    // pixel dims for SGR-pixel mouse (sub-cell click/cursor accuracy).
    cell_px: Option<(u16, u16)>,
    // Last emitted frame (RGBA). When the next capture is byte-identical we
    // skip encode/emit — the cheap "diff" that avoids resending static screens
    // (idle menus, text) at 16 fps.
    prev_frame: Option<Vec<u8>>,
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut State,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<wl_shm::WlShm, ()> for State {
    fn event(
        _: &mut State,
        _: &wl_shm::WlShm,
        _: wl_shm::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<wl_shm_pool::WlShmPool, ()> for State {
    fn event(
        _: &mut State,
        _: &wl_shm_pool::WlShmPool,
        _: wl_shm_pool::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<wl_buffer::WlBuffer, ()> for State {
    fn event(
        _: &mut State,
        _: &wl_buffer::WlBuffer,
        _: wl_buffer::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<wl_output::WlOutput, ()> for State {
    fn event(
        _: &mut State,
        _: &wl_output::WlOutput,
        _: wl_output::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwlrScreencopyManagerV1, ()> for State {
    fn event(
        _: &mut State,
        _: &ZwlrScreencopyManagerV1,
        _: zwlr_screencopy_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<wl_seat::WlSeat, ()> for State {
    fn event(
        _: &mut State,
        _: &wl_seat::WlSeat,
        _: wl_seat::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwpVirtualKeyboardManagerV1, ()> for State {
    fn event(
        _: &mut State,
        _: &ZwpVirtualKeyboardManagerV1,
        _: zwp_virtual_keyboard_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwpVirtualKeyboardV1, ()> for State {
    fn event(
        _: &mut State,
        _: &ZwpVirtualKeyboardV1,
        _: zwp_virtual_keyboard_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwlrVirtualPointerManagerV1, ()> for State {
    fn event(
        _: &mut State,
        _: &ZwlrVirtualPointerManagerV1,
        _: zwlr_virtual_pointer_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwlrVirtualPointerV1, ()> for State {
    fn event(
        _: &mut State,
        _: &ZwlrVirtualPointerV1,
        _: zwlr_virtual_pointer_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwlrScreencopyFrameV1, ()> for State {
    fn event(
        state: &mut State,
        frame: &ZwlrScreencopyFrameV1,
        event: zwlr_screencopy_frame_v1::Event,
        _: &(),
        _: &Connection,
        qh: &QueueHandle<Self>,
    ) {
        use zwlr_screencopy_frame_v1::Event::*;
        match event {
            Buffer {
                width,
                height,
                stride,
                ..
            } => {
                state.dims = Some((width, height, stride));
            }
            LinuxDmabuf { .. } => {}
            BufferDone => {
                let (w, h, stride) = match state.dims {
                    Some(d) => d,
                    None => {
                        state.done = Some(Err("BufferDone without Buffer".into()));
                        return;
                    }
                };
                let size = (stride as usize) * (h as usize);
                let fd = match memfd_create(c"zuko-screencopy", MemfdFlags::empty()) {
                    Ok(fd) => fd,
                    Err(e) => {
                        state.done = Some(Err(format!("memfd: {e}")));
                        return;
                    }
                };
                if let Err(e) = rustix::fs::ftruncate(fd.as_fd(), size as u64) {
                    state.done = Some(Err(format!("ftruncate: {e}")));
                    return;
                }
                let mmap = match unsafe { MmapMut::map_mut(&fd) } {
                    Ok(m) => Arc::new(Mutex::new(m)),
                    Err(e) => {
                        state.done = Some(Err(format!("mmap: {e}")));
                        return;
                    }
                };
                let shm = match state.shm.as_ref() {
                    Some(s) => s,
                    None => {
                        state.done = Some(Err("no wl_shm".into()));
                        return;
                    }
                };
                let pool = shm.create_pool(fd.as_fd(), size as i32, qh, ());
                let buffer = pool.create_buffer(
                    0,
                    w as i32,
                    h as i32,
                    stride as i32,
                    wl_shm::Format::Xrgb8888,
                    qh,
                    (),
                );
                frame.copy(&buffer);
                state._pool = Some(pool);
                state._buffer = Some(buffer);
                state.mmap = Some(mmap);
            }
            Ready { .. } => {
                if let Some((w, h, stride)) = state.dims
                    && let Some(mmap_arc) = state.mmap.take()
                {
                    let guard = mmap_arc.lock().unwrap();
                    let mut out = Vec::with_capacity(w as usize * h as usize * 4);
                    for y in 0..h as usize {
                        let row = &guard[y * stride as usize..y * stride as usize + w as usize * 4];
                        for px in row.chunks_exact(4) {
                            // XRGB8888 little-endian -> bytes B,G,R,X. Emit R,G,B,255.
                            out.push(px[2]);
                            out.push(px[1]);
                            out.push(px[0]);
                            out.push(255);
                        }
                        let _ = &mut out; // keep borrow tidy
                    }
                    let _ = &guard;
                    if state.cursor
                        && let Some((px, py)) = state.pointer
                    {
                        draw_cursor(&mut out, w as usize, h as usize, px as i32, py as i32);
                    }
                    state.captured = Some((w as usize, h as usize, out));
                }
                state.done = Some(Ok(()));
            }
            Failed => state.done = Some(Err("server reported screencopy Failed".into())),
            Flags { .. } => {}
            _ => {}
        }
    }
}
