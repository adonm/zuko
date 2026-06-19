# zuko

**Remote terminals over [Iroh](https://www.iroh.computer/).** Dial by key,
end-to-end encrypted, no open ports or port forwarding. Run the **host** on any
Linux/macOS box you want to reach, then attach a **client** from anywhere —
`vim`, `htop`, tab completion, resize, Ctrl-C all work, because the host runs a
real PTY.

zuko is a small **wire protocol** and a **host daemon**. The clients are
pluggable: the iOS app and the CLI are the first two, and Android / a Linux GUI
(relm4) / others can speak the same protocol. The spec is in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md); the client list lives in
[`docs/CLIENTS.md`](docs/CLIENTS.md).

```
   any client                                  your host
  ┌──────────────┐      Iroh (E2E)        ┌──────────────────┐
  │  iOS app     │  <------------------->  │  zuko host       │
  │  CLI         │   bidi stream +         │  PTY + your shell│
  │  Android…    │   zuko/1 frame proto    │  (persistent key)│
  └──────────────┘                         └──────────────────┘
```

- **Pair with a code.** Add a new device with `zuko share` on the host (prints
  a short, minutes-long code) and `zuko <code>` on the other machine. The code
  is a one-time pad over an ephemeral Iroh key — the host's persistent key
  stays put.
- **Real PTY.** Bytes flow verbatim between the client and the host's shell, so
  every terminal program behaves exactly as if it were local.
- **No port forwarding, no relay you run.** Iroh's public relays + NAT
  traversal do the reachability; the connection is end-to-end encrypted by the
  host's key.
- **Service install in the CLI.** `zuko install` writes the systemd/launchd
  user unit and starts the daemon. `zuko uninstall` reverses it.

## Clients

Anyone can write a client — zuko is one bidirectional Iroh stream and a tiny
frame format. See [`docs/CLIENTS.md`](docs/CLIENTS.md) for the full list and
[`docs/PROTOCOL.md`](docs/PROTOCOL.md) for the spec. Reference implementations:

| Client | Status | Stack | Source |
|--------|--------|-------|--------|
| **CLI** | shipped | Rust + crossterm | the `zuko` binary (`zuko connect`) |
| **iOS** | shipped | Swift + SwiftTerm + IrohLib | [`ios/Zuko/`](ios/Zuko) |
| Android | planned | — | — |
| Linux GUI (relm4) | planned | — | — |

The CLI ships in the same `zuko` binary as the host — one install gives you
both. The iOS app is built from source (or pushed to TestFlight from CI; see
[`ios/DISTRIBUTION.md`](ios/DISTRIBUTION.md)).

## Quick start

### 1. Set up a host

Prerequisite: [mise](https://mise.jdx.dev) on the host (`curl https://mise.run | sh`).

On the machine you want to shell into:

```sh
mise use --global github:adonm/zuko   # put `zuko` on PATH
zuko install                          # write the systemd/launchd unit + start it
```

`zuko install` writes a persistent secret key to `~/.config/zuko/key` (on the
first host run), installs a `zuko-host-run` wrapper at `~/.local/bin/`, and
starts a background service (systemd user unit on Linux, launchd on macOS).
Logs go to `journalctl --user -u zuko-host -f` (Linux) or
`~/.config/zuko/zuko-host.out.log` (macOS).

> Manual / no service manager? Run `zuko host` in the foreground, or
> [`zuko/scripts/zuko-host.sh`](zuko/scripts/zuko-host.sh) from a checkout.

### 2. Pair a client

```sh
# on the host (code is read-once, expires in minutes):
zuko share
#   wowu-hiva-fiki-rufu

# on the client:
zuko wowu-hiva-fiki-rufu   # fetches the ticket, saves it, connects
```

By default `claim` saves the host under the host's label (override with
`--as <name>`) and drops you straight into the shell. From then on, connect
by name:

```sh
zuko ls                            # list saved hosts
zuko home                          # = zuko connect home (shorthand)
```

**iOS** — build the app from source and run it in the Simulator or on a device:

```sh
mise install             # rust
mise run setup-ios       # brew install xcodegen + fastlane (macOS)
mise run build-ios       # generate project + build for the iOS Simulator
open ios/Zuko/Zuko.xcodeproj
```

Pick your iPhone and hit Run. In the app: tap **+**, name the host, paste the
ticket, tap **Add**. (CI builds the same way — grab the `Zuko-app` artifact from
the [build workflow](.github/workflows/build.yml); it's an unsigned simulator
build, so for a real device you need to sign it with your own developer
account.)

## Wire protocol

One bidirectional Iroh stream, ALPN `zuko/1`. Each message is length-prefixed
so resize and data stay ordered and nothing leaks into the terminal as escape
codes:

```
[type: u8][len: u16 big-endian][payload: len bytes]
  0x00 DATA   payload = raw terminal bytes
  0x01 RESIZE payload = [cols: u16 BE][rows: u16 BE]   (client -> host)
```

The full spec (lifecycle, semantics, the ticket-handoff ALPN used by
`share`/`claim`) is in [`docs/PROTOCOL.md`](docs/PROTOCOL.md). Reference impls:
[`zuko/src/wire.rs`](zuko/src/wire.rs) (Rust),
[`ios/Zuko/Zuko/Net/Wire.swift`](ios/Zuko/Zuko/Net/Wire.swift) (Swift).

## What's in here

| Path | What |
|------|------|
| `zuko/` | The `zuko` binary (Rust): the **host** (`zuko host`), the **CLI client** (`zuko connect`/`share`/`claim`), and the **service installer** (`zuko install`/`uninstall`). Wire framing in [`zuko/src/wire.rs`](zuko/src/wire.rs), handoff in [`zuko/src/handoff.rs`](zuko/src/handoff.rs), service management in [`zuko/src/service.rs`](zuko/src/service.rs). |
| `zuko/scripts/` | The foreground `zuko-host.sh` dev wrapper and [`e2e_test.py`](zuko/scripts/e2e_test.py) (the end-to-end PTY harness). |
| `ios/Zuko/` | The **iOS client** (XcodeGen `project.yml` + Swift sources). |
| `docs/` | [`PROTOCOL.md`](docs/PROTOCOL.md) (wire spec for client authors) and [`CLIENTS.md`](docs/CLIENTS.md) (client registry). |
| `.github/workflows/` | CI: builds+tests the `zuko` binary (incl. the e2e harness), the iOS app (simulator), and publishes `zuko` release binaries to GitHub Releases. |

## Requirements

- Host: any Linux/macOS box with [mise](https://mise.jdx.dev). `mise use
  --global github:adonm/zuko` installs the prebuilt binary; `cargo` is only
  needed to build from source.
- CLI client: same — `mise use --global github:adonm/zuko`.
- iOS client: iOS 17.5+ (IrohLib requirement), Xcode 16+.

## Security notes

- The host's `endpointa…` ticket is the only long-lived secret. It moves only
  through `zuko share` → `zuko claim`: an end-to-end-encrypted Iroh stream
  keyed by a one-time code.
- `zuko share`/`claim` never weaken the host key: the code derives a
  *throwaway* key used only to deliver the real ticket once. The host key
  stays strong. See [`docs/PROTOCOL.md`](docs/PROTOCOL.md#ticket-handoff).
- Anyone who has the ticket can connect, so treat it like an SSH private key.
  Rotate by deleting `~/.config/zuko/key` and restarting; the node id changes
  and all old tickets stop working.
- The host runs your `$SHELL` per connection. For a specific command, pass
  `--shell` / `--shell-args` (see `zuko host --help`).

## Development

Tools, system deps, and tasks are defined in [`mise.toml`](mise.toml):

```sh
mise install              # rust (+ system deps via mise bootstrap)
mise run test             # clippy + unit tests
mise run test-e2e         # end-to-end: host<->connect + share<->claim over Iroh
mise run build            # release binary
mise run setup-ios        # brew install xcodegen + fastlane (macOS)
mise run build-ios        # generate + build the iOS app
mise run run-host         # run `zuko host` in the foreground
```

CI uses the same tasks via [`jdx/mise-Action`](https://github.com/jdx/mise-Action),
so local and CI stay in lockstep.

## Releases & distribution

- **`zuko` binary** — tagging `v*` (or running the `release` workflow)
  cross-compiles `zuko` for `linux/{x86_64,aarch64}` and
  `macos/{x86_64,aarch64}` and attaches tarballs to a GitHub Release.
  `mise use --global github:adonm/zuko` pulls these via mise's `github:`
  backend; `zuko install` then sets up the service. The release binary is ~9.5
  MB — built with boring dependencies and standard size-conscious cargo flags
  (`opt-level="z"`, fat LTO, stripped symbols); no bespoke trimming, on
  purpose.

  **Cutting a release** is one command — it commits any pending work, pushes
  the branch, creates an annotated `v*` tag, and pushes the tag (which fires
  [`release.yml`](.github/workflows/release.yml)):

  ```sh
  mise run release v0.1.0   # = sh zuko/scripts/release.sh v0.1.0
  ```

  The script refuses to tag a version that doesn't match `zuko/Cargo.toml`'s
  `version`, and refuses to clobber an existing tag.

- **iOS app** — [`ios/DISTRIBUTION.md`](ios/DISTRIBUTION.md) covers building a
  **signed** `.ipa` and pushing to **TestFlight entirely from GitHub Actions,
  no Mac required**. Signing material (`.p12` cert + `.mobileprovision`) lives
  in GitHub secrets on this repo.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
