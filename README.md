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

- **One ticket per host.** `zuko host` prints a ticket (`endpointa…`) that any
  client dials. Because the host keeps a stable secret key, the same ticket
  reconnects across reboots and IP changes.
- **Real PTY.** Bytes flow verbatim between the client and the host's shell, so
  every terminal program behaves exactly as if it were local.
- **No port forwarding, no relay you run.** Iroh's public relays + NAT
  traversal do the reachability; the connection is end-to-end encrypted by the
  host's key.
- **Skip the long paste on a new device.** `zuko share` mints a short code;
  `zuko claim <code>` fetches the ticket over Iroh, saves it, and connects.

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
The installer pulls a prebuilt `zuko` binary from GitHub Releases via mise's
`github:` backend.

On the machine you want to shell into:

```sh
curl -fsSL https://raw.githubusercontent.com/adonm/zuko/main/zuko/scripts/install.sh | sh
```

This installs `zuko`, writes a persistent secret key to `~/.config/zuko/key`,
starts a background service (systemd user unit on Linux, launchd on macOS), and
prints a ticket that starts with `endpointa…`.

> Manual / no service manager? See [`zuko/README.md`](zuko/README.md) and
> `zuko/scripts/zuko-host.sh`. To pin a version: `ZUKO_VERSION=v0.1.0 sh install.sh`.

### 2. Pick a client

Both clients use the same ticket.

**Terminal (Linux/macOS)** — the `zuko` binary:

```sh
mise use --global github:adonm/zuko
zuko connect "endpointa..."        # one-off
zuko add home "endpointa..."       # …or save it once, then:
zuko home                          # shorthand for `zuko connect home`
```

You can also pipe the ticket: `echo "endpointa..." | zuko`. Or, from a host
running `zuko share`, skip the paste entirely: `zuko claim wowu-hiva-fiki-rufu`.

**iOS** — the iOS app:

```sh
mise install             # rust
mise run setup-ios       # brew install xcodegen + fastlane (macOS)
mise run build-ios       # generate project + build for the iOS Simulator
open ios/Zuko/Zuko.xcodeproj
```

Pick your iPhone and hit Run. In the app: tap **+**, name the host, paste the
ticket, tap **Add**. (CI builds the same way — grab the `Zuko-app` artifact from
the [build workflow](.github/workflows/build.yml); it's an unsigned simulator
build, so for a real device you need to sign it with your own developer account.)

## Wire protocol

One bidirectional Iroh stream, ALPN `zuko/1`. Each message is length-prefixed
so resize and data stay ordered and nothing leaks into the terminal as escape
codes:

```
[type: u8][len: u16 big-endian][payload: len bytes]
  0x00 DATA   payload = raw terminal bytes
  0x01 RESIZE payload = [cols: u16 BE][rows: u16 BE]   (client -> host)
```

The full spec (lifecycle, semantics, the optional ticket-handoff ALPN) is in
[`docs/PROTOCOL.md`](docs/PROTOCOL.md). Reference impls:
[`zuko/src/wire.rs`](zuko/src/wire.rs) (Rust),
[`ios/Zuko/Zuko/Net/Wire.swift`](ios/Zuko/Zuko/Net/Wire.swift) (Swift).

## What's in here

| Path | What |
|------|------|
| `zuko/` | The `zuko` binary (Rust): the **host** (`zuko host`) + the **CLI client** (`zuko connect`/`share`/`claim`). Wire framing in [`zuko/src/wire.rs`](zuko/src/wire.rs), handoff in [`zuko/src/share.rs`](zuko/src/share.rs). |
| `zuko/scripts/` | mise-based install + run scripts, systemd/launchd units, and [`e2e_test.py`](zuko/scripts/e2e_test.py) (the end-to-end PTY harness). |
| `ios/Zuko/` | The **iOS client** (XcodeGen `project.yml` + Swift sources). |
| `docs/` | [`PROTOCOL.md`](docs/PROTOCOL.md) (wire spec for client authors) and [`CLIENTS.md`](docs/CLIENTS.md) (client registry). |
| `.github/workflows/` | CI: builds+tests the `zuko` binary (incl. the e2e harness), the iOS app (simulator), and publishes `zuko` release binaries to GitHub Releases. |

## Requirements

- Host: any Linux/macOS box with [mise](https://mise.jdx.dev). The installer
  downloads a prebuilt binary; `cargo` is only needed to build from source.
- CLI client: same — `mise use --global github:adonm/zuko`.
- iOS client: iOS 17.5+ (IrohLib requirement), Xcode 16+.

## Security notes

- Connections are end-to-end encrypted by Iroh using the host's key. Anyone who
  has the ticket can connect, so treat it like an SSH private key — the ticket is
  the only secret needed to reach the host.
- `zuko share`/`claim` never weaken this: the memorable code derives a
  *throwaway* key used only to deliver the real ticket once. The host key stays
  strong. See [`docs/PROTOCOL.md`](docs/PROTOCOL.md#ticket-handoff-optional).
- Rotate by deleting `~/.config/zuko/key` and restarting; the node id changes
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
  `macos/{x86_64,aarch64}` and attaches tarballs to a GitHub Release. The
  install script (and `mise use --global github:adonm/zuko`) pulls these via
  mise's `github:` backend. The release binary is ~9.5 MB — built with boring
  dependencies and standard size-conscious cargo flags (`opt-level="z"`, fat
  LTO, stripped symbols); no bespoke trimming, on purpose.
- **iOS app** — [`ios/DISTRIBUTION.md`](ios/DISTRIBUTION.md) covers building a
  **signed** `.ipa` and pushing to **TestFlight entirely from GitHub Actions,
  no Mac required**. Signing material (`.p12` cert + `.mobileprovision`) lives
  in GitHub secrets on this repo.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
