//! Linux-only implementation of `zuko app` (the cage + wlr-screencopy backend).
//!
//! See [`super`] for the cross-platform shell + reusable helpers. This module
//! pulls in the Wayland client stack only on Linux builds.

use std::io::Write;
use std::os::fd::{AsFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
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
use wayland_protocols_wlr::output_management::v1::client::{
    zwlr_output_configuration_head_v1::{self, ZwlrOutputConfigurationHeadV1},
    zwlr_output_configuration_v1::{self, ZwlrOutputConfigurationV1},
    zwlr_output_head_v1::{self, ZwlrOutputHeadV1},
    zwlr_output_manager_v1::{self, ZwlrOutputManagerV1},
    zwlr_output_mode_v1::{self, ZwlrOutputModeV1},
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
    DEFAULT_OUTPUT, KittyFramePayload, KittyGraphicsFormat, Launch, TerminalModeGuard,
    encode_rgba_png, encode_rgba_rgb, encode_test_pattern_payload, kitty_clear_screen,
    kitty_emit_frame, print_discovered_apps, print_launch, resolve_launch, validate_args,
};
use crate::{AppArgs, KittyGraphicsCodec};

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

/// Left-click held this long (without moving) → right-click on release.
/// Fallback for terminals that intercept right-click for their own menu.
const LONG_PRESS_MS: u128 = 400;
/// Max pointer drift (image-space units) during a press to still count as a
/// "static" hold eligible for long-press → right-click.
const LONG_PRESS_MOVE: i64 = 6;
/// How long a terminal key tap stays pressed in the virtual Wayland keyboard.
/// Must be long enough to avoid wlroots/client coalescing same-timestamp
/// down+up, but short enough to stay below compositor/app key-repeat delays.
const KEY_TAP: Duration = Duration::from_millis(25);
/// Hard cap for adaptive cage output sizing. Higher resolutions explode PNG
/// encode time and PTY bandwidth with little benefit inside a terminal.
const MAX_OUTPUT_DIM: u32 = 4096;
const MIN_OUTPUT_DIM: u32 = 160;
const IDLE_FRAME_INTERVAL: Duration = Duration::from_millis(250);
const FRAME_COST_MULTIPLIER: f64 = 1.25;
const FRAME_PROFILE_SAMPLES: usize = 4096;
const VIDEO_CHANGE_RATIO: f64 = 0.35;
const HIGH_ENTROPY_DELTA: f64 = 48.0;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct OutputSize {
    width: u32,
    height: u32,
}

impl OutputSize {
    const DEFAULT: Self = Self {
        width: DEFAULT_OUTPUT.0 as u32,
        height: DEFAULT_OUTPUT.1 as u32,
    };
}

impl Default for OutputSize {
    fn default() -> Self {
        Self::DEFAULT
    }
}

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
        let payload = encode_test_pattern_payload(w as usize, h as usize, args.graphics_codec)?;
        let placement = term_cell_size().map(|(c, r)| {
            compute_placement(u32::from(c), u32::from(r), None, (w as u32, h as u32))
        });
        kitty_emit_frame(
            w as u32,
            h as u32,
            payload.format,
            &payload.bytes,
            true,
            placement,
        )?;
        eprintln!("zuko app: Kitty test pattern rendered at {w}x{h}; press Enter to exit");
        let mut buf = String::new();
        let _ = std::io::stdin().read_line(&mut buf);
        return Ok(());
    }

    if args.doctor {
        return doctor(&args);
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

    run_launch(&args, launch)
}

fn run_launch(args: &AppArgs, mut launch: Launch) -> Result<()> {
    let mut terminal = TerminalModeGuard::enter().context("enter terminal app mode")?;

    // Probe the terminal's pixel geometry ONCE for the whole process so we can
    // switch mouse reporting to SGR-pixel (1016) — pixel-accurate clicks/cursor
    // instead of ~1-cell quantization. Best-effort: if the terminal won't tell
    // us (or a slow relay beats the probe), keep cell coords and the cursor just
    // snaps to cells. Probing again after a fallback relaunch would race the
    // long-lived input thread for stdin and corrupt the reply, so do it here.
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

    // Spawn the terminal input reader ONCE. crossterm's event::read() blocks on
    // stdin and can't be interrupted, so a second reader (from a per-profile
    // relaunch) would split stdin bytes with the first and desync the pointer.
    let input_rx = spawn_terminal_input_thread();

    // Walk the display-profile fallback chain, recreating only the cage/Wayland
    // session per profile. Fall back ONLY on a real startup failure (early
    // crash or stuck-blank) or a hard error; a clean quit or an app that
    // rendered then exited is `Done` and never retried — that was the old
    // retry-on-any-error bug (it relaunched on every normal exit).
    loop {
        let fallback = launch.fallback.take();
        let result = run_session(args, &launch, cell_px, &input_rx, fallback.is_some());
        match result {
            Ok(SessionEnd::Done) => return Ok(()),
            Ok(SessionEnd::StartupFailed(reason)) => match fallback {
                Some(next) => {
                    eprintln!(
                        "\nzuko app: {} on {} did not render ({reason}); retrying with {}…",
                        launch.label,
                        launch.profile.label(),
                        next.profile.label()
                    );
                    launch = *next;
                }
                None => {
                    eprintln!("\nzuko app: {} did not render ({reason})", launch.label);
                    return Ok(());
                }
            },
            Err(e) => match fallback {
                Some(next) => {
                    eprintln!(
                        "\nzuko app: {} on {} failed; retrying with {}…\n  {e:#}",
                        launch.label,
                        launch.profile.label(),
                        next.profile.label()
                    );
                    launch = *next;
                }
                None => {
                    eprintln!("\nzuko app error: {e:#}");
                    return Err(e);
                }
            },
        }
    }
}

