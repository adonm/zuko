//! `zuko app` — host one Wayland GUI app in a terminal.
//!
//! This module is intentionally Linux-only and starts with the smallest useful
//! Smithay kiosk skeleton: create a private Wayland socket, advertise the
//! desktop globals Firefox expects, spawn exactly one child app against that
//! socket, force any toplevel fullscreen to the terminal's pixel size, and exit
//! cleanly with the child. Rendering/input are added in the sibling modules as
//! the next implementation phases; the zuko wire protocol is unchanged because
//! the eventual Kitty graphics stream is just terminal output.

use anyhow::{Context, Result, bail};
use crossterm::{
    cursor::{Hide, Show},
    event::{
        self, DisableMouseCapture, EnableMouseCapture, Event, KeyCode, KeyEvent, KeyEventKind,
        KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
    },
    execute,
    terminal::{EnterAlternateScreen, LeaveAlternateScreen},
};
use smithay::{
    backend::{
        allocator::Fourcc,
        input::{ButtonState, KeyState, Keycode},
        renderer::{
            Bind, Color32F, ExportMem, Frame, Offscreen, Renderer,
            element::{
                Kind,
                surface::{WaylandSurfaceRenderElement, render_elements_from_surface_tree},
            },
            pixman::PixmanRenderer,
            utils::{draw_render_elements, on_commit_buffer_handler},
        },
    },
    delegate_compositor, delegate_data_device, delegate_output, delegate_seat, delegate_shm,
    delegate_xdg_shell,
    input::{
        Seat, SeatHandler, SeatState,
        keyboard::{FilterResult, KeyboardHandle},
        pointer::{ButtonEvent, MotionEvent, PointerHandle},
    },
    output::{Mode, Output, PhysicalProperties, Scale, Subpixel},
    reexports::{
        wayland_protocols::xdg::shell::server::xdg_toplevel,
        wayland_server::{
            Client, Display, ListeningSocket,
            backend::{ClientData, ClientId, DisconnectReason},
            protocol::{wl_buffer, wl_seat, wl_surface::WlSurface},
        },
    },
    utils::{Buffer, Logical, Physical, Point, Serial, Size},
    wayland::{
        buffer::BufferHandler,
        compositor::{
            CompositorClientState, CompositorHandler, CompositorState, SurfaceAttributes,
            TraversalAction, with_surface_tree_downward,
        },
        output::OutputHandler,
        selection::{
            SelectionHandler,
            data_device::{
                ClientDndGrabHandler, DataDeviceHandler, DataDeviceState, ServerDndGrabHandler,
            },
        },
        shell::xdg::{
            PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState,
        },
        shm::{ShmHandler, ShmState},
    },
};
use std::{
    collections::BTreeMap,
    env,
    io::Write,
    os::fd::OwnedFd,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::Arc,
    time::{Duration, Instant},
};

use crate::AppArgs;

const DEFAULT_WIDTH_PX: i32 = 1280;
const DEFAULT_HEIGHT_PX: i32 = 720;
const FULL_REFRESH_INTERVAL: Duration = Duration::from_secs(5);
/// How long to wait for the XTWINOPS `CSI 16 t` cell-size reply at startup.
/// Covers a typical Iroh relay RTT; override with `ZUKO_PIXEL_PROBE_MS` for
/// slow links. Bounded because terminals that don't implement XTWINOPS never
/// answer, and we must not block app startup forever.
const DEFAULT_PIXEL_PROBE: Duration = Duration::from_millis(250);

