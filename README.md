# zuko

Reach your own Mac/Linux boxes over [Iroh](https://www.iroh.computer/) — dial by
key, end-to-end encrypted, no open ports or port forwarding needed. Zuko is one
small Rust binary that does two things:

- **`zuko host`** runs on the machine you want to reach. It keeps a persistent
  identity and exposes your shell over Iroh.
- **`zuko connect`** (this repo) or the **iOS app** attach a real terminal to
  that shell from anywhere.

```
 iPhone / laptop                           your host
┌──────────────────┐      Iroh (E2E)     ┌──────────────────┐
│  zuko connect    │  <----------------> │  zuko host       │
│  …or the iOS app │   bidi stream +     │  PTY + your shell│
│  (SwiftTerm)     │   tiny frame proto  │  (persistent key)│
└──────────────────┘                     └──────────────────┘
```

- **First run** of `zuko host` prints a one-line **ticket**.
- **Paste the ticket** into the app, or `zuko connect "<ticket>"` from a
  terminal. It's a real PTY, so `vim`, `htop`, tab completion, resize, etc. all
  work.
- **Remembers your hosts.** Because the host keeps a stable secret key, the same
  ticket reconnects across host reboots and IP changes. `zuko add home
  "<ticket>"` once, then just `zuko home`.
- **Skip the long paste on a new device.** Run `zuko share` on the host, read
  off a short code (`wowu-hiva-fiki-rufu`), then `zuko claim <code>` on the new
  device — it fetches the real ticket over Iroh, saves it, and connects. See
  [`zuko/README.md`](zuko/README.md) for the croc-style handoff.

## What's in here

| Path | What |
|------|------|
| `zuko/` | The `zuko` binary (Rust): `zuko host` + `zuko connect` + `zuko share`/`claim` over Iroh. Wire framing in [`zuko/src/wire.rs`](zuko/src/wire.rs), ticket handoff in [`zuko/src/share.rs`](zuko/src/share.rs). |
| `zuko/scripts/` | mise-based install + run scripts, systemd/launchd units, and [`e2e_test.py`](zuko/scripts/e2e_test.py) (the end-to-end PTY harness). |
| `ios/Zuko/` | The iOS app (XcodeGen `project.yml` + Swift sources). |
| `.github/workflows/` | CI: builds+tests the `zuko` binary (incl. the e2e harness), the iOS app (simulator), and publishes `zuko` release binaries to GitHub Releases. |

## Wire protocol

One bidirectional Iroh stream, ALPN `zuko/1`. Each message is length-prefixed so
resize and data stay ordered and nothing leaks into the terminal as escape codes:

```
[type: u8][len: u16 big-endian][payload: len bytes]
  0x00 DATA   payload = raw terminal bytes
  0x01 RESIZE payload = [cols: u16 BE][rows: u16 BE]   (client -> host)
```

See [`zuko/src/wire.rs`](zuko/src/wire.rs) and
[`ios/Zuko/Zuko/Net/Wire.swift`](ios/Zuko/Zuko/Net/Wire.swift).

## Quick start

### 1. Set up a host

Prerequisite: [mise](https://mise.jdx.dev) on the host (`curl https://mise.run | sh`). The installer pulls a prebuilt `zuko` binary from GitHub Releases via mise's `github:` backend.

On the machine you want to shell into:

```sh
curl -fsSL https://raw.githubusercontent.com/adonm/zuko/main/zuko/scripts/install.sh | sh
```

This installs `zuko`, writes a persistent secret key to `~/.config/zuko/key`,
starts a background service (systemd user unit on Linux, launchd on macOS), and
prints a ticket that starts with `endpointa…`.

> Manual / no service manager? See [`zuko/README.md`](zuko/README.md) and
> `zuko/scripts/zuko-host.sh`. To pin a version: `ZUKO_VERSION=v0.1.0 sh install.sh`.

### 2. Connect

You have two clients — pick whichever you like (both use the same ticket):

**From a terminal (Linux/macOS):**

```sh
mise use --global github:adonm/zuko   # installs the `zuko` binary
zuko connect "<ticket>"               # or: zuko add home "<ticket>" && zuko home
```

**From the iOS app:**

With [mise](https://mise.jdx.dev) installed:

```sh
mise install             # rust
mise run setup-ios       # brew install xcodegen + fastlane (macOS)
mise run build-ios       # generate project + build for the iOS Simulator
open ios/Zuko/Zuko.xcodeproj
```

Pick your iPhone and hit Run. In the app: tap **+**, name the host, paste the
ticket from step 1, tap **Add**. Tap the host to open a terminal. (CI builds the
same way — grab the `Zuko-app` artifact from the [ios workflow](../../actions/workflows/build-ios.yml);
it's an unsigned simulator build, so for a real device you need to sign it with
your own developer account.)

## Requirements

- iOS 17.5+ (IrohLib requirement), Xcode 16+ — for the iOS app.
- Host: any Linux/macOS box with [mise](https://mise.jdx.dev). The installer
  downloads a prebuilt binary from GitHub Releases; `cargo` is only needed if
  you build from source. Iroh uses public relays + NAT traversal to reach hosts
  behind firewalls — no port forwarding needed.
- Client (terminal): same — `mise use --global github:adonm/zuko`.

## Security notes

- Connections are end-to-end encrypted by Iroh using the host's key. Anyone who
  has the ticket can connect, so treat it like an SSH private key — the ticket is
  the only secret needed to reach the host.
- Rotate by deleting `~/.config/zuko/key` and restarting; the node id changes
  and all old tickets stop working.
- The host runs your `$SHELL` per connection. If you want a specific command,
  pass `--shell` / `--shell-args` (see `zuko host --help`).

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

CI uses the same tasks via [`jdx/mise-action`](https://github.com/jdx/mise-action),
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
  in GitHub secrets on this repo. The default `build`/`build-ios` workflows
  produce an *unsigned simulator* build for verification.

## License

Apache-2.0. See [`LICENSE`](LICENSE).
