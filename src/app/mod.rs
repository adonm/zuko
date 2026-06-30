//! `zuko app` — host one Wayland GUI app in a terminal.
//!
//! Rather than being a Wayland compositor ourselves (the old in-process
//! Smithay kiosk, which had to *guess* the terminal's pixel size and kept
//! rendering into the wrong-sized buffer — the "only the top-left corner is
//! visible, with padding" bug), we spawn **[cage](https://github.com/cage-kiosk/cage)**,
//! a mature wlroots kiosk, headless in pure software
//! (`WLR_BACKENDS=headless WLR_RENDERER=pixman` — no GPU), and talk to it as a
//! Wayland **client** over its private socket:
//!
//! - `zwlr_screencopy_manager_v1` to pull frames at cage's output resolution;
//! - `zwp_virtual_keyboard_manager_v1` / `zwlr_virtual_pointer_manager_v1`
//!   to inject input (Phase 2).
//!
//! Sizing is solved by construction: zuko chooses the terminal's pixel geometry
//! (bounded by a safety cap), asks cage to use it via wlr-output-management,
//! and reconfigures cage when the terminal is resized.

use anyhow::{Context, Result, bail};
use crossterm::{
    cursor::Hide,
    event::{DisableMouseCapture, EnableMouseCapture},
    execute,
    terminal::EnterAlternateScreen,
};
use std::{collections::BTreeMap, env, io::Write, path::PathBuf};

use crate::{AppArgs, KittyGraphicsCodec};

#[cfg(target_os = "linux")]
mod imp;

#[cfg(target_os = "linux")]
pub use imp::run;

// ─────────────────────── non-Linux stub ────────────────────────────────────
// `zuko app` is Linux-only. On other platforms we expose the subcommand but it
// errors clearly, so the CLI parser/help is identical everywhere.
#[cfg(not(target_os = "linux"))]
pub fn run(_args: AppArgs) -> Result<()> {
    bail!(
        "`zuko app` is Linux-only (it spawns cage + wlr-screencopy). Run it on Linux; at runtime it needs cage/wlroots plus Wayland runtime libraries."
    )
}

#[cfg(target_os = "linux")]
const DEFAULT_WIDTH_PX: i32 = 1280;
#[cfg(target_os = "linux")]
const DEFAULT_HEIGHT_PX: i32 = 720;
#[cfg(target_os = "linux")]
const DEFAULT_OUTPUT: (i32, i32) = (DEFAULT_WIDTH_PX, DEFAULT_HEIGHT_PX);

// ───────────────────────────── Kitty graphics ───────────────────────────────
// Reused verbatim from the old in-process renderer: encode a frame to a fast
// PNG and emit it via the Kitty graphics protocol. Cage's screencopy gives us
// an RGBA buffer; these functions turn it into terminal pixels.