/// Run a single child GUI app against a private Wayland socket.
pub fn run(args: AppArgs) -> Result<()> {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "zuko=info,smithay=warn".into()),
        )
        .try_init();

    validate_args(&args)?;

    if args.test_pattern {
        let _terminal = TerminalModeGuard::enter().context("enter terminal app mode")?;
        let cell_px = probe_terminal_cell_pixels(DEFAULT_PIXEL_PROBE);
        let size = terminal_pixel_size(cell_px).unwrap_or(Size::from((640, 360)));
        kitty_clear_screen().ok();
        let png = encode_test_pattern(size.w.max(1) as usize, size.h.max(1) as usize)?;
        kitty_emit_png(size.w.max(1) as u32, size.h.max(1) as u32, &png, true)?;
        eprintln!(
            "zuko app: Kitty test pattern rendered at {}x{}; press Enter to exit",
            size.w, size.h
        );
        let mut buf = String::new();
        let _ = std::io::stdin().read_line(&mut buf);
        return Ok(());
    }

    if args.list {
        print_discovered_apps()?;
        return Ok(());
    }

    // Note: `--software` only configures the *child* app's environment
    // (MOZ_WEBRENDER=software, etc.) via app_env below. The compositor itself
    // always renders in software now (Pixman), so there's no longer an EGL
    // driver to coax onto a software path.

    let socket_name = format!("wayland-zuko-{}", std::process::id());
    let launch = resolve_launch(&args, &socket_name).context("resolve app launch command")?;

    if args.dry_run {
        print_launch(&launch, &socket_name);
        return Ok(());
    }

    let _terminal = TerminalModeGuard::enter().context("enter terminal app mode")?;

    // Probe the cell pixel size ONCE. The reply round-trips through the Iroh
    // relay to the client's terminal and back, so this is the one spot we pay a
    // network RTT for pixel info. `cell_px` feeds the initial size and is reused
    // on every resize below (cell size only changes on font change, not resize).
    let cell_px = probe_terminal_cell_pixels(DEFAULT_PIXEL_PROBE);
    if cell_px.is_none() {
        eprintln!(
            "zuko app: terminal didn't answer the pixel-size probe within {:?}; \
             falling back to ws_xpixel / cell estimate (may blur on HiDPI). \
             Set ZUKO_PIXEL_PROBE_MS=<ms> to extend the timeout.",
            DEFAULT_PIXEL_PROBE
        );
    }

    let size =
        terminal_pixel_size(cell_px).unwrap_or(Size::from((DEFAULT_WIDTH_PX, DEFAULT_HEIGHT_PX)));

    let mut display: Display<App> = Display::new().context("create Wayland display")?;
    let dh = display.handle();
    let output = Output::new(
        "zuko-terminal".into(),
        PhysicalProperties {
            size: (size.w / 4, size.h / 4).into(),
            subpixel: Subpixel::Unknown,
            make: "zuko".into(),
            model: "terminal".into(),
        },
    );
    let mode = Mode {
        size: Size::from((size.w, size.h)),
        refresh: i32::from(args.fps.max(1)) * 1000,
    };
    output.create_global::<App>(&dh);
    output.change_current_state(
        Some(mode),
        Some(smithay::utils::Transform::Normal),
        Some(Scale::Integer(1)),
        Some((0, 0).into()),
    );
    output.set_preferred(mode);

    let compositor_state = CompositorState::new::<App>(&dh);
    let xdg_shell_state = XdgShellState::new::<App>(&dh);
    let shm_state = ShmState::new::<App>(&dh, vec![]);
    let data_device_state = DataDeviceState::new::<App>(&dh);
    let mut seat_state = SeatState::new();
    let seat = seat_state.new_wl_seat(&dh, "zuko-app");

    let mut state = App {
        compositor_state,
        xdg_shell_state,
        shm_state,
        seat_state,
        data_device_state,
        seat,
        output_size: size,
        dirty: true,
        pending_resize: false,
        serial: 1,
    };

    // Advertise basic seat capabilities. Input routing is implemented in the
    // next phase, but Firefox expects the globals/capabilities to exist.
    // Repeat rate/delay are both 0: the hosted app must NOT auto-repeat on its
    // own. Without the kitty keyboard protocol the terminal reports a key
    // Press but no Release, so any non-zero repeat rate would make every
    // character run away (`a` -> `aaaaaa…`). The terminal already sends its
    // own repeats while a key is physically held, so compositor repeat is
    // redundant; keeping it disabled is correct.
    let keyboard = state
        .seat
        .add_keyboard(Default::default(), 0, 0)
        .context("create Wayland keyboard")?;
    let pointer = state.seat.add_pointer();

    let listener = ListeningSocket::bind(&socket_name)
        .with_context(|| format!("bind Wayland socket {socket_name:?}"))?;
    eprintln!(
        "zuko app: starting {} on WAYLAND_DISPLAY={} at {}x{}",
        launch.label, socket_name, size.w, size.h
    );

    let mut child = ChildGuard(spawn_child(&args, &launch).context("spawn app")?);
    let mut clients = Vec::new();
    let mut renderer = RenderState::new(size).context("create EGL renderer")?;
    let frame_interval = Duration::from_millis((1000 / u64::from(args.fps)).max(1));
    let mut next_frame = Instant::now();
    let mut last_full = Instant::now()
        .checked_sub(FULL_REFRESH_INTERVAL)
        .unwrap_or_else(Instant::now);
    let started_at = Instant::now();

    kitty_clear_screen().ok();

    loop {
        while let Some(stream) = listener.accept().context("accept Wayland client")? {
            let client = display
                .handle()
                .insert_client(stream, Arc::new(ClientState::default()))
                .context("insert Wayland client")?;
            clients.push(client);
        }

        display
            .dispatch_clients(&mut state)
            .context("dispatch Wayland clients")?;
        display.flush_clients().context("flush Wayland clients")?;

        pump_terminal_input(&mut state, &keyboard, &pointer, started_at)?;

        // Terminal resized: rebuild the Pixman render target at the new pixel
        // size, update the Wayland output mode + logical size, and reconfigure
        // existing toplevels so the app redraws at the new dimensions. A fresh
        // RenderState starts with `placed = false`, so the next emit re-places
        // the Kitty image at the new size instead of updating the old one.
        if state.pending_resize {
            state.pending_resize = false;
            if let Some(new_size) = terminal_pixel_size(cell_px) {
                renderer =
                    RenderState::new(new_size).context("recreate render target on resize")?;
                state.output_size = new_size;
                let mode = Mode {
                    size: Size::from((new_size.w, new_size.h)),
                    refresh: i32::from(args.fps.max(1)) * 1000,
                };
                output.change_current_state(
                    Some(mode),
                    Some(smithay::utils::Transform::Normal),
                    Some(Scale::Integer(1)),
                    Some((0, 0).into()),
                );
                output.set_preferred(mode);
                for surface in state.xdg_shell_state.toplevel_surfaces() {
                    surface.with_pending_state(|s| {
                        s.size = Some(new_size);
                        s.bounds = Some(new_size);
                    });
                    surface.send_configure();
                }
                state.dirty = true;
            }
        }

        if let Some(status) = child.try_wait().context("poll child process")? {
            eprintln!("zuko app: child exited with {status}");
            break;
        }

        let now = Instant::now();
        if now >= next_frame
            && !state.xdg_shell_state.toplevel_surfaces().is_empty()
            && (state.dirty || now.duration_since(last_full) >= FULL_REFRESH_INTERVAL)
        {
            renderer
                .render_and_emit(&mut state, args.scale)
                .context("render app frame")?;
            state.dirty = false;
            last_full = now;
            for surface in state.xdg_shell_state.toplevel_surfaces() {
                send_frames_surface_tree(
                    surface.wl_surface(),
                    started_at.elapsed().as_millis() as u32,
                );
            }
            display.flush_clients().context("flush frame callbacks")?;
            // Advance the render throttle only when we actually emitted a
            // frame. This was previously outside the block, which pushed the
            // ~frame_interval deadline forward on every 8ms tick — so once a
            // surface appeared, `now >= next_frame` was never true and no frame
            // was ever rendered (blank terminal).
            next_frame = now + frame_interval;
        }

        std::thread::sleep(Duration::from_millis(8));
    }

    Ok(())
}

struct RenderState {
    renderer: PixmanRenderer,
    target: smithay::reexports::pixman::Image<'static, 'static>,
    physical_size: Size<i32, Physical>,
    buffer_size: Size<i32, Buffer>,
    placed: bool,
}

