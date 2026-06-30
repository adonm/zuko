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
        kitty_emit_png(
            w as u32,
            h as u32,
            &png,
            true,
            term_cell_size().map(|(c, r)| (c as u32, r as u32)),
        )?;
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

    // Fresh per-session XDG_RUNTIME_DIR so cage's `wayland-0` is unambiguous
    // and we don't touch the user's real session.
    let xdg_runtime = make_xdg_runtime_dir()?;
    let socket_path = xdg_runtime.join("wayland-0");

    let mut cage = spawn_cage(&args, &launch, &xdg_runtime)?;
    wait_for_ready(&mut cage, &socket_path)?;

    eprintln!(
        "zuko app: cage running {} at {}x{} (pixman/headless); connecting…",
        launch.label, DEFAULT_OUTPUT.0, DEFAULT_OUTPUT.1
    );

    // Point our own Wayland client env at cage's socket, then connect.
    // SAFETY: single-threaded at this point (before the Wayland event loop or
    // any input thread starts); no other thread can read these env vars
    // concurrently. Edition 2024 marks set_var unsafe for the data-race risk.
    unsafe {
        env::set_var("XDG_RUNTIME_DIR", &xdg_runtime);
        env::set_var("WAYLAND_DISPLAY", "wayland-0");
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

    // Best-effort cleanup: kill cage (it reaps the app child). The TerminalModeGuard
    // drop restores the terminal + clears Kitty placements.
    let _ = cage.kill();
    let _ = cage.wait();
    result
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
    let png = encode_rgba_png(&rgba, w, h)?;
    kitty_emit_png(
        w as u32,
        h as u32,
        &png,
        !std::mem::replace(placed, true),
        cells.map(|(c, r)| (c as u32, r as u32)),
    )?;
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
    // Extent for motion_absolute: terminal PIXEL dims if known (mode 1016 is
    // on → mouse.column/.row are pixels → sub-cell accuracy), else cell counts
    // (mode 1006 → coords quantize to ~1 cell). `x`/`y` and the extent are in
    // the same unit either way, so the proportional map + crosshair stay
    // consistent with where the click actually lands.
    let (ex, ey) = term_pixel_dims(state.cell_px)
        .or_else(|| term_cell_size().map(|(c, r)| (u32::from(c), u32::from(r))))
        .unwrap_or((1, 1));
    let x = u32::from(mouse.column).min(ex.saturating_sub(1));
    let y = u32::from(mouse.row).min(ey.saturating_sub(1));
    ptr.motion_absolute(time, x, y, ex, ey);
    // Track the pointer in output pixels for the crosshair overlay.
    if state.cursor {
        let (ow, oh) = (
            u32::try_from(DEFAULT_OUTPUT.0).unwrap_or(1),
            u32::try_from(DEFAULT_OUTPUT.1).unwrap_or(1),
        );
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
    // Prefer /run/user/$UID (tmpfs, correct perms); fall back to a tmp dir.
    let base = env::var("XDG_RUNTIME_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir());
    let dir = base.join(format!("zuko-app-{}", std::process::id()));
    fs::create_dir_all(&dir)
        .with_context(|| format!("create XDG_RUNTIME_DIR {}", dir.display()))?;
    Ok(dir)
}

fn spawn_cage(args: &AppArgs, launch: &Launch, xdg_runtime: &Path) -> Result<Child> {
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

/// Wait for cage to bind its Wayland socket, OR fail fast if cage dies first.
///
/// The fast-fail path is the graceful-degradation case: when the host is missing
/// one of cage's runtime libraries (libwayland/libxkbcommon/libdrm/libxcb/…),
/// the dynamic loader kills cage immediately and prints the offending lib to
/// stderr (which we inherit, so it's already visible above). Without this check
/// we'd silently loop for `SOCKET_WAIT` and then report a misleading "socket
/// never appeared". The rest of zuko (host/connect/…) never links those libs, so
/// only `zuko app` is affected — the binary itself runs fine on minimal hosts.
fn wait_for_ready(cage: &mut Child, path: &Path) -> Result<()> {
    let deadline = Instant::now() + SOCKET_WAIT;
    while Instant::now() < deadline {
        if path.exists() {
            return Ok(());
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
        "cage did not bind Wayland socket {} within {SOCKET_WAIT:?}",
        path.display()
    );
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