/// Run one display profile end to end: spawn cage, connect to its Wayland
/// socket, stream frames, then tear cage back down. The terminal guard, pixel
/// probe, and input thread are owned by the caller and shared across profiles
/// so a fallback relaunch never re-probes stdin or double-reads input.
fn run_session(
    args: &AppArgs,
    launch: &Launch,
    cell_px: Option<(u16, u16)>,
    input_rx: &mpsc::Receiver<TerminalInput>,
    allow_fallback: bool,
) -> Result<SessionEnd> {
    let desired_output = desired_output_size(args.scale, cell_px);

    // cage runs in the real XDG_RUNTIME_DIR (so Flatpak children reach the
    // session); it auto-names its socket, so snapshot first and discover the
    // new name after spawn rather than assuming wayland-0.
    let xdg_runtime = make_xdg_runtime_dir()?;
    let sockets_before = snapshot_wayland_sockets(&xdg_runtime);

    if launch.flatpak {
        eprintln!(
            "zuko app: Flatpak portals use the host desktop session and may not appear in the TUI; \
             run an RDP client with `zuko app remmina` or `zuko app krdc` for full desktop sessions."
        );
    }

    let mut cage = spawn_cage(args, launch, &xdg_runtime)?;
    let socket = wait_for_socket(&mut cage, &xdg_runtime, &sockets_before)?;

    eprintln!(
        "zuko app: cage running {} targeting {}x{} (pixman/headless) on {}; connecting…",
        launch.label, desired_output.width, desired_output.height, socket
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
        output_manager: globals.bind(&qh, 1..=4, ()).ok(),
        output_size: desired_output,
        target_output_size: desired_output,
        output_scale: args.scale,
        graphics_codec: args.graphics_codec,
        cursor: !args.no_cursor,
        cell_px,
        ..Default::default()
    };

    configure_output_size(&mut state, &conn, &mut queue, desired_output);

    // Create the virtual keyboard + pointer up front (best-effort; non-fatal).
    setup_input(&mut state, &qh);
    let _ = conn.flush();

    let frame_interval = Duration::from_millis((1000 / u64::from(args.fps)).max(1));
    let next_frame = Instant::now();
    let started_at = Instant::now();

    kitty_clear_screen().ok();
    let mut loop_timing = LoopTiming {
        max_frame_interval: frame_interval,
        current_frame_interval: frame_interval,
        next_frame,
        started_at,
        unchanged_frames: 0,
        max_mbps: args.max_mbps,
    };

    let result = run_loop(
        &mut state,
        &conn,
        &mut queue,
        &mut cage,
        input_rx,
        &mut loop_timing,
        allow_fallback,
    );

    // Best-effort cleanup. SIGTERM cage first (don't SIGKILL) so it runs its
    // wlroots teardown and reaps the app child; SIGKILL only as a fallback.
    // cage doesn't reliably unlink its Wayland socket on SIGTERM, so we remove
    // the socket + `.lock` ourselves after it exits (otherwise they accumulate
    // in the shared XDG_RUNTIME_DIR — the "wayland lock" leftover). The terminal
    // guard stays owned by run_launch (shared across profiles) and restores the
    // terminal + clears Kitty when the whole process unwinds.
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

fn doctor(args: &AppArgs) -> Result<()> {
    println!("zuko app doctor");
    let mut fatal = false;

    doctor_check(
        "terminal cell size",
        term_cell_size().is_some(),
        "TIOCGWINSZ reports cells",
    );
    let pixels = term_pixel_dims(None);
    doctor_check(
        "terminal pixel size",
        pixels.is_some(),
        "TIOCGWINSZ reports pixels (otherwise zuko app falls back to defaults/cell mapping)",
    );
    let desired = desired_output_size(args.scale, None);
    println!(
        "  target output: {}x{} (--scale {})",
        desired.width, desired.height, args.scale
    );

    let cage = cage_path();
    doctor_check(
        "cage binary",
        cage.is_some(),
        "bundled cage, $ZUKO_CAGE, or PATH",
    );
    if cage.is_none() {
        fatal = true;
    }
    match doctor_cage_smoke(args, desired) {
        Ok(()) => doctor_check(
            "live cage smoke",
            true,
            "screencopy + virtual input + output management",
        ),
        Err(e) => {
            doctor_check("live cage smoke", false, &format!("{e:#}"));
            fatal = true;
        }
    }

    if fatal {
        bail!("zuko app doctor found missing required capabilities")
    }
    Ok(())
}

fn doctor_check(name: &str, ok: bool, detail: &str) {
    println!(
        "  {:<24} {}  {}",
        name,
        if ok { "ok  " } else { "warn" },
        detail
    );
}

fn doctor_cage_smoke(args: &AppArgs, desired: OutputSize) -> Result<()> {
    let xdg_runtime = make_xdg_runtime_dir()?;
    let sockets_before = snapshot_wayland_sockets(&xdg_runtime);
    let launch = Launch {
        label: "doctor".to_string(),
        program: "sh".to_string(),
        args: vec!["-c".to_string(), "sleep 5".to_string()],
        env: Vec::new(),
        flatpak: false,
        profile: super::DisplayProfile::Wayland,
        fallback: None,
    };
    let mut cage = spawn_cage(args, &launch, &xdg_runtime)?;
    let socket = match wait_for_socket(&mut cage, &xdg_runtime, &sockets_before) {
        Ok(socket) => socket,
        Err(e) => {
            shutdown_cage(&mut cage, &xdg_runtime, "wayland-0");
            return Err(e);
        }
    };

    unsafe {
        env::set_var("XDG_RUNTIME_DIR", &xdg_runtime);
        env::set_var("WAYLAND_DISPLAY", &socket);
    }
    let conn = Connection::connect_to_env().context("connect to cage Wayland socket")?;
    let (globals, mut queue) = registry_queue_init::<State>(&conn)?;
    let qh = queue.handle();
    let mut state = State {
        shm: globals.bind(&qh, 1..=2, ()).ok(),
        output: globals.bind(&qh, 1..=4, ()).ok(),
        manager: globals.bind(&qh, 1..=3, ()).ok(),
        seat: globals.bind(&qh, 5..=9, ()).ok(),
        vk_manager: globals.bind(&qh, 1..=1, ()).ok(),
        vp_manager: globals.bind(&qh, 1..=2, ()).ok(),
        output_manager: globals.bind(&qh, 1..=4, ()).ok(),
        ..Default::default()
    };
    configure_output_size(&mut state, &conn, &mut queue, desired);
    setup_input(&mut state, &qh);
    let _ = conn.flush();

    let required = [
        ("wl_shm", state.shm.is_some()),
        ("wl_output", state.output.is_some()),
        ("wlr-screencopy", state.manager.is_some()),
        ("virtual keyboard", state.vkeyboard.is_some()),
        ("virtual pointer", state.vpointer.is_some()),
        ("output management", state.output_manager.is_some()),
    ];
    for (name, ok) in required {
        doctor_check(name, ok, "advertised by cage");
        if !ok && name != "output management" {
            shutdown_cage(&mut cage, &xdg_runtime, &socket);
            bail!("required Wayland global missing: {name}");
        }
    }

    shutdown_cage(&mut cage, &xdg_runtime, &socket);
    Ok(())
}

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

struct LoopTiming {
    max_frame_interval: Duration,
    current_frame_interval: Duration,
    next_frame: Instant,
    started_at: Instant,
    unchanged_frames: u8,
    max_mbps: f64,
}

#[derive(Clone, Copy, Debug)]
struct FrameOutcome {
    emitted: bool,
    elapsed: Duration,
    bytes: usize,
    /// The captured frame contained real (non-uniform) pixels — i.e. the app
    /// actually drew something, not just cage's blank output. The session
    /// "commits" to its display profile once this is true.
    content: bool,
}

/// How a session loop ended, so the caller can decide whether to fall back to
/// the next display profile.
enum SessionEnd {
    /// The user quit (escape chord) or the app exited after rendering real
    /// content — a normal end. Never fall back.
    Done,
    /// Startup failed on this display profile: cage/app died before rendering,
    /// or only blank frames appeared within the probe window. Try the next
    /// profile if one exists.
    StartupFailed(String),
}

/// How long an app may stay blank after launch before we treat the current
/// display profile as wrong and fall back. Generous enough for slow Electron /
/// browser cold starts, short enough that a wrong backend isn't a long hang.
const STARTUP_PROBE: Duration = Duration::from_secs(8);

fn run_loop(
    state: &mut State,
    conn: &Connection,
    queue: &mut EventQueue<State>,
    cage: &mut Child,
    input_rx: &mpsc::Receiver<TerminalInput>,
    timing: &mut LoopTiming,
    allow_fallback: bool,
) -> Result<SessionEnd> {
    let mut placed = false;
    let mut last_cells: Option<(u16, u16)> = None;
    // Whether the app has drawn real content yet. Until this is true on a
    // fallback-capable launch, an early exit or a stuck-blank window means the
    // chosen display profile is wrong and we should try the next one. Once
    // true, the session is "committed": any later exit is the user's.
    let mut saw_content = false;
    loop {
        if let Some(status) = cage.try_wait().context("poll cage process")? {
            // cage (and its app child) exited. If we already rendered, that's a
            // normal quit. If not — and a fallback exists — the backend likely
            // failed at startup, so report it for a profile switch.
            if saw_content || !allow_fallback {
                return Ok(SessionEnd::Done);
            }
            return Ok(SessionEnd::StartupFailed(format!(
                "cage exited with {status} before the app rendered"
            )));
        }

        if drain_terminal_input(state, input_rx, timing.started_at)? {
            return Ok(SessionEnd::Done);
        }
        release_due_key(state, timing.started_at);
        if sync_output_size_to_terminal(state, conn, queue) || state.terminal_resized {
            placed = false;
            last_cells = None;
            state.prev_frame = None;
            state.terminal_resized = false;
        }

        let now = Instant::now();
        if now >= timing.next_frame {
            match capture_and_emit(state, conn, queue, &mut placed, &mut last_cells) {
                Ok(outcome) => {
                    saw_content |= outcome.content;
                    update_frame_pacing(timing, outcome);
                }
                Err(e) => {
                    // A single frame failing shouldn't kill the session (e.g. the
                    // app is mid-resize); log and continue. A broken connection,
                    // however, surfaces from blocking_dispatch below.
                    eprintln!("zuko app: frame skipped: {e:#}");
                    timing.current_frame_interval = timing.max_frame_interval;
                }
            }
            timing.next_frame = Instant::now() + timing.current_frame_interval;
        }

        // Stuck-blank detection: a fallback-capable launch that has shown only
        // cage's uniform output past the probe window is almost certainly on the
        // wrong backend (the classic Electron/Chromium "black screen under
        // headless pixman"). Switch profiles instead of leaving a black screen.
        if allow_fallback && !saw_content && timing.started_at.elapsed() >= STARTUP_PROBE {
            return Ok(SessionEnd::StartupFailed(format!(
                "app stayed blank for {STARTUP_PROBE:?} (no content rendered)"
            )));
        }

        if drain_terminal_input(state, input_rx, timing.started_at)? {
            return Ok(SessionEnd::Done);
        }
        let _ = conn.flush();

        // Drain any pending Wayland events without blocking (e.g. late
        // screencopy callbacks, output changes). Ignore drain errors while cage
        // is still alive — the capture path reports real ones.
        let _ = queue.dispatch_pending(state);

        std::thread::sleep(Duration::from_millis(8));
    }
}

/// Capture one frame from cage's headless output via wlr-screencopy and emit it
/// to the terminal as a Kitty graphics frame, scaled to fit the terminal's cell grid.
fn capture_and_emit(
    state: &mut State,
    conn: &Connection,
    queue: &mut EventQueue<State>,
    placed: &mut bool,
    last_cells: &mut Option<(u16, u16)>,
) -> Result<FrameOutcome> {
    let started = Instant::now();
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
    state.frame_content = false;

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
    let (w, h) = state
        .captured
        .take()
        .context("capture Ready without frame bytes")?;
    state.output_size = OutputSize {
        width: w as u32,
        height: h as u32,
    };
    // Dirty-frame "diff": if the new RGBA is byte-identical to the last emitted
    // frame AND the placement is already live, skip encode/emit — the terminal
    // is already showing exactly this. Always (re)emit when (re)placing.
    let needs_place = !*placed;
    *placed = true;
    let rgba = state.frame_scratch.as_slice();
    // Computed in the Ready handler from the pre-cursor pixels.
    let content = state.frame_content;
    let changed = state.prev_frame.as_deref() != Some(rgba);
    let emitted = needs_place || changed;
    let mut bytes = 0;
    if emitted {
        // Aspect-preserving (letterboxed) cell rectangle for this terminal.
        let placement = cells.map(|(c, r)| {
            compute_placement(
                u32::from(c),
                u32::from(r),
                state.cell_px,
                (w as u32, h as u32),
            )
        });
        let profile = frame_profile(rgba, w, h, state.prev_frame.as_deref());
        let payload = encode_kitty_payload(rgba, w, h, state.graphics_codec, profile)?;
        bytes = payload.transport_bytes();
        kitty_emit_frame(
            w as u32,
            h as u32,
            payload.format,
            &payload.bytes,
            needs_place,
            placement,
        )?;
        let old = state
            .prev_frame
            .replace(std::mem::take(&mut state.frame_scratch));
        state.frame_scratch = old.unwrap_or_default();
        state.frame_scratch.clear();
    } else {
        state.frame_scratch.clear();
    }
    Ok(FrameOutcome {
        emitted,
        elapsed: started.elapsed(),
        bytes,
        content,
    })
}

/// Whether a captured RGBA frame holds real content rather than cage's uniform
/// blank output. A solid color (the black/grey a misconfigured Electron or
/// Chromium window shows under headless pixman) is uniform; a real UI is not.
/// Sampled (not every pixel) so it stays cheap on large frames.
fn frame_has_content(rgba: &[u8]) -> bool {
    let Some(first) = rgba.get(0..4) else {
        return false;
    };
    rgba.chunks_exact(4).step_by(97).any(|px| px != first)
}

#[derive(Clone, Copy, Debug)]
struct FrameProfile {
    changed_ratio: Option<f64>,
    avg_neighbor_delta: f64,
}

impl FrameProfile {
    fn high_entropy(self) -> bool {
        self.avg_neighbor_delta >= HIGH_ENTROPY_DELTA
    }

    fn video_like(self) -> bool {
        self.high_entropy()
            && self
                .changed_ratio
                .is_none_or(|ratio| ratio >= VIDEO_CHANGE_RATIO)
    }

    fn png_filter(self) -> png::Filter {
        if self.video_like() {
            png::Filter::NoFilter
        } else {
            png::Filter::Paeth
        }
    }
}

fn frame_profile(rgba: &[u8], width: usize, height: usize, prev: Option<&[u8]>) -> FrameProfile {
    let pixels = width.saturating_mul(height);
    if pixels == 0 {
        return FrameProfile {
            changed_ratio: prev.map(|_| 0.0),
            avg_neighbor_delta: 0.0,
        };
    }
    let step = (pixels / FRAME_PROFILE_SAMPLES).max(1);
    let mut samples = 0usize;
    let mut changed = 0usize;
    let mut deltas = 0u64;
    let len = width * height * 4;
    let rgba = &rgba[..rgba.len().min(len)];
    let prev = prev.filter(|prev| prev.len() >= len);

    for pixel in (0..pixels).step_by(step) {
        let idx = pixel * 4;
        if idx + 3 > rgba.len() {
            break;
        }
        samples += 1;
        if let Some(prev) = prev {
            let old = &prev[idx..idx + 4];
            let new = &rgba[idx..idx + 4];
            if old != new {
                changed += 1;
            }
        }
        if pixel % width != 0 {
            let left = idx - 4;
            if left + 2 < rgba.len() {
                deltas += u64::from(rgba[idx].abs_diff(rgba[left]));
                deltas += u64::from(rgba[idx + 1].abs_diff(rgba[left + 1]));
                deltas += u64::from(rgba[idx + 2].abs_diff(rgba[left + 2]));
            }
        }
    }

    FrameProfile {
        changed_ratio: prev.map(|_| changed as f64 / samples.max(1) as f64),
        avg_neighbor_delta: deltas as f64 / samples.max(1) as f64,
    }
}

fn encode_kitty_payload(
    rgba: &[u8],
    width: usize,
    height: usize,
    codec: KittyGraphicsCodec,
    profile: FrameProfile,
) -> Result<KittyFramePayload> {
    match codec {
        KittyGraphicsCodec::Rgb => Ok(KittyFramePayload {
            format: KittyGraphicsFormat::Rgb,
            bytes: encode_rgba_rgb(rgba, width, height)?,
        }),
        KittyGraphicsCodec::Png => Ok(KittyFramePayload {
            format: KittyGraphicsFormat::Png,
            bytes: encode_rgba_png(rgba, width, height, profile.png_filter())?,
        }),
        KittyGraphicsCodec::Auto if profile.video_like() => Ok(KittyFramePayload {
            format: KittyGraphicsFormat::Rgb,
            bytes: encode_rgba_rgb(rgba, width, height)?,
        }),
        KittyGraphicsCodec::Auto => Ok(KittyFramePayload {
            format: KittyGraphicsFormat::Png,
            bytes: encode_rgba_png(rgba, width, height, profile.png_filter())?,
        }),
    }
}

fn update_frame_pacing(timing: &mut LoopTiming, outcome: FrameOutcome) {
    let active_interval = active_frame_interval(
        timing.max_frame_interval,
        outcome.elapsed,
        outcome.bytes,
        timing.max_mbps,
    );
    if outcome.emitted {
        timing.unchanged_frames = 0;
        timing.current_frame_interval = active_interval;
    } else {
        timing.unchanged_frames = timing.unchanged_frames.saturating_add(1);
        timing.current_frame_interval = if timing.unchanged_frames >= 2 {
            IDLE_FRAME_INTERVAL.max(timing.max_frame_interval)
        } else {
            active_interval
        };
    }
}

fn active_frame_interval(
    max_fps_interval: Duration,
    elapsed: Duration,
    bytes: usize,
    max_mbps: f64,
) -> Duration {
    let cost_limited = Duration::from_secs_f64(elapsed.as_secs_f64() * FRAME_COST_MULTIPLIER);
    let bandwidth_limited = if max_mbps > 0.0 && bytes > 0 {
        Duration::from_secs_f64(bytes as f64 * 8.0 / (max_mbps * 1_000_000.0))
    } else {
        Duration::ZERO
    };
    max_fps_interval.max(cost_limited).max(bandwidth_limited)
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

fn desired_output_size(scale: f32, cell_px: Option<(u16, u16)>) -> OutputSize {
    let base =
        term_pixel_dims(cell_px).unwrap_or((OutputSize::DEFAULT.width, OutputSize::DEFAULT.height));
    scaled_output_size_for_terminal(base, scale)
}

fn scaled_output_size_for_terminal(base: (u32, u32), scale: f32) -> OutputSize {
    let scale = f64::from(scale);
    let width = (base.0.max(1) as f64 * scale).round() as u32;
    let height = (base.1.max(1) as f64 * scale).round() as u32;
    OutputSize {
        width: width.clamp(MIN_OUTPUT_DIM, MAX_OUTPUT_DIM),
        height: height.clamp(MIN_OUTPUT_DIM, MAX_OUTPUT_DIM),
    }
}

fn sync_output_size_to_terminal(
    state: &mut State,
    conn: &Connection,
    queue: &mut EventQueue<State>,
) -> bool {
    let desired = desired_output_size(state.output_scale, state.cell_px);
    if desired == state.target_output_size {
        return false;
    }
    state.target_output_size = desired;
    configure_output_size(state, conn, queue, desired)
}

fn configure_output_size(
    state: &mut State,
    conn: &Connection,
    queue: &mut EventQueue<State>,
    desired: OutputSize,
) -> bool {
    if env::var_os("ZUKO_APP_NO_OUTPUT_CONFIG").is_some() {
        return false;
    }
    if let Err(e) = try_configure_output_size(state, conn, queue, desired) {
        eprintln!(
            "zuko app: couldn't set cage output to {}x{} ({e:#}); continuing with compositor default",
            desired.width, desired.height
        );
        return false;
    }
    true
}

fn try_configure_output_size(
    state: &mut State,
    conn: &Connection,
    queue: &mut EventQueue<State>,
    desired: OutputSize,
) -> Result<()> {
    let manager = state
        .output_manager
        .as_ref()
        .context("zwlr_output_manager_v1 unavailable")?
        .clone();
    conn.flush().ok();

    if let Err(first) = apply_output_config(state, conn, queue, &manager, desired) {
        // A resize can race with wlroots publishing the next output-management
        // serial. Refresh the serial and retry once; this is the common failure
        // mode after the initial launch-time configuration succeeded.
        let stale_serial = state.output_config_serial;
        state.output_config_serial = None;
        let deadline = Instant::now() + Duration::from_millis(500);
        while state.output_config_serial.is_none() && Instant::now() <= deadline {
            let _ = queue.dispatch_pending(state);
            if state.output_config_serial.is_none() {
                std::thread::sleep(Duration::from_millis(8));
            }
        }
        if state.output_config_serial.is_some() && state.output_config_serial != stale_serial {
            apply_output_config(state, conn, queue, &manager, desired).map_err(|second| {
                anyhow::anyhow!("first attempt: {first:#}; retry after serial refresh: {second:#}")
            })
        } else {
            Err(first)
        }
    } else {
        Ok(())
    }
}

fn apply_output_config(
    state: &mut State,
    conn: &Connection,
    queue: &mut EventQueue<State>,
    manager: &ZwlrOutputManagerV1,
    desired: OutputSize,
) -> Result<()> {
    state.output_config_result = None;
    let deadline = Instant::now() + Duration::from_secs(2);
    while state.output_config_serial.is_none() {
        if Instant::now() > deadline {
            bail!("timed out waiting for output-management head list");
        }
        queue.blocking_dispatch(state)?;
    }
    let serial = state
        .output_config_serial
        .context("missing output-management serial")?;
    if state.output_heads.is_empty() {
        bail!("output-management advertised no heads");
    }

    let qh = queue.handle();
    let config = manager.create_configuration(serial, &qh, ());
    let head = state
        .output_heads
        .first()
        .context("output-management advertised no heads")?;
    let head_config = config.enable_head(head, &qh, ());
    head_config.set_custom_mode(desired.width as i32, desired.height as i32, 0);
    head_config.set_position(0, 0);
    config.apply();
    conn.flush().ok();

    let deadline = Instant::now() + Duration::from_secs(2);
    while state.output_config_result.is_none() {
        if Instant::now() > deadline {
            config.destroy();
            bail!("timed out applying output size");
        }
        queue.blocking_dispatch(state)?;
    }
    match state.output_config_result.take() {
        Some(Ok(())) => {
            config.destroy();
            eprintln!(
                "zuko app: cage output set to {}x{} via wlr-output-management",
                desired.width, desired.height
            );
            Ok(())
        }
        Some(Err(e)) => {
            config.destroy();
            bail!(e)
        }
        None => unreachable!("checked above"),
    }
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

    #[test]
    fn cursor_crosshair_would_mask_blank_detection_so_it_must_run_first() {
        let (w, h) = (40usize, 40usize);
        let mut buf = vec![0u8; w * h * 4]; // uniform (blank) frame
        assert!(
            !frame_has_content(&buf),
            "uniform frame is blank before the cursor is drawn"
        );
        // Place the crosshair center on a pixel the blank-detector samples
        // (it steps by 97 pixels, so index 776 = 97*8 -> x=16, y=19). On a real
        // blank app the cursor lands wherever the user points, so detection run
        // AFTER the composite would intermittently flip blank -> "has content"
        // and defeat the startup fallback. The capture path computes content
        // from the pre-cursor pixels instead; this guards that ordering.
        assert_eq!(19 * w + 16, 776, "crosshair center sits on a sampled pixel");
        draw_cursor(&mut buf, w, h, 16, 19);
        assert!(
            frame_has_content(&buf),
            "post-cursor frame reads as content — proves it must not feed blank detection"
        );
    }

    #[test]
    fn printable_key_mapping_uses_raw_evdev_and_infers_shift() {
        assert_eq!(evdev_keycode_for(KeyCode::Char('a')), Some(30));
        assert_eq!(evdev_keycode_for(KeyCode::Char('A')), Some(30));
        assert!(!key_requires_shift(KeyCode::Char('a')));
        assert!(key_requires_shift(KeyCode::Char('A')));

        assert_eq!(evdev_keycode_for(KeyCode::Char('1')), Some(2));
        assert_eq!(evdev_keycode_for(KeyCode::Char('!')), Some(2));
        assert!(!key_requires_shift(KeyCode::Char('1')));
        assert!(key_requires_shift(KeyCode::Char('!')));

        assert_eq!(evdev_keycode_for(KeyCode::Char('/')), Some(53));
        assert_eq!(evdev_keycode_for(KeyCode::Char('?')), Some(53));
        assert!(!key_requires_shift(KeyCode::Char('/')));
        assert!(key_requires_shift(KeyCode::Char('?')));
        assert!(key_requires_shift(KeyCode::BackTab));
    }

    #[test]
    fn terminal_sized_output_scales_and_clamps() {
        assert_eq!(
            scaled_output_size_for_terminal((1000, 500), 1.5),
            OutputSize {
                width: 1500,
                height: 750,
            }
        );
        assert_eq!(
            scaled_output_size_for_terminal((10, 10), 0.5),
            OutputSize {
                width: MIN_OUTPUT_DIM,
                height: MIN_OUTPUT_DIM,
            }
        );
        assert_eq!(
            scaled_output_size_for_terminal((9000, 9000), 1.0),
            OutputSize {
                width: MAX_OUTPUT_DIM,
                height: MAX_OUTPUT_DIM,
            }
        );
    }

    #[test]
    fn frame_pacing_tracks_changes_and_idles_when_static() {
        let max = Duration::from_millis(33);
        assert_eq!(
            active_frame_interval(max, Duration::from_millis(5), 0, 30.0),
            max
        );
        assert_eq!(
            active_frame_interval(max, Duration::from_millis(80), 0, 30.0),
            Duration::from_millis(100)
        );
        assert_eq!(
            active_frame_interval(max, Duration::from_millis(5), 3_750_000, 30.0),
            Duration::from_secs(1)
        );

        let mut timing = LoopTiming {
            max_frame_interval: max,
            current_frame_interval: max,
            next_frame: Instant::now(),
            started_at: Instant::now(),
            unchanged_frames: 0,
            max_mbps: 80.0,
        };
        update_frame_pacing(
            &mut timing,
            FrameOutcome {
                emitted: true,
                elapsed: Duration::from_millis(5),
                bytes: 0,
                content: false,
            },
        );
        assert_eq!(timing.current_frame_interval, max);
        assert_eq!(timing.unchanged_frames, 0);

        for _ in 0..2 {
            update_frame_pacing(
                &mut timing,
                FrameOutcome {
                    emitted: false,
                    elapsed: Duration::from_millis(2),
                    bytes: 0,
                    content: false,
                },
            );
        }
        assert_eq!(timing.current_frame_interval, IDLE_FRAME_INTERVAL);

        update_frame_pacing(
            &mut timing,
            FrameOutcome {
                emitted: true,
                elapsed: Duration::from_millis(5),
                bytes: 0,
                content: false,
            },
        );
        assert_eq!(timing.current_frame_interval, max);
        assert_eq!(timing.unchanged_frames, 0);
    }

    #[test]
    fn graphics_auto_uses_png_for_ui_and_rgb_for_video_like_frames() {
        let (w, h) = (64usize, 64usize);
        let solid = vec![32u8; w * h * 4];
        let solid_profile = frame_profile(&solid, w, h, None);
        let solid_payload =
            encode_kitty_payload(&solid, w, h, KittyGraphicsCodec::Auto, solid_profile).unwrap();
        assert_eq!(solid_payload.format, KittyGraphicsFormat::Png);

        let mut prev = Vec::with_capacity(w * h * 4);
        let mut next = Vec::with_capacity(w * h * 4);
        let mut x = 0x1234_5678u32;
        for _ in 0..w * h {
            x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            prev.extend_from_slice(&[x as u8, (x >> 8) as u8, (x >> 16) as u8, 255]);
            x = x.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            next.extend_from_slice(&[x as u8, (x >> 8) as u8, (x >> 16) as u8, 255]);
        }
        let video_profile = frame_profile(&next, w, h, Some(&prev));
        assert!(video_profile.video_like());
        let video_payload =
            encode_kitty_payload(&next, w, h, KittyGraphicsCodec::Auto, video_profile).unwrap();
        assert_eq!(video_payload.format, KittyGraphicsFormat::Rgb);
        assert_eq!(video_payload.bytes.len(), w * h * 3);
    }

    #[test]
    fn mouse_mapping_uses_actual_adaptive_output_size() {
        // Terminal reports pixel mouse coords in an 800x600 terminal. The cage
        // output is 960x540, letterboxed vertically into 800x450 at y=75.
        let (x, y, ex, ey) =
            map_terminal_point_to_image(400, 300, (80, 30), Some((10, 20)), (960, 540));
        assert_eq!((ex, ey), (800, 460));
        assert_eq!(x, 400);
        assert_eq!(y, 240);

        // With cell coords and a non-default output, the image extent is still
        // derived from the adaptive source aspect, not DEFAULT_OUTPUT.
        let (x, y, ex, ey) = map_terminal_point_to_image(40, 15, (80, 30), None, (960, 540));
        assert_eq!((ex, ey), (80, 23));
        assert_eq!((x, y), (40, 12));
    }

    #[test]
    fn scroll_events_map_to_wayland_axes() {
        assert_eq!(
            scroll_axis(MouseEventKind::ScrollUp),
            Some((wl_pointer::Axis::VerticalScroll, -1))
        );
        assert_eq!(
            scroll_axis(MouseEventKind::ScrollDown),
            Some((wl_pointer::Axis::VerticalScroll, 1))
        );
        assert_eq!(
            scroll_axis(MouseEventKind::ScrollLeft),
            Some((wl_pointer::Axis::HorizontalScroll, -1))
        );
        assert_eq!(
            scroll_axis(MouseEventKind::ScrollRight),
            Some((wl_pointer::Axis::HorizontalScroll, 1))
        );
        assert_eq!(scroll_axis(MouseEventKind::Moved), None);
    }
}

// ────────────────────────── crossterm → cage input ──────────────────────────
//
// Translate terminal key/mouse events into the virtual-keyboard /
// virtual-pointer requests cage receives. Ctrl-Alt-q is the escape hatch (it
// can't go to the app — terminals don't forward it cleanly anyway).

enum TerminalInput {
    Event(Event),
    Error(String),
}

const TERMINAL_INPUT_CAP: usize = 256;
const WHEEL_AXIS_STEP: f64 = 15.0;

fn spawn_terminal_input_thread() -> mpsc::Receiver<TerminalInput> {
    let (tx, rx) = mpsc::sync_channel(TERMINAL_INPUT_CAP);
    std::thread::spawn(move || {
        loop {
            match event::read() {
                Ok(ev) => {
                    let input = TerminalInput::Event(ev);
                    let sent = if is_coalescible_mouse_motion(&input) {
                        tx.try_send(input).is_ok()
                    } else {
                        tx.send(input).is_ok()
                    };
                    if !sent {
                        break;
                    }
                }
                Err(e) => {
                    let _ = tx.send(TerminalInput::Error(e.to_string()));
                    break;
                }
            }
        }
    });
    rx
}

fn is_coalescible_mouse_motion(input: &TerminalInput) -> bool {
    matches!(
        input,
        TerminalInput::Event(Event::Mouse(MouseEvent {
            kind: MouseEventKind::Moved,
            ..
        }))
    )
}

/// Drain pending terminal input. Returns `Ok(true)` when the user pressed the
/// Ctrl-Alt-q escape chord (an explicit quit — the caller must end the session
/// and must NOT fall back to another display profile).
fn drain_terminal_input(
    state: &mut State,
    rx: &mpsc::Receiver<TerminalInput>,
    started_at: Instant,
) -> Result<bool> {
    let mut pending_motion: Option<MouseEvent> = None;
    loop {
        match rx.try_recv() {
            Ok(TerminalInput::Event(Event::Mouse(mouse)))
                if matches!(mouse.kind, MouseEventKind::Moved) =>
            {
                pending_motion = Some(mouse);
            }
            Ok(TerminalInput::Event(Event::Key(key))) if is_escape_chord(&key) => {
                flush_pending_motion(state, &mut pending_motion, started_at);
                return Ok(true);
            }
            Ok(TerminalInput::Event(Event::Key(key))) => {
                flush_pending_motion(state, &mut pending_motion, started_at);
                handle_key(state, key, started_at);
            }
            Ok(TerminalInput::Event(Event::Mouse(mouse))) => {
                flush_pending_motion(state, &mut pending_motion, started_at);
                handle_mouse(state, mouse, started_at);
            }
            Ok(TerminalInput::Event(Event::Resize(_, _))) => {
                pending_motion = None;
                state.terminal_resized = true;
            }
            Ok(TerminalInput::Event(_)) => {}
            Ok(TerminalInput::Error(e)) => bail!("read terminal input: {e}"),
            Err(mpsc::TryRecvError::Empty) | Err(mpsc::TryRecvError::Disconnected) => {
                flush_pending_motion(state, &mut pending_motion, started_at);
                return Ok(false);
            }
        }
    }
}

fn flush_pending_motion(
    state: &mut State,
    pending_motion: &mut Option<MouseEvent>,
    started_at: Instant,
) {
    if let Some(mouse) = pending_motion.take() {
        handle_mouse(state, mouse, started_at);
    }
}

fn is_escape_chord(key: &KeyEvent) -> bool {
    matches!(key.kind, KeyEventKind::Press)
        && matches!(key.code, KeyCode::Char('q') | KeyCode::Char('Q'))
        && key.modifiers.contains(KeyModifiers::CONTROL)
        && key.modifiers.contains(KeyModifiers::ALT)
}

fn handle_key(state: &mut State, key: KeyEvent, started_at: Instant) {
    let time = started_at.elapsed().as_millis() as u32;

    if matches!(key.kind, KeyEventKind::Release) {
        release_pending_key(state, time);
        if let (Some(kb), Some(evdev)) = (state.vkeyboard.as_ref(), evdev_keycode_for(key.code)) {
            kb.key(time, evdev, 0);
        }
        return;
    }

    if !matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
        return;
    }

    // Terminals usually only report Press events. Press now, then release from
    // the main loop after a short delay. This avoids two bad extremes:
    // same-timestamp down+up can vanish, but holding until the next key triggers
    // compositor/app repeat floods (IBus queue growth in GNOME apps).
    release_pending_key(state, time);

    if let Some(evdev) = evdev_keycode_for(key.code) {
        tracing::debug!(code = ?key.code, kind = ?key.kind, modifiers = ?key.modifiers, evdev, "forward key");
        let Some(kb) = state.vkeyboard.as_ref() else {
            tracing::debug!("drop key: no virtual keyboard");
            return;
        };
        let mut mods = key_modifiers(key.modifiers);
        if key_requires_shift(key.code) && !mods.contains(&KEY_LEFTSHIFT) {
            mods.evdev.push(KEY_LEFTSHIFT);
            mods.xkb_depressed |= XKB_MOD_SHIFT;
        }
        for &m in &mods.evdev {
            kb.key(time, m, 1);
        }
        kb.modifiers(mods.xkb_depressed, 0, 0, 0);
        kb.key(time, evdev, 1);
        state.pending_key = Some(PendingKey {
            evdev,
            mods,
            release_at: Instant::now() + KEY_TAP,
        });
    } else {
        tracing::debug!(code = ?key.code, kind = ?key.kind, modifiers = ?key.modifiers, "drop key: unmapped");
    }
}

fn release_due_key(state: &mut State, started_at: Instant) {
    if state
        .pending_key
        .as_ref()
        .is_some_and(|pending| Instant::now() >= pending.release_at)
    {
        let time = started_at.elapsed().as_millis() as u32;
        release_pending_key(state, time);
    }
}

fn release_pending_key(state: &mut State, time: u32) {
    let Some(pending) = state.pending_key.take() else {
        return;
    };
    let Some(kb) = state.vkeyboard.as_ref() else {
        return;
    };
    kb.key(time, pending.evdev, 0);
    for &m in pending.mods.evdev.iter().rev() {
        kb.key(time, m, 0);
    }
    kb.modifiers(0, 0, 0, 0);
}

fn handle_mouse(state: &mut State, mouse: MouseEvent, started_at: Instant) {
    let Some(ptr) = state.vpointer.as_ref() else {
        return;
    };
    let time = started_at.elapsed().as_millis() as u32;
    let (ow, oh) = (
        state.output_size.width.max(1),
        state.output_size.height.max(1),
    );
    // Map the click into the letterboxed image rectangle (off_*, span_*),
    // preserving the click's units: pixels when the cell size is known (mode
    // 1016 → sub-cell accuracy), else cells (mode 1006). Clicks in the
    // letterbox bars clamp to the image edge.
    let cells = term_cell_size().unwrap_or((mouse.column.max(1), mouse.row.max(1)));
    let (x, y, ex, ey) =
        map_terminal_point_to_image(mouse.column, mouse.row, cells, state.cell_px, (ow, oh));
    ptr.motion_absolute(time, x, y, ex, ey);
    if state.cursor {
        state.pointer = Some((x * ow / ex.max(1), y * oh / ey.max(1)));
    }

    if let Some((axis, sign)) = scroll_axis(mouse.kind) {
        // Wayland axis values are positive for down/right, negative for up/left.
        // Include both continuous `axis` and discrete wheel-click metadata so
        // GTK/Qt/WebKit/mpv-style clients can pick their preferred signal.
        let value = WHEEL_AXIS_STEP * f64::from(sign);
        ptr.axis_source(wl_pointer::AxisSource::Wheel);
        ptr.axis_discrete(time, axis, value, sign);
        ptr.axis(time, axis, value);
        ptr.frame();
        return;
    }

    // Native right/middle clicks pass through directly (SGR mouse mode 1006
    // delivers them when the terminal doesn't intercept). Left clicks are
    // sent immediately on press so drag works; on release, if the press was
    // a long static hold, we ALSO fire a right-click — a fallback for
    // terminals that swallow right-click for their own context menu.
    if let MouseEventKind::Down(btn) | MouseEventKind::Up(btn) = mouse.kind
        && let Some(code) = linux_button_code(btn)
    {
        let pressed = matches!(mouse.kind, MouseEventKind::Down(_));
        ptr.button(
            time,
            code,
            if pressed {
                wl_pointer::ButtonState::Pressed
            } else {
                wl_pointer::ButtonState::Released
            },
        );

        if btn == MouseButton::Left {
            if pressed {
                state.left_press = Some((Instant::now(), (x, y)));
            } else if let Some((start, (px, py))) = state.left_press.take() {
                let moved = (x as i64 - px as i64)
                    .abs()
                    .max((y as i64 - py as i64).abs());
                if start.elapsed().as_millis() >= LONG_PRESS_MS && moved <= LONG_PRESS_MOVE {
                    ptr.button(time, 0x111, wl_pointer::ButtonState::Pressed);
                    ptr.button(time, 0x111, wl_pointer::ButtonState::Released);
                }
            }
        }
    }
    ptr.frame();
}

fn scroll_axis(kind: MouseEventKind) -> Option<(wl_pointer::Axis, i32)> {
    match kind {
        MouseEventKind::ScrollUp => Some((wl_pointer::Axis::VerticalScroll, -1)),
        MouseEventKind::ScrollDown => Some((wl_pointer::Axis::VerticalScroll, 1)),
        MouseEventKind::ScrollLeft => Some((wl_pointer::Axis::HorizontalScroll, -1)),
        MouseEventKind::ScrollRight => Some((wl_pointer::Axis::HorizontalScroll, 1)),
        _ => None,
    }
}

fn map_terminal_point_to_image(
    column: u16,
    row: u16,
    cells: (u16, u16),
    cell_px: Option<(u16, u16)>,
    src: (u32, u32),
) -> (u32, u32, u32, u32) {
    let (span_cols, span_rows, off_col, off_row) =
        compute_placement(u32::from(cells.0), u32::from(cells.1), cell_px, src);
    if let Some((cw, ch)) = cell_px.map(|(w, h)| (u32::from(w), u32::from(h))) {
        let (img_x0, img_w) = (off_col * cw, span_cols * cw);
        let (img_y0, img_h) = (off_row * ch, span_rows * ch);
        let x = u32::from(column)
            .saturating_sub(img_x0)
            .min(img_w.saturating_sub(1));
        let y = u32::from(row)
            .saturating_sub(img_y0)
            .min(img_h.saturating_sub(1));
        (x, y, img_w.max(1), img_h.max(1))
    } else {
        let x = u32::from(column)
            .saturating_sub(off_col)
            .min(span_cols.saturating_sub(1));
        let y = u32::from(row)
            .saturating_sub(off_row)
            .min(span_rows.saturating_sub(1));
        (x, y, span_cols.max(1), span_rows.max(1))
    }
}

/// Map a crossterm click to the compositor button code (linux input.h BTN_*).
fn linux_button_code(button: MouseButton) -> Option<u32> {
    match button {
        MouseButton::Left => Some(0x110),
        MouseButton::Right => Some(0x111),
        MouseButton::Middle => Some(0x112),
    }
}

/// Linux evdev keycodes for modifier keys (from `linux/input-event-codes.h`).
const KEY_LEFTCTRL: u32 = 29;
const KEY_LEFTSHIFT: u32 = 42;
const KEY_LEFTALT: u32 = 56;
const XKB_MOD_SHIFT: u32 = 1 << 0;
const XKB_MOD_CONTROL: u32 = 1 << 2;
const XKB_MOD_ALT: u32 = 1 << 3;

#[derive(Clone, Debug, Default)]
struct ActiveKeyModifiers {
    evdev: Vec<u32>,
    xkb_depressed: u32,
}

impl ActiveKeyModifiers {
    fn contains(&self, evdev: &u32) -> bool {
        self.evdev.contains(evdev)
    }
}

fn key_modifiers(mods: KeyModifiers) -> ActiveKeyModifiers {
    let mut active = ActiveKeyModifiers::default();
    if mods.contains(KeyModifiers::CONTROL) {
        active.evdev.push(KEY_LEFTCTRL);
        active.xkb_depressed |= XKB_MOD_CONTROL;
    }
    if mods.contains(KeyModifiers::SHIFT) {
        active.evdev.push(KEY_LEFTSHIFT);
        active.xkb_depressed |= XKB_MOD_SHIFT;
    }
    if mods.contains(KeyModifiers::ALT) {
        active.evdev.push(KEY_LEFTALT);
        active.xkb_depressed |= XKB_MOD_ALT;
    }
    active
}

/// Terminals report printable characters after applying the user's keyboard
/// layout, and not all of them consistently preserve a Shift modifier for
/// printable ASCII. Our virtual keyboard uses a US XKB keymap, so synthesize
/// Shift for characters that require it on that keymap.
fn key_requires_shift(code: KeyCode) -> bool {
    use KeyCode::*;
    match code {
        Char(c) if c.is_ascii_uppercase() => true,
        Char(c) => matches!(
            c,
            '!' | '@'
                | '#'
                | '$'
                | '%'
                | '^'
                | '&'
                | '*'
                | '('
                | ')'
                | '_'
                | '+'
                | '{'
                | '}'
                | ':'
                | '"'
                | '~'
                | '|'
                | '<'
                | '>'
                | '?'
        ),
        BackTab => true,
        _ => false,
    }
}

/// US QWERTY evdev keycodes for 'a'–'z' (alphabetical order). Letters don't
/// follow ASCII ordering — they follow the physical keyboard layout.
const ALPHA_EVDEV: [u32; 26] = [
    30, 48, 46, 32, 18, 33, 34, 35, 23, 36, 37, 38, 50, // a–m
    49, 24, 25, 16, 19, 31, 20, 22, 47, 17, 45, 21, 44, // n–z
];

/// Map a crossterm `KeyCode` to a **raw Linux evdev keycode** (as used by
/// `linux/input-event-codes.h` and expected by `zwp_virtual_keyboard_v1.key`).
fn evdev_keycode_for(code: KeyCode) -> Option<u32> {
    use KeyCode::*;
    Some(match code {
        // Letters — algorithmic lookup by position in the alphabet.
        Char(c) if c.is_ascii_alphabetic() => {
            ALPHA_EVDEV[(c.to_ascii_lowercase() as u32 - b'a' as u32) as usize]
        }
        // Digits — evdev KEY_1=2 … KEY_9=10, KEY_0=11.
        Char(c) if c.is_ascii_digit() => {
            if c == '0' {
                11
            } else {
                (c as u32 - b'1' as u32) + 2
            }
        }
        // Punctuation (US layout — no pattern, must be tabulated).
        Char(c) => match c.to_ascii_lowercase() {
            '!' => 2,
            '@' => 3,
            '#' => 4,
            '$' => 5,
            '%' => 6,
            '^' => 7,
            '&' => 8,
            '*' => 9,
            '(' => 10,
            ')' => 11,
            '-' => 12,
            '_' => 12,
            '=' => 13,
            '+' => 13,
            '[' => 26,
            '{' => 26,
            ']' => 27,
            '}' => 27,
            ';' => 39,
            ':' => 39,
            '\'' => 40,
            '"' => 40,
            '`' => 41,
            '~' => 41,
            '\\' => 43,
            '|' => 43,
            ',' => 51,
            '<' => 51,
            '.' => 52,
            '>' => 52,
            '/' => 53,
            '?' => 53,
            ' ' => 57,
            _ => return None,
        },
        // Special keys.
        Esc => 1,
        Backspace => 14,
        Tab | BackTab => 15,
        Enter => 28,
        // Function keys — F1–F10 are sequential (59–68), F11/F12 jump.
        F(n @ 1..=10) => 58 + u32::from(n),
        F(11) => 87,
        F(12) => 88,
        // Navigation cluster.
        Home => 102,
        Up => 103,
        PageUp => 104,
        Left => 105,
        Right => 106,
        End => 107,
        Down => 108,
        PageDown => 109,
        Insert => 110,
        Delete => 111,
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
            tracing::debug!("virtual keyboard created + keymap uploaded");
        } else {
            tracing::debug!("virtual keyboard created, but keymap memfd failed");
        }
        state.vkeyboard = Some(kb);
    } else {
        tracing::debug!("virtual keyboard unavailable: missing manager or seat");
    }
    if let Some(mgr) = state.vp_manager.as_ref() {
        state.vpointer = Some(mgr.create_virtual_pointer(state.seat.as_ref(), qh, ()));
        tracing::debug!("virtual pointer created");
    } else {
        tracing::debug!("virtual pointer unavailable: missing manager");
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

fn cage_path() -> Option<PathBuf> {
    if let Some(p) = env::var_os("ZUKO_CAGE") {
        let p = PathBuf::from(p);
        if p.is_file() {
            return Some(p);
        }
    }
    if let Some(prefix) = bundled_cage_prefix() {
        let p = prefix.join("cage");
        if p.is_file() {
            return Some(p);
        }
    }
    find_bin("cage", "ZUKO_CAGE")
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

fn spawn_cage(args: &AppArgs, launch: &Launch, xdg_runtime: &Path) -> Result<Child> {
    use std::os::unix::process::CommandExt;
    let mut cmd = Command::new(cage_bin());
    cmd.env("WLR_BACKENDS", "headless")
        .env("WLR_RENDERER", "pixman")
        .env("WLR_HEADLESS_OUTPUTS", "1")
        .env("XDG_RUNTIME_DIR", xdg_runtime);
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
// per capture, create a frame + SHM buffer, copy, wait for Ready. The captured
// buffer is XRGB8888 with a compositor-provided stride, so the tight RGBA
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
    captured: Option<(usize, usize)>, // w, h for frame_scratch's tight RGBA
    frame_scratch: Vec<u8>,
    // Whether the most recent capture held real content, computed from the raw
    // screencopy pixels BEFORE the cursor crosshair is composited in (otherwise
    // the crosshair could make a blank app read as non-blank and defeat the
    // startup fallback).
    frame_content: bool,
    done: Option<Result<(), String>>,
    // The memfd backing the current screencopy SHM buffer. Held until the next
    // frame so the fd stays valid across the Wayland flush (see BufferDone).
    _screencopy_fd: Option<OwnedFd>,
    // Input devices + a keymap memfd kept alive for the session.
    seat: Option<wl_seat::WlSeat>,
    vk_manager: Option<ZwpVirtualKeyboardManagerV1>,
    vp_manager: Option<ZwlrVirtualPointerManagerV1>,
    output_manager: Option<ZwlrOutputManagerV1>,
    vkeyboard: Option<ZwpVirtualKeyboardV1>,
    vpointer: Option<ZwlrVirtualPointerV1>,
    _keymap_fd: Option<OwnedFd>,
    output_heads: Vec<ZwlrOutputHeadV1>,
    output_config_serial: Option<u32>,
    output_config_result: Option<Result<(), String>>,
    output_size: OutputSize,
    target_output_size: OutputSize,
    output_scale: f32,
    terminal_resized: bool,
    graphics_codec: KittyGraphicsCodec,
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
    // Left-button press tracking for long-press → right-click. Stores the
    // press instant and image-space (x, y) so we can detect a long static hold.
    left_press: Option<(Instant, (u32, u32))>,
    // Key currently held down on the virtual keyboard. Released from the main
    // loop after KEY_TAP to synthesize terminal key-up without repeat floods.
    pending_key: Option<PendingKey>,
}

struct PendingKey {
    evdev: u32,
    mods: ActiveKeyModifiers,
    release_at: Instant,
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
impl Dispatch<ZwlrOutputManagerV1, ()> for State {
    fn event(
        state: &mut State,
        _: &ZwlrOutputManagerV1,
        event: zwlr_output_manager_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match event {
            zwlr_output_manager_v1::Event::Head { head } => state.output_heads.push(head),
            zwlr_output_manager_v1::Event::Done { serial } => {
                state.output_config_serial = Some(serial);
            }
            zwlr_output_manager_v1::Event::Finished => {}
            _ => {}
        }
    }

    wayland_client::event_created_child!(State, ZwlrOutputManagerV1, [
        // zwlr_output_manager_v1.head(new_id zwlr_output_head_v1)
        0 => (ZwlrOutputHeadV1, ()),
    ]);
}
impl Dispatch<ZwlrOutputHeadV1, ()> for State {
    fn event(
        _: &mut State,
        _: &ZwlrOutputHeadV1,
        _: zwlr_output_head_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }

    wayland_client::event_created_child!(State, ZwlrOutputHeadV1, [
        // zwlr_output_head_v1.mode(new_id zwlr_output_mode_v1)
        3 => (ZwlrOutputModeV1, ()),
    ]);
}
impl Dispatch<ZwlrOutputModeV1, ()> for State {
    fn event(
        _: &mut State,
        _: &ZwlrOutputModeV1,
        _: zwlr_output_mode_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}
impl Dispatch<ZwlrOutputConfigurationV1, ()> for State {
    fn event(
        state: &mut State,
        _: &ZwlrOutputConfigurationV1,
        event: zwlr_output_configuration_v1::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        state.output_config_result = Some(match event {
            zwlr_output_configuration_v1::Event::Succeeded => Ok(()),
            zwlr_output_configuration_v1::Event::Failed => {
                Err("output configuration failed".into())
            }
            zwlr_output_configuration_v1::Event::Cancelled => {
                Err("output configuration cancelled".into())
            }
            _ => return,
        });
    }
}
impl Dispatch<ZwlrOutputConfigurationHeadV1, ()> for State {
    fn event(
        _: &mut State,
        _: &ZwlrOutputConfigurationHeadV1,
        _: zwlr_output_configuration_head_v1::Event,
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
                // Keep the memfd alive until the connection flushes —
                // create_pool sent the raw fd number (via BorrowedFd), and if
                // the OwnedFd closes before flush, the stale fd number causes
                // "invalid arguments for wl_shm.create_pool" on the compositor.
                state._screencopy_fd = Some(fd);
            }
            Ready { .. } => {
                if let Some((w, h, stride)) = state.dims
                    && let Some(mmap_arc) = state.mmap.take()
                {
                    let guard = mmap_arc.lock().unwrap();
                    let frame_len = w as usize * h as usize * 4;
                    let out = &mut state.frame_scratch;
                    out.clear();
                    out.reserve(frame_len.saturating_sub(out.capacity()));
                    for y in 0..h as usize {
                        let row = &guard[y * stride as usize..y * stride as usize + w as usize * 4];
                        for px in row.chunks_exact(4) {
                            // XRGB8888 little-endian -> bytes B,G,R,X. Emit R,G,B,255.
                            out.push(px[2]);
                            out.push(px[1]);
                            out.push(px[0]);
                            out.push(255);
                        }
                    }
                    let _ = &guard;
                    // Detect blank/uniform output on the raw pixels, before the
                    // cursor crosshair is drawn (it would otherwise add differing
                    // pixels and mask a blank app from the startup fallback).
                    let content = frame_has_content(out.as_slice());
                    if state.cursor
                        && let Some((px, py)) = state.pointer
                    {
                        draw_cursor(out, w as usize, h as usize, px as i32, py as i32);
                    }
                    state.frame_content = content;
                    state.captured = Some((w as usize, h as usize));
                }
                state.done = Some(Ok(()));
            }
            Failed => state.done = Some(Err("server reported screencopy Failed".into())),
            Flags { .. } => {}
            _ => {}
        }
    }
}