fn pump_terminal_input(
    state: &mut App,
    keyboard: &KeyboardHandle<App>,
    pointer: &PointerHandle<App>,
    started_at: Instant,
) -> Result<()> {
    while event::poll(Duration::ZERO).context("poll terminal input")? {
        match event::read().context("read terminal input")? {
            Event::Key(key) => {
                if is_escape_chord(key) {
                    bail!("zuko app interrupted by Ctrl-Alt-q");
                }
                handle_key(state, keyboard, key, started_at);
            }
            Event::Mouse(mouse) => handle_mouse(state, pointer, mouse, started_at),
            Event::Resize(_, _) => {
                // The new terminal size isn't known here (crossterm gives cells,
                // not pixels); `run()` re-queries the pixel size and rebuilds the
                // render target + Wayland output there, where they live.
                state.pending_resize = true;
            }
            _ => {}
        }
    }
    Ok(())
}

fn handle_key(state: &mut App, keyboard: &KeyboardHandle<App>, key: KeyEvent, started_at: Instant) {
    let Some(code) = xkb_keycode_for(key.code) else {
        return;
    };
    let key_state = match key.kind {
        KeyEventKind::Press | KeyEventKind::Repeat => KeyState::Pressed,
        KeyEventKind::Release => KeyState::Released,
    };
    focus_keyboard(state, keyboard);
    let serial = state.next_serial();
    let time = started_at.elapsed().as_millis() as u32;

    if matches!(key.kind, KeyEventKind::Press | KeyEventKind::Repeat) {
        for modifier in modifier_keycodes(key.modifiers) {
            let serial = state.next_serial();
            keyboard.input::<(), _>(
                state,
                Keycode::from(modifier),
                KeyState::Pressed,
                serial,
                time,
                |_, _, _| FilterResult::Forward,
            );
        }
    }
    keyboard.input::<(), _>(
        state,
        Keycode::from(code),
        key_state,
        serial,
        time,
        |_, _, _| FilterResult::Forward,
    );
    if matches!(key.kind, KeyEventKind::Release | KeyEventKind::Press) {
        for modifier in modifier_keycodes(key.modifiers).into_iter().rev() {
            let serial = state.next_serial();
            keyboard.input::<(), _>(
                state,
                Keycode::from(modifier),
                KeyState::Released,
                serial,
                time,
                |_, _, _| FilterResult::Forward,
            );
        }
    }
    state.dirty = true;
}

fn handle_mouse(
    state: &mut App,
    pointer: &PointerHandle<App>,
    mouse: MouseEvent,
    started_at: Instant,
) {
    let Some(surface) = first_surface(state) else {
        return;
    };
    let pos = terminal_mouse_to_logical(state.output_size, mouse.column, mouse.row);
    let serial = state.next_serial();
    let time = started_at.elapsed().as_millis() as u32;
    pointer.motion(
        state,
        Some((surface, Point::from((0.0, 0.0)))),
        &MotionEvent {
            location: pos,
            serial,
            time,
        },
    );
    match mouse.kind {
        MouseEventKind::Down(button) | MouseEventKind::Up(button) => {
            let button = effective_button(button, mouse.modifiers);
            let Some(button) = linux_button_code(button) else {
                pointer.frame(state);
                return;
            };
            let serial = state.next_serial();
            pointer.button(
                state,
                &ButtonEvent {
                    serial,
                    time,
                    button,
                    state: if matches!(mouse.kind, MouseEventKind::Down(_)) {
                        ButtonState::Pressed
                    } else {
                        ButtonState::Released
                    },
                },
            );
        }
        _ => {}
    }
    pointer.frame(state);
    state.dirty = true;
}

fn focus_keyboard(state: &mut App, keyboard: &KeyboardHandle<App>) {
    if let Some(surface) = first_surface(state) {
        let serial = state.next_serial();
        keyboard.set_focus(state, Some(surface), serial);
    }
}

fn first_surface(state: &App) -> Option<WlSurface> {
    state
        .xdg_shell_state
        .toplevel_surfaces()
        .iter()
        .next()
        .map(|surface| surface.wl_surface().clone())
}

fn terminal_mouse_to_logical(
    size: Size<i32, Logical>,
    column: u16,
    row: u16,
) -> Point<f64, Logical> {
    // SGR-pixel mode (1016) is on, so `column`/`row` are pixel coordinates in
    // the terminal's pixel space — the same space we render into (the Kitty
    // image is `size` px and the output logical size is `size` at scale 1.0).
    // Map 1:1 and clamp. The previous cell-vs-pixel heuristic (`column <= cols`
    // means cell) was wrong: pixel coords in the top-left are numerically <=
    // the cell count, so it scaled them ~10× and jumped the pointer to the
    // bottom-right quarter.
    Point::from((
        f64::from(column).clamp(0.0, f64::from(size.w)),
        f64::from(row).clamp(0.0, f64::from(size.h)),
    ))
}

fn linux_button_code(button: MouseButton) -> Option<u32> {
    match button {
        MouseButton::Left => Some(0x110),
        MouseButton::Right => Some(0x111),
        MouseButton::Middle => Some(0x112),
    }
}

/// Map a physical click to the button we send to the compositor.
///
/// Most terminals intercept plain right-click (their own context menu) and
/// Shift+click (which bypasses application mouse reporting for text
/// selection), so the hosted app never receives a right-button press here. To
/// keep right-click usable, hold **Alt** while left-clicking: terminals
/// forward Alt+click with the modifier flag intact, and we turn it into a
/// right-button event. A plain right-click still works on terminals that
/// forward it. (Change `ALT` below to `CONTROL` etc. if your WM grabs Alt.)
fn effective_button(button: MouseButton, mods: KeyModifiers) -> MouseButton {
    match (button, mods.contains(KeyModifiers::ALT)) {
        (MouseButton::Left, true) => MouseButton::Right,
        (_, _) => button,
    }
}

