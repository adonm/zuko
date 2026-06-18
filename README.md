# zuko

A minimal iOS terminal app that lets you shell into your own Mac/Linux box over
[Iroh](https://www.iroh.computer/) (dial-by-key, end-to-end encrypted, no open
ports or port forwarding needed), rendered with
[SwiftTerm](https://github.com/migueldeicaza/SwiftTerm).

Home: <https://zuko.adonm.dev> · Source: <https://github.com/adonm/zuko>

```
 iPhone                                your host
┌──────────────┐      Iroh (E2E)     ┌──────────────────┐
│  Zuko app    │  <----------------> │  zuko-host daemon │
│  SwiftTerm   │   bidi stream +     │  PTY + your shell │
│              │   tiny frame proto  │  (persistent key) │
└──────────────┘                     └──────────────────┘
```

- **First run** shows a one-line install command. Run it on the host you want to
  reach; it installs a persistent daemon and prints a **ticket**.
- **Paste the ticket** into the app to connect. The terminal is a real PTY, so
  `vim`, `htop`, tab completion, resize, etc. all work.
- **Remembers your last few connections.** Because the host keeps a stable secret
  key, the saved ticket reconnects across host reboots and IP changes.

## What's in here

| Path | What |
|------|------|
| `ios/Zuko/` | The iOS app (XcodeGen `project.yml` + Swift sources). |
| `host/` | The host daemon (`zuko-host`): Iroh + PTY bridge, written in Rust. |
| `host/scripts/` | mise-based install + run scripts, systemd/launchd units. |
| `.github/workflows/` | CI: builds the iOS app (simulator), builds+tests the host, and publishes host release binaries to GitHub Releases. |

## Wire protocol

One bidirectional Iroh stream, ALPN `zuko/1`. Each message is length-prefixed so
resize and data stay ordered and nothing leaks into the terminal as escape codes:

```
[type: u8][len: u16 big-endian][payload: len bytes]
  0x00 DATA   payload = raw terminal bytes
  0x01 RESIZE payload = [cols: u16 BE][rows: u16 BE]   (client -> host)
```

See [`host/src/main.rs`](host/src/main.rs) and
[`ios/Zuko/Zuko/Net/Wire.swift`](ios/Zuko/Zuko/Net/Wire.swift).

## Quick start

### 1. Set up a host

Prerequisite: [mise](https://mise.jdx.dev) on the host (`curl https://mise.run | sh`). The installer pulls a prebuilt `zuko-host` binary from GitHub Releases via mise's `github:` backend.

On the machine you want to shell into:

```sh
curl -fsSL https://raw.githubusercontent.com/adonm/zuko/main/host/scripts/install.sh | sh
```

This installs `zuko-host`, writes a persistent secret key to `~/.config/zuko/key`,
starts a background service (systemd user unit on Linux, launchd on macOS), and
prints a ticket that starts with `endpointa…`.

> Manual / no service manager? See [`host/README.md`](host/README.md) and
> `host/scripts/zuko-host.sh`. To pin a version: `ZUKO_VERSION=v0.1.0 sh install.sh`.

### 2. Build the app

With [mise](https://mise.jdx.dev) installed:

```sh
MISE_ENV=ios mise install   # rust + xcodegen (the ios env layer)
mise run build-ios          # generate project + build for the iOS Simulator
open ios/Zuko/Zuko.xcodeproj
```

Pick your iPhone and hit Run. (CI builds the same way — grab the `Zuko-app`
artifact from the [ios workflow](../../actions/workflows/ios.yml); it's an
unsigned simulator build, so for a real device you need to sign it with your own
developer account.)

### 3. Connect

In the app: tap **+**, name the host, paste the ticket from step 1, tap **Add**.
Tap the host to open a terminal.

## Requirements

- iOS 17.5+ (IrohLib requirement), Xcode 16+.
- Host: any Linux/macOS box with [mise](https://mise.jdx.dev) (the installer
  downloads a prebuilt binary from GitHub Releases; `cargo` is only needed if
  you build from source). Iroh uses public relays + NAT traversal to reach hosts
  behind firewalls — no port forwarding needed.

## Security notes

- Connections are end-to-end encrypted by Iroh using the host's key. Anyone who
  has the ticket can connect, so treat it like an SSH private key — the ticket is
  the only secret needed to reach the host.
- Rotate by deleting `~/.config/zuko/key` and restarting; the node id changes
  and all old tickets stop working.
- The host runs your `$SHELL` per connection. If you want a specific command,
  pass `--shell` / `--shell-args` (see `zuko-host --help`).

## Development

Tools, system deps, and tasks are defined in [`mise.toml`](mise.toml)
([`mise.ios.toml`](mise.ios.toml) adds xcodegen under `MISE_ENV=ios`):

```sh
mise install              # rust (+ system deps via mise bootstrap)
mise run test-host        # clippy + unit tests
mise run build-host       # release binary
MISE_ENV=ios mise install # adds xcodegen (macOS)
mise run build-ios        # generate + build the iOS app
mise run run-host         # run the daemon in the foreground
```

CI uses the same tasks via [`jdx/mise-action`](https://github.com/jdx/mise-action),
so local and CI stay in lockstep.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
