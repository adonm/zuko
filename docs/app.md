# `zuko app`

Linux-only GUI app streaming. Run inside an existing `zuko <host>` shell.

Implementation: host spawns headless cage/wlroots, captures frames, writes Kitty
graphics to stdout, and injects keyboard/mouse input back into cage.

## Quick use

```sh
zuko app --list
zuko app text-editor
zuko app firefox
zuko app --fps 5 -- firefox --new-window
```

Flags go before the child command. Use `--` before child flags.

## Diagnostics

Run in this order:

```sh
zuko app --test-pattern
zuko app --doctor
zuko app --dry-run firefox
zuko app --debug-child firefox
```

If `--test-pattern` fails, fix terminal Kitty graphics or the zuko PTY path
before debugging cage/app launch.

## Flags

| Flag | Default | Notes |
|------|---------|-------|
| `--list` | — | list aliases |
| `--dry-run` | — | print launch command/env |
| `--test-pattern` | — | draw Kitty test image; no cage |
| `--doctor` | — | check cage/protocol/geometry |
| `--debug-child` | — | let child stdout/stderr through |
| `--no-sandbox` | — | browser/container escape hatch |
| `--no-cursor` | — | hide crosshair cursor overlay |
| `--fps` | `30` | max frame rate |
| `--max-mbps` | `80` | approximate graphics bandwidth cap; `0` disables |
| `--graphics-codec` | `auto` | `auto`, `png`, `rgb` |
| `--scale` | `1.0` | render below/above terminal pixel size |
| `--software` | — | force software GL/WebRender in child |

## Flatpak

Flatpak launches are Wayland-only cage children with `--die-with-parent`. zuko
detects exported Flatpaks and simple `Exec=flatpak run <app-id> ...` desktop
files.

Portal-heavy/full-desktop flows: run an RDP client inside `zuko app` and connect
to GNOME/KDE RDP on the host.

## Runtime deps

x86_64 Linux release tarballs bundle cage plus uncommon wlroots libs next to the
`zuko` binary. Lookup order:

1. `<exe_dir>/cage/`
2. `~/.local/share/zuko/cage`
3. `PATH`
4. `$ZUKO_CAGE`

Not bundled: `libwayland`, `libxkbcommon`, `libdrm`, `libxcb`, `libinput`,
`libudev`, mesa `libEGL`/`libGLESv2`.

aarch64 Linux currently needs `cage` on `PATH`.