fn is_escape_chord(key: KeyEvent) -> bool {
    matches!(key.kind, KeyEventKind::Press)
        && matches!(key.code, KeyCode::Char('q') | KeyCode::Char('Q'))
        && key.modifiers.contains(KeyModifiers::CONTROL)
        && key.modifiers.contains(KeyModifiers::ALT)
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

impl RenderState {
    fn new(size: Size<i32, Logical>) -> Result<Self> {
        let physical_size = Size::from((size.w, size.h));
        let buffer_size = Size::from((size.w, size.h));
        // Pixman is a pure-CPU 2D rasterizer: no EGL display, no GL context,
        // no unsafe FFI dance, no llvmpipe env coaxing — just construct and go.
        let mut renderer = PixmanRenderer::new().context("create pixman renderer")?;
        let target = renderer
            .create_buffer(Fourcc::Abgr8888, buffer_size)
            .context("create offscreen render target")?;
        Ok(Self {
            renderer,
            target,
            physical_size,
            buffer_size,
            placed: false,
        })
    }

    fn render_and_emit(&mut self, state: &mut App, scale: f32) -> Result<()> {
        let damage = smithay::utils::Rectangle::from_size(self.physical_size);
        let elements = state
            .xdg_shell_state
            .toplevel_surfaces()
            .iter()
            .flat_map(|surface| {
                render_elements_from_surface_tree(
                    &mut self.renderer,
                    surface.wl_surface(),
                    (0, 0),
                    scale as f64,
                    1.0,
                    Kind::Unspecified,
                )
            })
            .collect::<Vec<WaylandSurfaceRenderElement<PixmanRenderer>>>();

        {
            let mut framebuffer = self
                .renderer
                .bind(&mut self.target)
                .context("bind render target")?;
            let mut frame = self
                .renderer
                .render(
                    &mut framebuffer,
                    self.physical_size,
                    smithay::utils::Transform::Normal,
                )
                .context("begin pixman frame")?;
            frame
                .clear(Color32F::new(0.02, 0.02, 0.02, 1.0), &[damage])
                .context("clear frame")?;
            draw_render_elements(&mut frame, 1.0, &elements, &[damage])
                .context("draw Wayland surfaces")?;
            let _ = frame.finish().context("finish pixman frame")?;
        }

        let framebuffer = self
            .renderer
            .bind(&mut self.target)
            .context("bind target for readback")?;
        let readback = smithay::utils::Rectangle::from_size(self.buffer_size);
        let mapping = self
            .renderer
            .copy_framebuffer(&framebuffer, readback, Fourcc::Abgr8888)
            .context("read back rendered frame")?;
        let bytes = self
            .renderer
            .map_texture(&mapping)
            .context("map rendered frame")?;
        let png = encode_rgba_png(
            bytes,
            self.buffer_size.w as usize,
            self.buffer_size.h as usize,
        )
        .context("encode frame png")?;
        let place = !self.placed;
        kitty_emit_png(
            self.buffer_size.w as u32,
            self.buffer_size.h as u32,
            &png,
            place,
        )
        .context("emit kitty frame")?;
        self.placed = true;
        Ok(())
    }
}

/// Encode an RGBA frame to a fast-compressed PNG for the Kitty graphics
/// protocol.
///
/// Two differences from the old GLES path:
/// - **Top-down, not flipped.** Pixman lays out rows top→bottom (standard image
///   order), which is what PNG and Kitty expect directly. The GLES
///   renderbuffer was bottom-up, so it needed a row reversal — that's gone.
/// - **Stride-aware.** `ExportMem::map_texture` returns `stride * height` bytes
///   and pixman may pad rows beyond `width * 4`; we derive the real stride from
///   the buffer length and copy each row tightly for the encoder.
fn encode_rgba_png(bytes: &[u8], width: usize, height: usize) -> Result<Vec<u8>> {
    let row_bytes = width * 4;
    if height == 0 || row_bytes == 0 {
        bail!("empty frame {width}x{height}");
    }
    let stride = bytes.len() / height;
    if stride < row_bytes {
        bail!(
            "pixman readback stride {stride} too small for {width}px RGBA ({} bytes)",
            bytes.len()
        );
    }
    let mut tight = Vec::with_capacity(row_bytes * height);
    for row in 0..height {
        let start = row * stride;
        tight.extend_from_slice(&bytes[start..start + row_bytes]);
    }

    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width as u32, height as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    encoder.set_filter(png::Filter::NoFilter);
    {
        let mut writer = encoder.write_header()?;
        writer.write_image_data(&tight)?;
    }
    Ok(out)
}

fn encode_test_pattern(width: usize, height: usize) -> Result<Vec<u8>> {
    let mut pixels = Vec::with_capacity(width * height * 4);
    for y in 0..height {
        for x in 0..width {
            let checker = ((x / 32) + (y / 32)) % 2 == 0;
            let r = ((x * 255) / width.max(1)) as u8;
            let g = ((y * 255) / height.max(1)) as u8;
            let b = if checker { 220 } else { 40 };
            pixels.extend_from_slice(&[r, g, b, 255]);
        }
    }

    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width as u32, height as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    encoder.set_filter(png::Filter::NoFilter);
    {
        let mut writer = encoder.write_header()?;
        writer.write_image_data(&pixels)?;
    }
    Ok(out)
}

fn kitty_clear_screen() -> Result<()> {
    let mut out = std::io::stdout();
    out.write_all(b"\x1b[2J\x1b[H")?;
    out.flush()?;
    Ok(())
}

fn kitty_emit_png(width: u32, height: u32, png: &[u8], place: bool) -> Result<()> {
    use base64::Engine as _;
    const CHUNK: usize = 4096;
    let encoded = base64::engine::general_purpose::STANDARD.encode(png);
    let mut out = std::io::stdout();
    out.write_all(b"\x1b[H")?;
    // Place (a=T) only on the first frame; subsequent frames transmit data
    // only (a=t) so the single existing placement updates in place.
    // Re-placing every frame stacked overlapping placements and drove the
    // terminal's cursor/cell accounting out of sync (repeating text, drifting
    // cursor). C=1 (don't advance the cursor past the image) only matters on
    // the placing frame.
    let action = if place { "a=T,C=1" } else { "a=t" };
    let chunks = encoded.as_bytes().chunks(CHUNK).collect::<Vec<_>>();
    for (i, chunk) in chunks.iter().enumerate() {
        let more = usize::from(i + 1 < chunks.len());
        if i == 0 {
            write!(
                out,
                "\x1b_G{action},f=100,t=d,i=1,q=2,s={width},v={height},m={more};"
            )?;
        } else {
            write!(out, "\x1b_Gm={more};")?;
        }
        out.write_all(chunk)?;
        out.write_all(b"\x1b\\")?;
    }
    out.flush()?;
    Ok(())
}

fn send_frames_surface_tree(surface: &WlSurface, time: u32) {
    with_surface_tree_downward(
        surface,
        (),
        |_, _, &()| TraversalAction::DoChildren(()),
        |_surf, states, &()| {
            for callback in states
                .cached_state
                .get::<SurfaceAttributes>()
                .current()
                .frame_callbacks
                .drain(..)
            {
                callback.done(time);
            }
        },
        |_, _, &()| true,
    );
}

struct TerminalModeGuard;

impl TerminalModeGuard {
    fn enter() -> Result<Self> {
        crossterm::terminal::enable_raw_mode().context("enable raw terminal mode")?;
        let mut out = std::io::stdout();
        execute!(out, EnterAlternateScreen, Hide, EnableMouseCapture)
            .context("enable terminal app screen/mouse mode")?;
        // Explicit mouse modes (crossterm turns on SGR/1006 by default, but the
        // compositor's pointer mapping depends on modern non-X10 coordinates):
        //  - 1003: all-motion events (hover/cursor updates matter for GUI apps)
        //  - 1006: SGR encoding (decimal `;`-separated coordinates)
        //  - 1016: SGR-pixel — terminals report pixel coords instead of cells,
        //          so `terminal_mouse_to_logical` gets sub-cell precision.
        //
        // 1016 needs a crossterm that handles 0-based pixel coords without
        // panicking on `coord - 1`; we patch crossterm from git (see
        // [patch.crates-io] in Cargo.toml) until the saturating_sub fix ships
        // on crates.io.
        out.write_all(b"\x1b[?1003h\x1b[?1006h\x1b[?1016h")
            .context("enable SGR/SGR-pixel mouse modes")?;
        out.flush().context("flush terminal app mode setup")?;
        Ok(Self)
    }
}

impl Drop for TerminalModeGuard {
    fn drop(&mut self) {
        let mut out = std::io::stdout();
        // Delete any Kitty graphics placements so a frozen frame doesn't linger
        // over the restored shell after exit (`a=d` with no id deletes all).
        let _ = out.write_all(b"\x1b_Ga=d,q=2\x1b\\");
        let _ = out.write_all(b"\x1b[?1016l\x1b[?1006l\x1b[?1003l");
        let _ = execute!(out, DisableMouseCapture, Show, LeaveAlternateScreen);
        let _ = crossterm::terminal::disable_raw_mode();
        let _ = out.flush();
    }
}

fn validate_args(args: &AppArgs) -> Result<()> {
    if args.command.is_empty() && !args.list && !args.test_pattern {
        bail!("missing app command");
    }
    if args.fps == 0 {
        bail!("--fps must be at least 1");
    }
    if !args.scale.is_finite() || args.scale <= 0.0 {
        bail!("--scale must be a positive finite number");
    }
    Ok(())
}

#[derive(Clone, Debug)]
struct Launch {
    label: String,
    program: String,
    args: Vec<String>,
    env: Vec<(String, String)>,
    flatpak: bool,
}

fn resolve_launch(args: &AppArgs, socket_name: &str) -> Result<Launch> {
    let (query, child_args) = args.command.split_first().context("missing app command")?;
    let env = app_env(socket_name, args.software, args.no_sandbox);
    if let Some(entry) = find_desktop_app(query)? {
        if let Some(app_id) = entry.flatpak_app_id.as_deref() {
            let mut flatpak_args = vec![
                "run".to_string(),
                "--socket=wayland".to_string(),
                "--socket=fallback-x11".to_string(),
            ];
            for (k, v) in &env {
                flatpak_args.push(format!("--env={k}={v}"));
            }
            flatpak_args.push(app_id.to_string());
            flatpak_args.extend(child_args.iter().cloned());
            return Ok(Launch {
                label: format!("{} ({app_id})", entry.name),
                program: "flatpak".to_string(),
                args: flatpak_args,
                // Flatpak itself needs WAYLAND_DISPLAY in its environment so
                // `--socket=wayland` exposes the compositor's custom socket;
                // the --env entries above pass the same values into the
                // sandboxed app.
                env,
                flatpak: true,
            });
        }
        if let Some(exec) = entry.exec.as_deref() {
            let mut words = desktop_exec_words(exec)?;
            if !words.is_empty() {
                let program = words.remove(0);
                words.extend(child_args.iter().cloned());
                return Ok(Launch {
                    label: entry.name,
                    program,
                    args: words,
                    env,
                    flatpak: false,
                });
            }
        }
    }

    let mut argv = child_args.to_vec();
    Ok(Launch {
        label: query.clone(),
        program: query.clone(),
        args: std::mem::take(&mut argv),
        env,
        flatpak: false,
    })
}

fn app_env(socket_name: &str, software: bool, no_sandbox: bool) -> Vec<(String, String)> {
    let mut env = vec![
        ("WAYLAND_DISPLAY".to_string(), socket_name.to_string()),
        ("MOZ_ENABLE_WAYLAND".to_string(), "1".to_string()),
        ("DISPLAY".to_string(), String::new()),
        ("GDK_BACKEND".to_string(), "wayland".to_string()),
        ("QT_QPA_PLATFORM".to_string(), "wayland".to_string()),
    ];
    if software {
        env.push(("LIBGL_ALWAYS_SOFTWARE".to_string(), "1".to_string()));
        env.push(("MOZ_WEBRENDER".to_string(), "software".to_string()));
    }
    if no_sandbox {
        env.push(("MOZ_DISABLE_CONTENT_SANDBOX".to_string(), "1".to_string()));
        env.push(("MOZ_DISABLE_RDD_SANDBOX".to_string(), "1".to_string()));
        env.push(("MOZ_DISABLE_GPU_SANDBOX".to_string(), "1".to_string()));
        env.push((
            "MOZ_DISABLE_SOCKET_PROCESS_SANDBOX".to_string(),
            "1".to_string(),
        ));
    }
    env
}

fn spawn_child(args: &AppArgs, launch: &Launch) -> Result<std::process::Child> {
    let mut cmd = Command::new(&launch.program);
    cmd.args(&launch.args);
    for (k, v) in &launch.env {
        cmd.env(k, v);
    }
    if args.debug_child {
        cmd.stdout(Stdio::inherit()).stderr(Stdio::inherit());
    } else {
        cmd.stdout(Stdio::null()).stderr(Stdio::null());
    }
    cmd.spawn()
        .with_context(|| format!("spawn child command {:?}", launch.program))
}

/// Wraps the spawned app so it's killed when `zuko app` exits for any reason
/// (Ctrl-Alt-q, error, or its own exit), preventing an orphaned GUI app from
/// running against a dead compositor. Killing an already-exited child is a
/// no-op, so the normal "child exited" path is unaffected.
struct ChildGuard(std::process::Child);

impl ChildGuard {
    fn try_wait(&mut self) -> std::io::Result<Option<std::process::ExitStatus>> {
        self.0.try_wait()
    }
}

impl Drop for ChildGuard {
    fn drop(&mut self) {
        // Kill only — do NOT wait(). This guard is declared after
        // `TerminalModeGuard`, so it drops *first*; a blocking wait() here
        // would hold the terminal in raw mode until the child reaped, which
        // looked like an exit hang. SIGKILL is enough to end the child; any
        // transient zombie is reaped by the parent/init when zuko exits.
        let _ = self.0.kill();
    }
}

fn print_launch(launch: &Launch, socket_name: &str) {
    println!("label: {}", launch.label);
    println!(
        "kind:  {}",
        if launch.flatpak { "flatpak" } else { "command" }
    );
    println!("wayland:");
    println!("  XDG_RUNTIME_DIR={:?}", env::var("XDG_RUNTIME_DIR").ok());
    println!("  WAYLAND_DISPLAY={socket_name}");
    if let Ok(runtime) = env::var("XDG_RUNTIME_DIR") {
        println!("  socket path would be: {runtime}/{socket_name}");
    }
    if !launch.env.is_empty() {
        println!("env:");
        for (k, v) in &launch.env {
            println!("  {k}={v:?}");
        }
    }
    println!("argv:");
    println!(
        "  {}",
        shell_join(std::iter::once(&launch.program).chain(launch.args.iter()))
    );
}

fn shell_join<'a>(parts: impl Iterator<Item = &'a String>) -> String {
    parts
        .map(|s| shell_words::quote(s).into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

#[derive(Clone, Debug)]
struct DesktopApp {
    id: String,
    name: String,
    exec: Option<String>,
    flatpak_app_id: Option<String>,
    aliases: Vec<String>,
}

fn print_discovered_apps() -> Result<()> {
    for app in discover_desktop_apps()?.values() {
        let flatpak = app
            .flatpak_app_id
            .as_ref()
            .map(|id| format!(" flatpak={id}"))
            .unwrap_or_default();
        println!(
            "{:<24} {}{}",
            app.aliases.first().unwrap_or(&app.id),
            app.name,
            flatpak
        );
    }
    Ok(())
}

fn find_desktop_app(query: &str) -> Result<Option<DesktopApp>> {
    let needle = normalize_alias(query);
    Ok(discover_desktop_apps()?.into_iter().find_map(|(_, app)| {
        app.aliases
            .iter()
            .any(|alias| normalize_alias(alias) == needle)
            .then_some(app)
    }))
}

fn discover_desktop_apps() -> Result<BTreeMap<String, DesktopApp>> {
    let mut apps = BTreeMap::new();
    for dir in application_dirs() {
        let Ok(read_dir) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in read_dir.flatten() {
            let path = entry.path();
            if path.extension().and_then(|s| s.to_str()) != Some("desktop") {
                continue;
            }
            if let Some(app) = parse_desktop_file(&path)? {
                apps.entry(app.id.clone()).or_insert(app);
            }
        }
    }
    Ok(apps)
}

fn application_dirs() -> Vec<PathBuf> {
    let mut dirs = Vec::new();
    if let Some(xdg_data_home) = env::var_os("XDG_DATA_HOME") {
        dirs.push(PathBuf::from(xdg_data_home).join("applications"));
    } else if let Some(home) = env::var_os("HOME") {
        dirs.push(PathBuf::from(&home).join(".local/share/applications"));
        dirs.push(PathBuf::from(home).join(".local/share/flatpak/exports/share/applications"));
    }
    dirs.push(PathBuf::from("/var/lib/flatpak/exports/share/applications"));
    let xdg_dirs = env::var_os("XDG_DATA_DIRS")
        .map(|v| env::split_paths(&v).collect::<Vec<_>>())
        .unwrap_or_else(|| {
            vec![
                PathBuf::from("/usr/local/share"),
                PathBuf::from("/usr/share"),
            ]
        });
    for dir in xdg_dirs {
        dirs.push(dir.join("applications"));
    }
    dirs
}

fn parse_desktop_file(path: &Path) -> Result<Option<DesktopApp>> {
    let text = std::fs::read_to_string(path).with_context(|| format!("read {}", path.display()))?;
    let mut in_entry = false;
    let mut name = None;
    let mut exec = None;
    let mut flatpak_app_id = None;
    let mut no_display = false;
    let mut hidden = false;
    let mut app_type = None;
    for raw in text.lines() {
        let line = raw.trim();
        if line.starts_with('[') && line.ends_with(']') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        match k {
            "Name" => name = Some(v.to_string()),
            "Exec" => exec = Some(v.to_string()),
            "X-Flatpak" => flatpak_app_id = Some(v.to_string()),
            "NoDisplay" => no_display = v.eq_ignore_ascii_case("true"),
            "Hidden" => hidden = v.eq_ignore_ascii_case("true"),
            "Type" => app_type = Some(v.to_string()),
            _ => {}
        }
    }
    if no_display || hidden || app_type.as_deref().is_some_and(|t| t != "Application") {
        return Ok(None);
    }
    let id = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
        .to_string();
    let name = name.unwrap_or_else(|| id.clone());
    let mut aliases = vec![id.clone(), name.clone()];
    if let Some(app_id) = &flatpak_app_id {
        aliases.push(app_id.clone());
        if let Some(last) = app_id.rsplit('.').next() {
            aliases.push(last.to_string());
        }
    }
    if let Some(last) = id.rsplit('.').next() {
        aliases.push(last.to_string());
    }
    aliases.sort_by_key(|s| (normalize_alias(s).len(), normalize_alias(s)));
    aliases.dedup_by(|a, b| normalize_alias(a) == normalize_alias(b));
    Ok(Some(DesktopApp {
        id,
        name,
        exec,
        flatpak_app_id,
        aliases,
    }))
}

fn desktop_exec_words(exec: &str) -> Result<Vec<String>> {
    Ok(shell_words::split(exec)
        .with_context(|| format!("parse desktop Exec={exec:?}"))?
        .into_iter()
        .filter(|word| !word.starts_with('%'))
        .collect())
}

fn normalize_alias(s: &str) -> String {
    s.trim_end_matches(".desktop")
        .chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Resolve the terminal's pixel size for sizing the Pixman render target.
///
/// Resolution order (first wins):
/// 1. **`cols × cell_px`** — physical pixels from the XTWINOPS `CSI 16 t` cell
///    probe ([`probe_terminal_cell_pixels`]). The reported cell size is always
///    in **physical** device pixels, so this stays sharp on HiDPI even when the
///    terminal leaves `ws_xpixel` at 0 (very common) or fills it with *logical*
///    pixels (which would make us render at half resolution and blur). This is
///    the HiDPI-correct primary path; the cache is computed once at startup and
///    reused on resize, so resizes stay cheap (no per-resize round-trip).
/// 2. **`ws_xpixel`/`ws_ypixel`** from `TIOCGWINSZ` — the terminal's direct
///    window-pixel report. Free and authoritative when the terminal populates
///    it with physical pixels; used when no cell probe was obtained.
/// 3. **`cols × 8, rows × 16`** — last-resort cell estimate. Wrong on HiDPI
///    (cells are physically larger), but better than nothing for terminals that
///    report neither pixels nor a cell size.
fn terminal_pixel_size(cell_px: Option<(u16, u16)>) -> Option<Size<i32, Logical>> {
    // TIOCGWINSZ returns both cells and pixels; cell count is always present.
    let mut winsz = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { libc::ioctl(libc::STDOUT_FILENO, libc::TIOCGWINSZ, &mut winsz) };
    if rc != 0 {
        return None;
    }
    let cols = winsz.ws_col as i32;
    let rows = winsz.ws_row as i32;

    // HiDPI-robust primary: physical pixels = cells × cell-pixel-size. The cell
    // size from CSI 16 t is device pixels, so this matches the framebuffer the
    // terminal actually draws — no 2× upscale, no blur.
    if let Some((cw, ch)) = cell_px
        && cw > 0
        && ch > 0
        && cols > 0
        && rows > 0
    {
        return Some(Size::from((cols * cw as i32, rows * ch as i32)));
    }

    if winsz.ws_xpixel > 0 && winsz.ws_ypixel > 0 {
        return Some(Size::from((winsz.ws_xpixel as i32, winsz.ws_ypixel as i32)));
    }
    if cols > 0 && rows > 0 {
        return Some(Size::from(((cols) * 8, (rows) * 16)));
    }
    None
}

/// Probe the terminal's per-cell pixel size via the XTWINOPS `CSI 16 t` query.
///
/// Writes the query to stdout (which round-trips through the Iroh relay to the
/// *client's* terminal when `zuko app` runs over a remote session) and reads
/// the `CSI 6 ; <height> ; <width> t` reply from stdin with a bounded timeout.
/// The cell size is stable across window resizes (it only changes on font
/// change), so one probe at startup feeds every later size computation.
///
/// Returns `None` if the terminal doesn't answer within the timeout (e.g. it
/// doesn't implement XTWINOPS); callers fall back to `ws_xpixel` / cell
/// estimate. Must run in raw mode (the caller enters it via `TerminalModeGuard`
/// first) so the reply arrives as raw bytes, not cooked input.
fn probe_terminal_cell_pixels(timeout: Duration) -> Option<(u16, u16)> {
    // Tunable for slow relay links: ZUKO_PIXEL_PROBE_MS overrides the default.
    let timeout = std::env::var("ZUKO_PIXEL_PROBE_MS")
        .ok()
        .and_then(|v| v.parse().ok())
        .map(Duration::from_millis)
        .unwrap_or(timeout);
    let mut out = std::io::stdout();
    let _ = out.write_all(b"\x1b[16t");
    let _ = out.flush();

    #[cfg(unix)]
    {
        set_stdin_nonblocking(true);
        let deadline = Instant::now() + timeout;
        let mut buf: Vec<u8> = Vec::with_capacity(64);
        let mut chunk = [0u8; 64];
        let mut found = None;
        while found.is_none() && Instant::now() < deadline {
            // Raw, non-blocking read on STDIN_FILENO. Returns the byte count
            // (>0), 0 on EOF, or -1/EAGAIN when nothing's queued yet.
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
                // Nothing yet — yield the CPU and retry until the deadline.
                std::thread::sleep(Duration::from_millis(3));
            }
        }
        set_stdin_nonblocking(false);
        found
    }
    #[cfg(not(unix))]
    {
        let _ = timeout;
        None
    }
}

/// Parse the XTWINOPS cell-size reply `CSI 6 ; <height> ; <width> t` out of an
/// arbitrary byte buffer. Returns `(width, height)` in pixels, or `None` if the
/// reply hasn't arrived (or is malformed). Scans the whole buffer so partial
/// reads + leading noise (other escape sequences) don't throw it off.
fn parse_cell_size_reply(buf: &[u8]) -> Option<(u16, u16)> {
    let s = std::str::from_utf8(buf).ok()?;
    let marker = "\x1b[6;";
    let after = s.split(marker).nth(1)?;
    let end = after.find('t')?;
    let mut nums = after[..end].split(';');
    // The reply puts height before width: CSI 6 ; <height> ; <width> t
    let h: u16 = nums.next()?.trim().parse().ok()?;
    let w: u16 = nums.next()?.trim().parse().ok()?;
    Some((w, h))
}

/// Toggle `O_NONBLOCK` on stdin. Used by [`probe_terminal_cell_pixels`] to read
/// the XTWINOPS reply with a deadline instead of blocking forever on terminals
/// that never answer. Restored to blocking before the crossterm event loop
/// takes over, so its reads behave normally.
#[cfg(unix)]
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

struct App {
    compositor_state: CompositorState,
    xdg_shell_state: XdgShellState,
    shm_state: ShmState,
    seat_state: SeatState<Self>,
    data_device_state: DataDeviceState,
    seat: Seat<Self>,
    output_size: Size<i32, Logical>,
    dirty: bool,
    pending_resize: bool,
    serial: u32,
}

impl App {
    fn next_serial(&mut self) -> Serial {
        self.serial = self.serial.wrapping_add(1).max(1);
        Serial::from(self.serial)
    }
}

impl BufferHandler for App {
    fn buffer_destroyed(&mut self, _buffer: &wl_buffer::WlBuffer) {}
}

impl OutputHandler for App {}

impl CompositorHandler for App {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor_state
    }

    fn client_compositor_state<'a>(&self, client: &'a Client) -> &'a CompositorClientState {
        &client
            .get_data::<ClientState>()
            .expect("Wayland client data installed")
            .compositor_state
    }

    fn commit(&mut self, surface: &WlSurface) {
        // Import/cache the committed buffer metadata. Rendering/damage tracking
        // is Phase 2+, but Smithay's render helpers expect commit handling to
        // have run for every surface buffer.
        on_commit_buffer_handler::<Self>(surface);
        self.dirty = true;
    }
}

