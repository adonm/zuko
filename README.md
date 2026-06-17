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
| `host/scripts/` | Install + run scripts, systemd/launchd units. |
| `.github/workflows/` | CI: builds the iOS app (simulator) and the host (Linux + macOS). |

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

On the machine you want to shell into:

```sh
curl -fsSL https://raw.githubusercontent.com/adonm/zuko/main/host/scripts/install.sh | sh
```

This builds `zuko-host`, writes a persistent secret key to `~/.config/zuko/key`,
starts a background service (systemd user unit on Linux, launchd on macOS), and
prints a ticket that starts with `endpointa…`.

> Manual / no service manager? See [`host/README.md`](host/README.md) and
> `host/scripts/zuko-host.sh`.

### 2. Build the app

The Xcode project is generated from [`ios/Zuko/project.yml`](ios/Zuko/project.yml)
with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
cd ios/Zuko && xcodegen generate
open Zuko.xcodeproj
```

Pick your iPhone and hit Run. (CI also builds it — grab the `Zuko-app` artifact
from the [ios workflow](../../actions/workflows/ios.yml); it's an unsigned
simulator build, so for a real device you need to sign it with your own
developer account.)

### 3. Connect

In the app: tap **+**, name the host, paste the ticket from step 1, tap **Add**.
Tap the host to open a terminal.

## Requirements

- iOS 17.5+ (IrohLib requirement), Xcode 16+.
- Host: any Linux/macOS box with `cargo`/`rustc` (the installer builds from
  source). Iroh uses public relays + NAT traversal to reach hosts behind
  firewalls — no port forwarding needed.

## Security notes

- Connections are end-to-end encrypted by Iroh using the host's key. Anyone who
  has the ticket can connect, so treat it like an SSH private key — the ticket is
  the only secret needed to reach the host.
- Rotate by deleting `~/.config/zuko/key` and restarting; the node id changes
  and all old tickets stop working.
- The host runs your `$SHELL` per connection. If you want a specific command,
  pass `--shell` / `--shell-args` (see `zuko-host --help`).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