/// Encode an RGBA frame to a fast-compressed PNG for the Kitty graphics
/// protocol. Expects tightly-packed rows (`bytes.len() == width * 4 * height`).
fn encode_rgba_png(
    bytes: &[u8],
    width: usize,
    height: usize,
    filter: png::Filter,
) -> Result<Vec<u8>> {
    let row_bytes = width * 4;
    if height == 0 || row_bytes == 0 {
        bail!("empty frame {width}x{height}");
    }
    if bytes.len() < row_bytes * height {
        bail!(
            "frame too small: {} bytes for {width}x{height} RGBA (need {})",
            bytes.len(),
            row_bytes * height
        );
    }
    let mut out = Vec::new();
    let mut encoder = png::Encoder::new(&mut out, width as u32, height as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.set_compression(png::Compression::Fast);
    // Paeth is best for mostly-static UI; NoFilter is cheaper for high-entropy
    // video-like frames where filtering rarely improves zlib output. The caller
    // picks per-frame from a cheap sampler.
    encoder.set_filter(filter);
    {
        let mut writer = encoder.write_header()?;
        writer.write_image_data(bytes)?;
    }
    Ok(out)
}

/// Convert tightly-packed RGBA to raw RGB for Kitty `f=24`. This avoids PNG
/// filtering/zlib entirely, which is much cheaper for high-entropy video-like
/// frames and often ships fewer bytes than PNG once the PNG no longer
/// compresses well.
fn encode_rgba_rgb(bytes: &[u8], width: usize, height: usize) -> Result<Vec<u8>> {
    let row_bytes = width * 4;
    if height == 0 || row_bytes == 0 {
        bail!("empty frame {width}x{height}");
    }
    if bytes.len() < row_bytes * height {
        bail!(
            "frame too small: {} bytes for {width}x{height} RGBA (need {})",
            bytes.len(),
            row_bytes * height
        );
    }
    let mut out = Vec::with_capacity(width * height * 3);
    for px in bytes[..row_bytes * height].chunks_exact(4) {
        out.extend_from_slice(&px[..3]);
    }
    Ok(out)
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum KittyGraphicsFormat {
    Png,
    Rgb,
}

impl KittyGraphicsFormat {
    fn code(self) -> u16 {
        match self {
            Self::Png => 100,
            Self::Rgb => 24,
        }
    }
}

#[derive(Debug)]
struct KittyFramePayload {
    format: KittyGraphicsFormat,
    bytes: Vec<u8>,
}

impl KittyFramePayload {
    fn transport_bytes(&self) -> usize {
        kitty_transport_bytes(self.bytes.len())
    }
}

fn encode_test_pattern_payload(
    width: usize,
    height: usize,
    codec: KittyGraphicsCodec,
) -> Result<KittyFramePayload> {
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
    match codec {
        KittyGraphicsCodec::Rgb => Ok(KittyFramePayload {
            format: KittyGraphicsFormat::Rgb,
            bytes: encode_rgba_rgb(&pixels, width, height)?,
        }),
        KittyGraphicsCodec::Auto | KittyGraphicsCodec::Png => Ok(KittyFramePayload {
            format: KittyGraphicsFormat::Png,
            bytes: encode_rgba_png(&pixels, width, height, png::Filter::NoFilter)?,
        }),
    }
}

fn kitty_clear_screen() -> Result<()> {
    let mut out = std::io::stdout();
    out.write_all(b"\x1b[2J\x1b[H")?;
    out.flush()?;
    Ok(())
}

fn kitty_emit_frame(
    width: u32,
    height: u32,
    format: KittyGraphicsFormat,
    data: &[u8],
    place: bool,
    // (span_cols, span_rows, off_col, off_row): aspect-preserving cell
    // rectangle + centering offset for letterboxed display.
    placement: Option<(u32, u32, u32, u32)>,
) -> Result<()> {
    use base64::Engine as _;
    const CHUNK: usize = 4096;
    let encoded = base64::engine::general_purpose::STANDARD.encode(data);
    let mut out = std::io::stdout();
    let format = format.code();
    if place {
        // A resize re-places the image with a new c=/r= cell rectangle. Some
        // terminals keep the old placement alive when another a=T with the same
        // image id is emitted, which shows up as a "double image" after resize.
        // Delete id=1 first; harmless on the initial frame, and a=t updates
        // below continue to reuse the single fresh placement.
        out.write_all(b"\x1b_Ga=d,i=1,q=2\x1b\\")?;
    }
    // Position the cursor at the letterbox offset (1-indexed) so the image is
    // centered; home if no placement. Harmless on `a=t` updates (they target
    // the existing placement by id, not the cursor).
    match placement {
        Some((_, _, off_col, off_row)) => write!(out, "\x1b[{};{}H", off_row + 1, off_col + 1)?,
        None => out.write_all(b"\x1b[H")?,
    }
    // Place (a=T) only on the first frame; subsequent frames transmit data
    // only (a=t) so the single existing placement updates in place.
    let action = if place { "a=T,C=1" } else { "a=t" };
    // On the placing frame, pin the display to the aspect-preserving cell
    // rectangle (c=,r=). Kitty scales the source to span that many cells;
    // because the rectangle matches the source's aspect (computed by the
    // caller), there's no stretch — just letterbox bars around it.
    let cell_rect = match (place, placement) {
        (true, Some((span_cols, span_rows, _, _))) => format!(",c={span_cols},r={span_rows}"),
        _ => String::new(),
    };
    let chunks = encoded.as_bytes().chunks(CHUNK).collect::<Vec<_>>();
    for (i, chunk) in chunks.iter().enumerate() {
        let more = usize::from(i + 1 < chunks.len());
        if i == 0 {
            write!(
                out,
                "\x1b_G{action},f={format},t=d,i=1,q=2,s={width},v={height}{cell_rect},m={more};"
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

fn kitty_transport_bytes(data_bytes: usize) -> usize {
    let base64 = data_bytes.div_ceil(3) * 4;
    // Kitty chunks add a small escape/control overhead. This is intentionally
    // approximate; frame pacing only needs the right order of magnitude.
    base64 + base64.div_ceil(4096) * 64
}

// ─────────────────────────── terminal mode guard ────────────────────────────

struct TerminalModeGuard {
    /// Whether SGR-pixel mouse (mode 1016) was enabled — only when the caller
    /// confirmed the terminal reports pixel coords (so we can map clicks with
    /// sub-cell precision). Tracked so Drop disables exactly what was enabled.
    pixel_mouse: bool,
}

impl TerminalModeGuard {
    fn enter() -> Result<Self> {
        crossterm::terminal::enable_raw_mode().context("enable raw terminal mode")?;
        let mut out = std::io::stdout();
        execute!(out, EnterAlternateScreen, Hide, EnableMouseCapture)
            .context("enable terminal app screen/mouse mode")?;
        // All-motion (1003) + SGR (1006) cell encoding. 1016 (SGR-pixel) is
        // enabled later by [`Self::enable_pixel_mouse`] only once the caller
        // knows the terminal's pixel geometry, so the coord unit always matches
        // the mapping.
        out.write_all(b"\x1b[?1003h\x1b[?1006h")
            .context("enable SGR mouse modes")?;
        out.flush().context("flush terminal app mode setup")?;
        Ok(Self { pixel_mouse: false })
    }

    /// Switch mouse reporting from cell coords (1006) to pixel coords (1016).
    /// Call only after confirming pixel geometry is available, so the click
    /// mapping and the crosshair are pixel-accurate instead of cell-quantized.
    fn enable_pixel_mouse(&mut self) -> Result<()> {
        self.pixel_mouse = true;
        let mut out = std::io::stdout();
        out.write_all(b"\x1b[?1016h")?;
        out.flush()?;
        Ok(())
    }
}

impl Drop for TerminalModeGuard {
    fn drop(&mut self) {
        // Restore in one buffered write + single flush so the terminal applies
        // the whole sequence in one render pass (no intermediate blank-alt-screen
        // flicker on exit). Order: leave the alt screen first (back to the
        // shell), THEN clear the Kitty image — Kitty placements persist across
        // the screen-buffer switch, so clearing after leaves the shell clean.
        let mut buf = Vec::with_capacity(64);
        use std::io::Write as _;
        let _ = buf.write_all(b"\x1b[?1049l"); // LeaveAlternateScreen
        let _ = buf.write_all(b"\x1b_Ga=d,q=2\x1b\\"); // delete Kitty placements
        if self.pixel_mouse {
            let _ = buf.write_all(b"\x1b[?1016l");
        }
        let _ = buf.write_all(b"\x1b[?1006l\x1b[?1003l"); // disable SGR mouse modes
        let _ = buf.write_all(b"\x1b[?25h"); // Show cursor
        let mut out = std::io::stdout();
        let _ = out.write_all(&buf);
        let _ = out.flush();
        let _ = execute!(out, DisableMouseCapture);
        let _ = crossterm::terminal::disable_raw_mode();
        let _ = out.flush();
    }
}

// ──────────────────────────────── arg validation ────────────────────────────

fn validate_args(args: &AppArgs) -> Result<()> {
    if args.command.is_empty() && !args.list && !args.test_pattern && !args.doctor {
        bail!("missing app command");
    }
    if args.fps == 0 {
        bail!("--fps must be at least 1");
    }
    if !args.scale.is_finite() || args.scale <= 0.0 {
        bail!("--scale must be a positive finite number");
    }
    if !args.max_mbps.is_finite() || args.max_mbps < 0.0 {
        bail!("--max-mbps must be a non-negative finite number");
    }
    Ok(())
}

// ─────────────────────── app launch resolution (reused) ─────────────────────
// `zuko <host>` runs `zuko app <alias>` on the host; the alias resolves to a
// .desktop entry (Flatpak or plain). This is unchanged from before: we still
// need to know *what* to launch, only the *how* (cage spawns it) changed.

#[derive(Clone, Debug)]
struct Launch {
    label: String,
    program: String,
    args: Vec<String>,
    env: Vec<(String, String)>,
    flatpak: bool,
    profile: DisplayProfile,
    fallback: Option<Box<Launch>>,
}

/// The two cage display backends `zuko app` knows how to drive. Selection is
/// not per-app guesswork: we start on the cheapest (`Wayland`) and only switch
/// to `Xwayland` if the app never rendered (the classic Electron/Chromium
/// "black screen under headless pixman"). Everything else — software GL, video
/// decode, backend hints — is driven by env, not app-specific CLI flags (those
/// caused their own crashes, e.g. Discord with `--use-gl=disabled`).
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum DisplayProfile {
    Wayland,
    Xwayland,
}

impl DisplayProfile {
    fn label(self) -> &'static str {
        match self {
            Self::Wayland => "Wayland/software",
            Self::Xwayland => "Xwayland/software",
        }
    }
}

const DISPLAY_FALLBACKS: &[DisplayProfile] = &[DisplayProfile::Wayland, DisplayProfile::Xwayland];

fn fallback_chain(mut mk: impl FnMut(DisplayProfile) -> Launch) -> Launch {
    let mut next = None;
    for &profile in DISPLAY_FALLBACKS.iter().rev() {
        let mut launch = mk(profile);
        launch.fallback = next;
        next = Some(Box::new(launch));
    }
    *next.expect("DISPLAY_FALLBACKS is non-empty")
}

fn resolve_launch(args: &AppArgs, software: bool, no_sandbox: bool) -> Result<Launch> {
    let (query, child_args) = args.command.split_first().context("missing app command")?;
    if let Some(entry) = find_desktop_app(query)? {
        if let Some(app_id) = entry.flatpak_app_id.as_deref() {
            return Ok(flatpak_launch_chain(
                &entry.name,
                app_id,
                child_args,
                software,
                no_sandbox,
            ));
        }
        if let Some(exec) = entry.exec.as_deref() {
            let mut words = desktop_exec_words(exec)?;
            if !words.is_empty() {
                let program = words.remove(0);
                return Ok(command_launch_chain(
                    entry.name, program, words, child_args, software, no_sandbox,
                ));
            }
        }
    }

    Ok(command_launch_chain(
        query.clone(),
        query.clone(),
        Vec::new(),
        child_args,
        software,
        no_sandbox,
    ))
}

fn flatpak_launch_chain(
    name: &str,
    app_id: &str,
    child_args: &[String],
    software: bool,
    no_sandbox: bool,
) -> Launch {
    fallback_chain(|profile| {
        let env = app_env(software, no_sandbox, profile);
        let args = flatpak_run_args(app_id, child_args, &env, profile);
        Launch {
            label: format!("{name} ({app_id}, {})", profile.label()),
            program: "flatpak".to_string(),
            args,
            env,
            flatpak: true,
            profile,
            fallback: None,
        }
    })
}

fn command_launch_chain(
    label: String,
    program: String,
    base_args: Vec<String>,
    child_args: &[String],
    software: bool,
    no_sandbox: bool,
) -> Launch {
    fallback_chain(|profile| {
        let mut args = base_args.clone();
        args.extend(child_args.iter().cloned());
        Launch {
            label: format!("{label} ({})", profile.label()),
            program: program.clone(),
            args,
            env: app_env(software, no_sandbox, profile),
            flatpak: false,
            profile,
            fallback: None,
        }
    })
}

fn flatpak_run_args(
    app_id: &str,
    child_args: &[String],
    env: &[(String, String)],
    profile: DisplayProfile,
) -> Vec<String> {
    let mut flatpak_args = vec![
        "run".to_string(),
        // Keep the sandbox attached to cage's lifecycle and Wayland socket.
        "--die-with-parent".to_string(),
        "--share=ipc".to_string(),
        // No host AT-SPI/a11y bus exists inside headless cage.
        "--no-a11y-bus".to_string(),
    ];
    match profile {
        DisplayProfile::Xwayland => {
            // DISPLAY is supplied by cage's Xwayland bridge, so app_env
            // intentionally does not pass --env=DISPLAY= in this mode.
            flatpak_args.push("--socket=x11".to_string());
            flatpak_args.push("--nosocket=wayland".to_string());
            flatpak_args.push("--nosocket=fallback-x11".to_string());
        }
        DisplayProfile::Wayland => {
            flatpak_args.push("--socket=wayland".to_string());
            // Wayland-only: X11 fallback can silently choose the wrong display
            // path or fail later in less obvious ways, so make it explicit.
            flatpak_args.push("--nosocket=x11".to_string());
            flatpak_args.push("--nosocket=fallback-x11".to_string());
        }
    }
    for (k, v) in env {
        flatpak_args.push(format!("--env={k}={v}"));
    }
    flatpak_args.push(app_id.to_string());
    flatpak_args.extend(child_args.iter().cloned());
    flatpak_args
}

/// Environment that points the child app at the right backend under cage and
/// forces software rendering/decoding (cage is headless pixman — there is no
/// GPU). cage sets `WAYLAND_DISPLAY`/`DISPLAY` for its child; we only add the
/// tunables.
fn app_env(software: bool, no_sandbox: bool, profile: DisplayProfile) -> Vec<(String, String)> {
    let wayland = profile == DisplayProfile::Wayland;
    let mut env = vec![
        (
            "MOZ_ENABLE_WAYLAND".to_string(),
            if wayland { "1" } else { "0" }.to_string(),
        ),
        (
            "GDK_BACKEND".to_string(),
            if wayland { "wayland" } else { "x11" }.to_string(),
        ),
        (
            "QT_QPA_PLATFORM".to_string(),
            if wayland { "wayland" } else { "xcb" }.to_string(),
        ),
        (
            "ELECTRON_OZONE_PLATFORM_HINT".to_string(),
            if wayland { "wayland" } else { "x11" }.to_string(),
        ),
        // cage's headless output has NO GPU (pixman, software-only), so force
        // every toolkit onto its software renderer up front. Without this, GTK4
        // probes Vulkan/EGL and spews `VK_ERROR_SURFACE_LOST_KHR`, `libEGL …`,
        // `MESA-LOADER …` warnings before falling back — noisy and pointless,
        // since there's no GPU to use.
        ("GSK_RENDERER".to_string(), "cairo".to_string()), // GTK4 scene kit
        ("LIBGL_ALWAYS_SOFTWARE".to_string(), "1".to_string()), // Mesa → llvmpipe
        ("QT_OPENGL".to_string(), "software".to_string()),
        ("QT_QUICK_BACKEND".to_string(), "software".to_string()), // QtQuick
        ("QSG_RHI_BACKEND".to_string(), "software".to_string()),  // Qt 6 scenegraph
        // QtWebEngine/Chromium-based Flatpaks (notably Jellyfin Media Player /
        // Jellyfin Desktop) can show black video under cage's pixman/headless
        // renderer when they create accelerated EGL/shared-image/dmabuf video
        // surfaces. Disable those paths so video is composited into the normal
        // Wayland surface that wlr-screencopy can capture. Throughput is CPU
        // bound, but correctness beats a black rectangle.
        (
            "QTWEBENGINE_CHROMIUM_FLAGS".to_string(),
            [
                "--disable-gpu",
                "--disable-gpu-compositing",
                "--disable-accelerated-video-decode",
                "--disable-accelerated-video-encode",
                "--disable-features=VaapiVideoDecoder,VaapiVideoEncoder,Vulkan,UseSkiaRenderer",
                "--use-gl=disabled",
            ]
            .join(" "),
        ),
        // Make VAAPI/VDPAU probing fail closed in sandboxed media players. Some
        // libmpv/CEF paths ignore Chromium flags and still try hardware decode;
        // empty driver names keep them from binding a host GPU behind cage.
        ("LIBVA_DRIVER_NAME".to_string(), String::new()),
        ("VDPAU_DRIVER".to_string(), String::new()),
        // Keep file/save dialogs IN cage (so they're captured + shown in the
        // TUI) instead of delegated to the host's xdg-desktop-portal, which
        // would pop them up on the host's own desktop. GTK_USE_PORTAL=0 makes
        // GTK use its in-process FileChooserDialog (rendered into the app's
        // cage surface). NOTE: Flatpaks mandate the portal regardless, so
        // sandboxed apps still route dialogs to the host desktop.
        ("GTK_USE_PORTAL".to_string(), "0".to_string()), // GTK in-process dialogs
        // The app runs in a private cage/D-Bus session where the host IBus/a11y
        // daemons are often unavailable. GTK text widgets otherwise pick IBus,
        // fail to create an input context, and can drop ordinary key input
        // (notably GNOME Text Editor). Use GTK's built-in simple IM instead.
        (
            "GTK_IM_MODULE".to_string(),
            "gtk-im-context-simple".to_string(),
        ),
        ("QT_IM_MODULE".to_string(), String::new()),
        ("XMODIFIERS".to_string(), "@im=none".to_string()),
        // In a headless cage session there is no GNOME settings daemon or AT-SPI
        // bus. Keep GTK/GSettings local to the process and disable a11y bridge
        // probing so startup doesn't depend on host desktop services.
        ("GSETTINGS_BACKEND".to_string(), "memory".to_string()),
        ("NO_AT_BRIDGE".to_string(), "1".to_string()),
    ];
    if wayland {
        // Blank DISPLAY so a Wayland-mode app can't silently fall onto X11; in
        // Xwayland mode cage provides DISPLAY and we leave it intact.
        env.push(("DISPLAY".to_string(), String::new()));
    }
    // Firefox WebRender is a separate perf choice (software WR is slower), so it
    // stays opt-in behind --software unlike the toolkit renderers above.
    if software {
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

// ──────────────────────────── .desktop discovery (reused) ───────────────────

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

fn parse_desktop_file(path: &std::path::Path) -> Result<Option<DesktopApp>> {
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

fn shell_join<'a>(parts: impl Iterator<Item = &'a String>) -> String {
    parts
        .map(|s| shell_words::quote(s).into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

fn print_launch(launch: &Launch) {
    println!("label: {}", launch.label);
    println!(
        "kind:  {}",
        if launch.flatpak { "flatpak" } else { "command" }
    );
    if !launch.env.is_empty() {
        println!("env:");
        for (k, v) in &launch.env {
            println!("  {k}={v:?}");
        }
    }
    println!("argv:");
    println!(
        "  cage -- {}",
        shell_join(std::iter::once(&launch.program).chain(launch.args.iter()))
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flatpak_launch_is_wayland_only_and_cage_lifecycle_bound() {
        let env = vec![
            ("GDK_BACKEND".to_string(), "wayland".to_string()),
            ("DISPLAY".to_string(), String::new()),
        ];
        let child_args = vec!["--new-window".to_string()];
        let args = flatpak_run_args(
            "org.example.App",
            &child_args,
            &env,
            DisplayProfile::Wayland,
        );

        assert!(args.contains(&"run".to_string()));
        assert!(args.contains(&"--die-with-parent".to_string()));
        assert!(args.contains(&"--socket=wayland".to_string()));
        assert!(args.contains(&"--share=ipc".to_string()));
        assert!(args.contains(&"--nosocket=x11".to_string()));
        assert!(args.contains(&"--nosocket=fallback-x11".to_string()));
        assert!(args.contains(&"--no-a11y-bus".to_string()));
        assert!(!args.contains(&"--socket=fallback-x11".to_string()));
        assert!(args.contains(&"--env=GDK_BACKEND=wayland".to_string()));
        assert!(args.contains(&"--env=DISPLAY=".to_string()));
        assert_eq!(args[args.len() - 2], "org.example.App");
        assert_eq!(args[args.len() - 1], "--new-window");
    }

    #[test]
    fn app_env_forces_software_rendering_and_video_decode() {
        let env = app_env(false, false, DisplayProfile::Wayland);
        let value = |key: &str| {
            env.iter()
                .find_map(|(k, v)| (k == key).then_some(v.as_str()))
                .unwrap_or("")
        };

        assert_eq!(value("QT_OPENGL"), "software");
        assert_eq!(value("QSG_RHI_BACKEND"), "software");
        assert_eq!(value("LIBGL_ALWAYS_SOFTWARE"), "1");
        assert!(value("QTWEBENGINE_CHROMIUM_FLAGS").contains("--disable-gpu"));
        assert!(value("QTWEBENGINE_CHROMIUM_FLAGS").contains("VaapiVideoDecoder"));
        assert_eq!(value("LIBVA_DRIVER_NAME"), "");
        assert_eq!(value("VDPAU_DRIVER"), "");
        assert_eq!(value("DISPLAY"), "");
        assert_eq!(value("ELECTRON_OZONE_PLATFORM_HINT"), "wayland");
    }

    #[test]
    fn xwayland_profile_uses_x11_socket_and_x11_hints() {
        let env = app_env(false, false, DisplayProfile::Xwayland);
        let value = |key: &str| {
            env.iter()
                .find_map(|(k, v)| (k == key).then_some(v.as_str()))
                .unwrap_or("")
        };
        assert_eq!(value("GDK_BACKEND"), "x11");
        assert_eq!(value("QT_QPA_PLATFORM"), "xcb");
        assert_eq!(value("ELECTRON_OZONE_PLATFORM_HINT"), "x11");
        // No blanked DISPLAY in Xwayland mode — cage supplies it.
        assert!(!env.iter().any(|(k, v)| k == "DISPLAY" && v.is_empty()));

        let args = flatpak_run_args("com.example.App", &[], &env, DisplayProfile::Xwayland);
        assert!(args.contains(&"--socket=x11".to_string()));
        assert!(args.contains(&"--nosocket=wayland".to_string()));
        assert!(!args.contains(&"--socket=wayland".to_string()));
        // No app-specific Chromium CLI flags are injected (they caused their own
        // crashes); backend + env drive everything.
        assert!(!args.iter().any(|a| a.starts_with("--use-gl")));
        assert_eq!(args[args.len() - 1], "com.example.App");
    }

    #[test]
    fn launch_has_two_step_wayland_then_xwayland_fallback() {
        let launch = flatpak_launch_chain("Example", "org.example.App", &[], false, false);
        assert_eq!(launch.profile, DisplayProfile::Wayland);
        let fallback = launch.fallback.as_ref().expect("xwayland fallback");
        assert_eq!(fallback.profile, DisplayProfile::Xwayland);
        assert!(fallback.fallback.is_none());
    }
}
