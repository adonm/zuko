import GhosttyKit
import GhosttyTerminal
import SwiftUI
import UIKit

// Touch-to-mouse bridge for TUI apps that have enabled mouse capture
// (`btop`, `yazi`, `zellij`, `vim` with `set mouse=a`, etc.).
//
// ## The problem
//
// libghostty-spm's `UITerminalView+Interaction.swift` only routes *finger*
// touches (`.direct`) to scroll gestures. Mouse clicks (`sendMouseButton`)
// fire only for `.indirectPointer` touches — i.e. an external trackpad or
// mouse. So tapping on `btop`'s process list does nothing, even though
// `btop` has enabled SGR mouse mode and is waiting for click events.
//
// ## The approach
//
// Add a tap gesture recognizer to the embedded `UITerminalView`. The
// handler checks `ghostty_surface_mouse_captured` and bails when the
// foreground app hasn't enabled mouse tracking — so a shell at a prompt
// ignores taps entirely (no escape sequences injected as keystrokes).
// `cancelsTouchesInView = false` lets the existing scroll / pinch /
// long-press recognizers continue firing alongside us.
//
// ## Why reflection
//
// Ghostty's mouse APIs (`sendMousePos`, `sendMouseButton`,
// `mouseCaptured`) are all `internal` in libghostty-spm — not callable
// from our app. The Swift `TerminalSurface` wrapper also keeps its
// underlying `ghostty_surface_t` pointer private. We walk the whole
// `UITerminalView.core.surface.surface` chain via `Mirror` and then
// call the ghostty C functions directly (GhosttyKit is now a direct
// dependency for this reason).
//
// Reflection is brittle against upstream renames, but the failure mode
// is benign: `zuko_rawSurface()` returns nil, the tap handler bails,
// and the terminal behaves as it does today. No crash, no misdelivered
// input.

extension UITerminalView {
    /// Read the raw ghostty surface pointer via Mirror reflection on the
    /// internal `core` (coordinator) → `surface` (TerminalSurface?) →
    /// `surface` (private stored `ghostty_surface_t?`).
    /// Returns nil if any link in the chain breaks (e.g. libghostty-spm
    /// renamed a property in a future version).
    private func zuko_rawSurface() -> ghostty_surface_t? {
        // All three properties (`core`, coordinator's `surface`,
        // TerminalSurface's `surface`) are internal/private — Mirror
        // reflection bypasses Swift's access control at runtime.
        let viewMirror = Mirror(reflecting: self)
        guard let terminalSurface = viewMirror.descendant("core", "surface") as? TerminalSurface
        else { return nil }
        let surfaceMirror = Mirror(reflecting: terminalSurface)
        for child in surfaceMirror.children where child.label == "surface" {
            // The value's static type depends on how Swift imported the
            // incomplete C struct — usually `OpaquePointer`, occasionally
            // the named `ghostty_surface_t` typealias. Try both.
            if let raw = child.value as? ghostty_surface_t {
                return raw
            }
            if let opaque = child.value as? OpaquePointer {
                return unsafeBitCast(opaque, to: ghostty_surface_t.self)
            }
        }
        return nil
    }

    /// Whether the foreground TUI app has enabled mouse capture (via
    /// `\x1b[?1000h` / `\x1b[?1006h` / etc.). Drives whether our tap
    /// handler actually delivers a click.
    func zuko_mouseCaptured() -> Bool {
        guard let raw = zuko_rawSurface() else { return false }
        return ghostty_surface_mouse_captured(raw)
    }

    /// Send a left-button click (press + release) at the given
    /// view-coordinate location. Ghostty translates pixels → cells using
    /// its current grid metrics and emits whatever escape sequence the
    /// TUI app's mouse mode expects (SGR for modern apps, legacy
    /// formats otherwise) — we don't have to care which.
    func zuko_sendMouseClick(at point: CGPoint) {
        guard let raw = zuko_rawSurface() else { return }
        let mods = ghostty_input_mods_e(rawValue: 0)
        ghostty_surface_mouse_pos(raw, Double(point.x), Double(point.y), mods)
        ghostty_surface_mouse_button(raw, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        ghostty_surface_mouse_button(raw, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
    }
}

/// Invisible overlay placed alongside `TerminalSurfaceView` in the
/// `TerminalScreen` ZStack. On appear it walks the sibling view hierarchy
/// to find the `UITerminalView` and installs a tap gesture recognizer
/// on it. The recognizer's handler bails when the foreground app hasn't
/// enabled mouse capture — so scroll / text-selection recognizers handle
/// those touches as before.
///
/// Implemented as a `UIViewRepresentable` because the gesture needs to be
/// attached to the embedded `UITerminalView` (a UIKit view), not to a
/// SwiftUI view — SwiftUI `.onTapGesture` would consume touches before
/// they reach the terminal and break existing pan/long-press handling.
struct TouchMouseInput: UIViewRepresentable {
    func makeUIView(context: Context) -> InputView {
        InputView()
    }

    func updateUIView(_ uiView: InputView, context: Context) {}
}

final class InputView: UIView {
    private var tapGesture: UITapGestureRecognizer?
    private weak var attachedTerminal: UITerminalView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        tryAttach()
    }

    private func tryAttach() {
        guard window != nil, tapGesture == nil else { return }
        // We're a transparent overlay in the same ZStack as
        // TerminalSurfaceView. Walk siblings + descendants to find the
        // UITerminalView that TerminalSurfaceView's representable
        // created. Climb to a common ancestor first so we cover both
        // "sibling" and "cousin" layouts.
        var ancestor: UIView? = superview
        for _ in 0..<6 {
            if let a = ancestor, let terminal = findTerminal(in: a) {
                let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
                // Don't cancel sibling recognizers — we want the
                // existing scroll / pinch / long-press gestures to
                // keep working. The handler gates on `mouseCaptured`
                // so we only deliver a click when the TUI app actually
                // wants one.
                tap.cancelsTouchesInView = false
                terminal.addGestureRecognizer(tap)
                tapGesture = tap
                attachedTerminal = terminal
                return
            }
            ancestor = ancestor?.superview
            if ancestor == nil { break }
        }
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard let terminal = attachedTerminal,
              terminal.zuko_mouseCaptured()
        else { return }
        // Translate tap location to the terminal's coordinate space.
        // The recogniser is attached to the terminal itself, so this is
        // already in its pixels — ghostty converts to cell coords using
        // the current grid metrics.
        let location = gesture.location(in: terminal)
        terminal.zuko_sendMouseClick(at: location)
    }

    private func findTerminal(in view: UIView) -> UITerminalView? {
        if let terminal = view as? UITerminalView { return terminal }
        for sub in view.subviews {
            if let found = findTerminal(in: sub) { return found }
        }
        return nil
    }
}