impl XdgShellHandler for App {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell_state
    }

    fn new_toplevel(&mut self, surface: ToplevelSurface) {
        let size = self.output_size;
        surface.with_pending_state(|state| {
            state.size = Some(size);
            state.bounds = Some(size);
            state.states.set(xdg_toplevel::State::Activated);
            // NOT Fullscreen: browsers (Vivaldi/Firefox) and GNOME Text Editor
            // hide their tab bar / title bar in fullscreen, so the hosted app
            // would lose its chrome. A plain Activated window sized to the
            // output fills the terminal while keeping client-side decorations.
        });
        surface.send_configure();
        self.dirty = true;
    }

    fn new_popup(&mut self, _surface: PopupSurface, _positioner: PositionerState) {}

    fn grab(&mut self, _surface: PopupSurface, _seat: wl_seat::WlSeat, _serial: Serial) {}

    fn reposition_request(
        &mut self,
        _surface: PopupSurface,
        _positioner: PositionerState,
        _token: u32,
    ) {
    }
}

impl ShmHandler for App {
    fn shm_state(&self) -> &ShmState {
        &self.shm_state
    }
}

impl SeatHandler for App {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }

    fn focus_changed(&mut self, _seat: &Seat<Self>, _focused: Option<&WlSurface>) {}

    fn cursor_image(
        &mut self,
        _seat: &Seat<Self>,
        _image: smithay::input::pointer::CursorImageStatus,
    ) {
    }
}

