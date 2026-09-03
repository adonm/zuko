# Pairing and connection flow

A picture-by-picture walkthrough of Zuko: installing the host, claiming a
one-time share code, and opening the terminal — on desktop and on touch.

The main screenshots are captured from the real Linux app (real engine,
bundled fonts) by `flutter/integration/integration_test/screenshot_flow_test.dart`;
the camera screen, which only exists on camera-capable targets, renders from
the widget tree instead. Regenerate everything with `just screenshots`
whenever the pairing or connection UI changes.

## 1. First run

The welcome screen gives the two host-side commands: install Zuko, then
run `zuko share` to mint a one-time share code.

![Welcome screen](images/welcome.png)

## 2. Claim the share code

On a phone, point the camera at the QR code that `zuko share` prints. The
animated viewfinder brackets the code; a failed claim offers both a retry
and the typed fallback.

![Camera pairing](images/pairing-scan.png)

Typing the code accepts the canonical two-word form. Pasting works with the
full `zuko share` output — the code is extracted from merged
stdout/stderr, `zuko claim` lines, or `zuko://pair` URIs.

![Manual pairing](images/pairing-code.png)

A successful claim confirms the host name before the connection opens.

![Pairing confirmation](images/pairing-confirmed.png)

## 3. Connect to a saved host

Selecting a saved host opens a terminal tab. While the peer connection is
established, the session overlay reports progress and the tab shows the
busy state.

![Connecting](images/connecting.png)

If the link drops, the overlay counts down to the automatic reconnect
attempt; *Retry now* reconnects immediately.

![Reconnect countdown](images/retrying.png)

## 4. The terminal

An attached session brings up the terminal with the compact accessory bar.
On wide desktops the sidebar collapses to a slim rail (the logo in the
accessory expands it) and the app bar gives way to native window chrome, so
the terminal fills the window.

![Attached session](images/connected.png)

Real terminal programs render as they would locally — here btop under the
touch layout's floating pad.

![btop with the floating pad](images/touch-btop.png)

TUI image previews (for example yazi's) use the Kitty graphics protocol.
They need the host to advertise `TERM=xterm-kitty`, so `zuko doctor`
checks for the terminfo entry (on Debian/Ubuntu: the `kitty-terminfo`
package) and tells you how to install it when sessions would fall back to
`xterm-256color`. Protocol transport is verified end to end (yazi picks
the Kitty adapter and its image bytes reach the client); visible painting
of placed images is a known upstream flterm gap being tracked in the test
suite.

![yazi sending an image over the Kitty graphics protocol](images/yazi-preview.png)

Terminal capability support:

| Capability | Status | Notes |
| --- | --- | --- |
| Kitty graphics transport | Supported | PNG/RGB/RGBA payloads store; needs `TERM=xterm-kitty` on the host |
| Kitty image painting | Upstream gap | Stored images don't paint yet (flterm); placeholders show as tofu |
| Sixel graphics | Not supported | Upstream Ghostty vt core has no Sixel; use Kitty-protocol programs |
| Mouse clicks, drags, wheel | Supported | SGR reports to mouse-tracking programs (yazi, helix, btop) |
| Touch tap, drag, long-press select | Supported | Long-press arms local selection; latch Shift in the accessory to select instead of clicking in mouse mode |
| Pixel-precise mouse (mode 1016) | Not requested | Encoder supports SGR-pixels; no program has needed it yet |

### Touch layout

Touch devices drop the top bar entirely. A translucent floating pad floats
over the terminal and can be dragged anywhere:

- tap a key for arrows, PgUp/PgDn, Home/End (hold to repeat) — PgUp/PgDn
  scroll the terminal view;
- drag the pad to move it anywhere over the terminal;
- tap the center logo to open the sidebar.

![Touch terminal with the floating pad](images/touch-terminal.png)

The same narrow layout running a real terminal program: the sidebar stays
closed and the pad floats over btop.

![btop in the narrow touch layout](images/touch-narrow-btop.png)

## 5. Re-pairing and revocation

A host that rejects the saved ticket shows a *Pair again* action. Pairing
again records the fresh ticket and the host-side client label, which the
host details dialog exposes as a `zuko rm <label>` revocation command.
