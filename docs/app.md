# `zuko app` — GUI-app streaming (Linux only)

`zuko app` runs one Wayland GUI app under a headless
[cage](https://github.com/cage-kiosk/cage) compositor on the host and streams its
frames back into your existing terminal session via the
[Kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/).
No second listener, port, pairing flow, or desktop client — the frames are
just terminal output over the already-authenticated Iroh session. Run it from
inside an ordinary `zuko <host>` shell.

Why Kitty graphics (not a custom video protocol) is the baseline transport is
argued in [`design.md`](design.md). This page is the operator reference.

## Quick start

```sh
zuko app --list                       # discover desktop/Flatpak aliases
zuko app text-editor                  # run an alias
zuko app firefox                      # run a binary
zuko app --fps 5 -- firefox --new-window   # flags before the command; -- separates child args
```

Defaults favor terminal interop: cage is sized to the terminal's pixel
geometry, resizes are followed when cage exposes output-management, unchanged
frames are skipped, and `--graphics-codec auto` uses PNG for UI/static frames
or raw Kitty RGB for high-entropy video-like frames.

## Diagnostics workflow

When a GUI app shows a blank screen or the image path looks broken, run these
in order — each proves one layer before the next:

```sh
zuko app --test-pattern          # 1. Kitty graphics survive the terminal + zuko PTY path (no cage)
zuko app --doctor                # 2. cage, Wayland protocols, terminal geometry are sound (no app)
zuko app --dry-run firefox       # 3. resolved launch command/env without starting the compositor
zuko app --debug-child firefox   # 4. let child stdout/stderr reach the terminal (normally suppressed)
```

`--test-pattern` draws a generated image and exits without touching cage. If
that fails, the problem is your terminal's Kitty-graphics support or the zuko
PTY path — not the app or the compositor.

## Flags

| Flag | Default | Notes |
|------|---------|-------|
| `--list` | — | List discoverable desktop/Flatpak aliases and exit. |
| `--dry-run` | — | Print the resolved launch command/env and exit without starting cage. |
| `--test-pattern` | — | Draw a Kitty graphics test pattern and exit (no cage/Wayland). First diagnostic. |
| `--doctor` | — | Check runtime capabilities (cage, Wayland protocols, terminal geometry) and exit. |
| `--debug-child` | — | Let child stdout/stderr write to the terminal (normally suppressed so they don't corrupt the graphics stream). |
| `--no-sandbox` | — | Disable common browser subprocess sandboxes. Use when Firefox logs `clone() failure: EPERM` in a container. |
| `--no-cursor` | — | Hide the pointer crosshair overlay. Captured frames have no compositor cursor; the default crosshair helps aim touch/imprecise clicks. |
| `--fps` | `30` | Max terminal frame ship rate. Adapts down on unchanged frames or slow encode/output. |
| `--max-mbps` | `80` | Approximate max Kitty-graphics bandwidth in Mbit/s. Adapts FPS down when full-motion frames exceed it. `0` disables the cap. |
| `--graphics-codec` | `auto` | `auto` (PNG for UI, raw RGB for video-like), `png`, or `rgb`. |
| `--scale` | `1.0` | Scale multiplier for the hosted app output relative to terminal pixels. `<1.0` renders below terminal resolution (less bandwidth). |
| `--software` | — | Force software rendering in the child (`MOZ_WEBRENDER=software`, `LIBGL_ALWAYS_SOFTWARE=1`, …). Cage already renders headless with pixman. |

Put zuko-app flags **before** the command; use `--` before child flags.

## Flatpak aliases

Flatpak aliases launch as Wayland-only cage children (`--socket=wayland`, no
X11 fallback, `--die-with-parent`). Portals still belong to the host desktop
session. For portal-heavy or full-desktop workflows, run an RDP client inside
`zuko app` (e.g. `zuko app remmina` or `zuko app krdc`) and connect it to
GNOME/KDE's built-in RDP server.

## Runtime dependencies

`mise use --global github:adonm/zuko` bundles **cage** + the uncommon wlroots
libs (`libwlroots-0.20.so`, `libliftoff.so.0`, `libseat.so.1`,
`libxcb-errors.so.0`) in a `cage/` dir next to the `zuko` binary on
**x86_64-linux** — no extra setup. zuko finds it exe-relative
(`<exe_dir>/cage/`), falling back to `~/.local/share/zuko/cage`, a `cage` on
`PATH`, or `$ZUKO_CAGE`.

Not bundled (present on any host that runs GUI apps, but worth knowing on a
truly minimal/headless server): `libwayland`, `libxkbcommon`, `libdrm`,
`libxcb`, `libinput`, `libudev`, mesa's `libEGL`/`libGLESv2`.

**aarch64-linux:** cage is not yet bundled (CI needs QEMU for the cross
build). `zuko app` requires a `cage` on `PATH` there until that lands. See
[`releasing.md`](releasing.md#zuko-app-linux-only).

## License

Apache-2.0. See [`../LICENSE`](https://github.com/adonm/zuko/blob/main/LICENSE).