impl SelectionHandler for App {
    type SelectionUserData = ();
}

impl DataDeviceHandler for App {
    fn data_device_state(&self) -> &DataDeviceState {
        &self.data_device_state
    }
}

impl ClientDndGrabHandler for App {}

impl ServerDndGrabHandler for App {
    fn send(&mut self, _mime_type: String, _fd: OwnedFd, _seat: Seat<Self>) {}
}

#[derive(Default)]
struct ClientState {
    compositor_state: CompositorClientState,
}

impl ClientData for ClientState {
    fn initialized(&self, client_id: ClientId) {
        tracing::debug!(?client_id, "Wayland client initialized");
    }

    fn disconnected(&self, client_id: ClientId, reason: DisconnectReason) {
        tracing::debug!(?client_id, ?reason, "Wayland client disconnected");
    }
}

delegate_xdg_shell!(App);
delegate_compositor!(App);
delegate_shm!(App);
delegate_seat!(App);
delegate_data_device!(App);
delegate_output!(App);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_bad_runtime_options() {
        let mut args = AppArgs {
            list: false,
            dry_run: false,
            test_pattern: false,
            debug_child: false,
            fps: 0,
            scale: 1.0,
            software: false,
            no_sandbox: false,
            command: vec!["firefox".into()],
        };
        assert!(validate_args(&args).is_err());
        args.fps = 8;
        args.scale = 0.0;
        assert!(validate_args(&args).is_err());
        args.scale = 1.0;
        assert!(validate_args(&args).is_ok());
    }

    #[test]
    fn parses_xtwinops_cell_size_reply() {
        // XTWINOPS CSI 16 t reply is `CSI 6 ; <height> ; <width> t` — note the
        // height-before-width order. Returns (width, height).
        assert_eq!(parse_cell_size_reply(b"\x1b[6;32;16t"), Some((16, 32)));
    }

    #[test]
    fn parses_cell_size_reply_amid_leading_noise() {
        // The probe reads raw stdin; other escape sequences (or a fragment of
        // one) can land before the reply. The parser must scan past them.
        let buf = b"\x1b[?1003h\x1b[6;40;20t";
        assert_eq!(parse_cell_size_reply(buf), Some((20, 40)));
    }

    #[test]
    fn cell_size_reply_none_until_complete() {
        // A partial reply (no trailing `t`) must not parse — the probe loop
        // keeps reading until the full reply arrives or the deadline hits.
        assert_eq!(parse_cell_size_reply(b"\x1b[6;40;20"), None);
        assert_eq!(parse_cell_size_reply(b""), None);
    }

    #[test]
    fn cell_size_reply_rejects_garbage() {
        // Malformed numbers / wrong shape → None, not a panic.
        assert_eq!(parse_cell_size_reply(b"\x1b[6;abc;def t"), None);
        assert_eq!(parse_cell_size_reply(b"not a reply at all"), None);
    }
}
