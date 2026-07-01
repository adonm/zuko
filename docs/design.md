# zuko design notes

This document records product/architecture choices that are easy to lose while
working on protocol details. The short version: zuko should stay a great remote
**terminal** first. GUI-app streaming should compose with existing terminal
emulators instead of replacing them.

## Goals

- **Interop by default.** A stock terminal plus the `zuko` binary should be a
  capable client. The best path is the one that works through Ghostty, kitty,
  WezTerm, iTerm2-compatible stacks, and any other terminal implementing the
  same de-facto protocols.
- **One host, many clients.** The host is a PTY and a small Iroh protocol. CLI,
  iOS, future Android, and future desktop clients should share it.
- **Boring failure modes.** Bound buffers, backpressure, clear diagnostics, and
  no hidden daemon state unless it buys a real user-visible reliability win.
- **Add capabilities without stranding old clients.** New protocol pieces should
  negotiate cleanly and leave the terminal path intact.

## `zuko app`: why Kitty graphics is the primary GUI transport

`zuko app` runs a GUI app under cage/wlroots on the host, captures frames with
wlr-screencopy, and emits them into the existing terminal session via the Kitty
graphics protocol. That is intentional, not a temporary hack.

Kitty graphics is the right primary interop layer because it keeps zuko inside
the terminal ecosystem:

- **Works over the existing PTY path.** `zuko app firefox` can be launched from
  inside an ordinary `zuko <host>` shell. No second listener, port, pairing flow,
  app install, or desktop client is required.
- **Leverages deployed terminal work.** Terminals already handle image
  placement, alternate screen lifetime, scrolling semantics, resizing, and raw
  keyboard/mouse escape reporting. zuko only has to encode frames and input.
- **Ghostty remains a first-class target.** The iOS app is built around
  GhosttyTerminal, and desktop Ghostty is a natural primary terminal target.
  Staying Kitty-compatible makes Ghostty support easier, not harder: zuko uses
  the terminal surface it already has instead of inventing a parallel renderer.
- **Preserves user choice.** Users can pick any Kitty-compatible terminal. A
  custom-only graphics protocol would require a zuko-specific client everywhere
  and would immediately lose this compatibility.
- **Keeps security and ops simple.** GUI frames are just terminal output over the
  already-authenticated Iroh session. There is no extra long-lived bearer token,
  side channel, local socket, or per-client rendering service to harden.

The cost is that Kitty graphics is not a perfect video transport: terminal image
payloads still go through base64/escape framing, and terminal image support
differs across emulators. `zuko app --graphics-codec auto` keeps PNG for
mostly-static UI frames but can switch high-entropy video-like frames to raw RGB
to avoid wasting CPU on PNG filtering/zlib when it no longer compresses well.
For zuko's product goal — "remote terminal experience that can also host a GUI
app when needed" — broad compatibility beats a more optimal private path.

## What a custom protocol could buy

A custom GUI protocol could still be useful someday, but only as an **optional
fast path** for native clients that deliberately opt in. Benefits could include:

- **Lower overhead frames.** Binary frame payloads avoid base64 and Kitty escape
  framing. They could carry PNG chunks directly, or later a real video codec /
  damage rectangles.
- **Cleaner flow control.** GUI frames could live on their own QUIC stream(s),
  separate from terminal text and input, with drop-latest/drop-oldest policies
  tuned for visual frames rather than terminal bytes.
- **Explicit capabilities.** A native client could negotiate pixel formats,
  cursor shape, pointer-lock, touch gestures, clipboard, audio, or codec support
  without probing terminal escape behavior.
- **Better mobile/native UI integration.** A phone/tablet/desktop app could draw
  frames directly into a view and map gestures without going through a terminal
  emulator surface.

Those are real advantages for a dedicated zuko GUI client. They are not good
reasons to remove Kitty graphics.

## Why a custom protocol must not replace Kitty graphics

Replacing Kitty graphics with a zuko-only GUI stream would make the most useful
path worse:

- Existing Kitty-compatible terminals would stop being complete clients for GUI
  apps.
- Desktop/Ghostty users would need a custom zuko GUI app instead of using the
  terminal they already chose.
- iOS would either keep GhosttyTerminal for shell sessions and add a second
  bespoke renderer for app sessions, or abandon GhosttyTerminal's terminal
  behavior for GUI mode. Both add complexity and drift.
- Debuggability gets worse. Today `zuko app --test-pattern`, terminal captures,
  and escape-sequence logging are enough to isolate many bugs. A private renderer
  adds a second rendering stack to debug.

So the rule is:

> Kitty graphics is the baseline GUI-app transport. A custom protocol may be an
> additive native-client optimization, never the only path.

## Current protocol direction

The shell protocol now negotiates `zuko/2` before falling back to `zuko/1`.
v2 keeps the same tiny frame format but allows a separate control stream for
resize/ping traffic. This is deliberately conservative: it improves reliability
without changing what a terminal client is.

If a future native GUI fast path is added, it should follow the same shape:

1. negotiate capability explicitly;
2. keep the PTY/Kitty path as the default and fallback;
3. make failure obvious (`zuko app --doctor` should explain what is missing);
4. avoid requiring a custom client for basic GUI-app usage.

## Practical implications

- Optimize the current Kitty path first: adaptive output size, frame skipping,
  raw RGB for video-like frames, better terminal capability detection, and input
  reliability.
- Keep `zuko app` usable from a normal remote shell.
- Treat native GUI/video streams as performance/capability enhancements for
  clients that want them, not as the product center of gravity.
