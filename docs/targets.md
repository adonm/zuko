# Labs targets

Labs code is useful for validating demand and protocol portability, but is not
part of the Core support promise. Promotion criteria are tracked in the
[roadmap](roadmap.md).

## Browser client

Goal: test whether a zero-install browser can be a useful zuko client without
weakening the Core host/CLI design. The static app at `/web/` can claim and
connect to a host today.

Open it from the published docs: [zuko web](https://adonm.github.io/zuko/web/).

Chosen stack:

- **Transport:** Iroh's browser/WASM build. Browser peers are relay-only because
  the browser sandbox cannot do UDP hole punching, but Iroh still keeps payloads
  end-to-end encrypted.
- **Terminal:** [`wterm`](https://wterm.dev/) with `@wterm/ghostty`, which uses a
  libghostty VT core compiled to WASM. This is the best Ghostty-derived browser
  terminal available today; it is not the full native Ghostty app.
- **UI:** semantic HTML plus bundled Bootstrap 5 CSS. No CDN scripts/styles are
  loaded at runtime; Vite emits static assets under `/web/`.
- **Build:** Deno runs TypeScript/Vite tasks and consumes npm packages through
  `package.json` + `deno.lock`.
- **Storage:** IndexedDB under the Pages origin. It stores the browser client key
  and claimed host connection information locally.

Security boundaries:

- Shell access requires the stored host connection information and the browser's
  authorized client key. Any script running on the same origin can read both
  from IndexedDB and impersonate that browser client.
- Keep the web app dependency-free at runtime except bundled assets, use a strict
  CSP, and do not load third-party scripts anywhere on the shared origin.
- Browser Iroh traffic is relay-only. Relays can see metadata and volume, not
  decrypted zuko frames.

Implementation status:

- Static app: `web/`, built by `mise run build-web` into `target/book/web/`.
- CI publish: `.github/workflows/docs.yml` builds mdBook first, then the web app,
  and uploads one Pages artifact.
- Iroh bridge: `web/wasm/` exposes claim/connect/session streaming to TypeScript.
- Terminal UI: `@wterm/ghostty` renders the remote PTY stream in the browser.
- Rendering hygiene: remote output is batched per animation frame, resize frames
  are debounced, and the browser sends measured grid pixels instead of the outer
  element size.

Known gaps:

- No reconnect/backoff loop for an already-attached terminal session yet.
- `zuko app` Kitty graphics should be treated as experimental until wterm's
  renderer is verified against zuko's graphics stream.
- Pages security headers are limited compared with a dedicated app origin; move
  to a hardened subdomain if this becomes a daily-use client.

Promotion requires reconnect/backoff, browser-level tests, and isolation on a
dedicated hardened origin. Until then, use the Core CLI for routine access.
