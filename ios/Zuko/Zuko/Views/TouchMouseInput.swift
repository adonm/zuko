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
// In keyboard mode the overlay opts out of hit-testing and libghostty keeps
// its default touch behavior. In tap/cursor mode the overlay captures direct
// touches before libghostty can focus the terminal and show the keyboard:
// taps become mouse clicks when the foreground app has enabled mouse capture,
// and one-finger vertical pans become precision mouse-wheel scroll events for
// TUI scrollback panes (opencode, zellij, vim, etc.).
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

    /// Send a precision wheel-scroll delta at the given terminal point. This
    /// intentionally does *not* gate on `mouseCaptured`: libghostty decides
    /// whether the delta scrolls local terminal scrollback or is encoded for
    /// an alternate-screen app that requested mouse-wheel input.
    func zuko_sendMouseScroll(at point: CGPoint, delta: CGPoint) {
        guard let raw = zuko_rawSurface() else { return }
        let mods = ghostty_input_mods_e(rawValue: 0)
        let scrollMods = TerminalScrollModifiers(precision: true)
        ghostty_surface_mouse_pos(raw, Double(point.x), Double(point.y), mods)
        ghostty_surface_mouse_scroll(
            raw,
            Double(delta.x),
            Double(delta.y),
            scrollMods.rawValue
        )
    }
}

/// Invisible overlay placed alongside `TerminalSurfaceView` in the
/// `TerminalScreen` ZStack. On appear it walks the sibling view hierarchy
/// to find the `UITerminalView`, applies Zuko's input preferences, and
/// optionally captures taps for mouse-aware TUI apps.
///
/// Implemented as a `UIViewRepresentable` because the gesture needs to be
/// coordinated with the embedded `UITerminalView` (a UIKit view), not with
/// a SwiftUI wrapper. In keyboard mode this view opts out of hit-testing so
/// libghostty keeps its normal scroll / selection / keyboard-focus behavior.
/// In tap mode it captures touches before the terminal can become first
/// responder, which keeps the software keyboard hidden.
struct TouchMouseInput: UIViewRepresentable {
    let tapModeEnabled: Bool
    let accessoryKeysVisible: Bool

    func makeUIView(context: Context) -> InputView {
        InputView(
            tapModeEnabled: tapModeEnabled,
            accessoryKeysVisible: accessoryKeysVisible
        )
    }

    func updateUIView(_ uiView: InputView, context: Context) {
        uiView.apply(
            tapModeEnabled: tapModeEnabled,
            accessoryKeysVisible: accessoryKeysVisible
        )
    }
}

final class InputView: UIView {
    private lazy var tapGesture = UITapGestureRecognizer(
        target: self,
        action: #selector(handleTap(_:))
    )
    private lazy var panGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handlePan(_:))
    )
    private weak var attachedTerminal: UITerminalView?
    private var tapModeEnabled: Bool
    private var accessoryKeysVisible: Bool
    private let touchScrollMultiplier: CGFloat = 3.0

    init(tapModeEnabled: Bool, accessoryKeysVisible: Bool) {
        self.tapModeEnabled = tapModeEnabled
        self.accessoryKeysVisible = accessoryKeysVisible
        super.init(frame: .zero)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func commonInit() {
        backgroundColor = .clear
        panGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        panGesture.maximumNumberOfTouches = 1
        addGestureRecognizer(tapGesture)
        addGestureRecognizer(panGesture)
        // In keyboard mode this representable must not win hit-testing, or
        // taps would stop focusing the terminal / showing the software
        // keyboard. Tap mode flips this on to swallow touches before
        // libghostty's `touchesBegan` can call `becomeFirstResponder()`.
        isUserInteractionEnabled = tapModeEnabled
        accessibilityElementsHidden = true
        isAccessibilityElement = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        tryAttach()
    }

    func apply(tapModeEnabled: Bool, accessoryKeysVisible: Bool) {
        self.tapModeEnabled = tapModeEnabled
        self.accessoryKeysVisible = accessoryKeysVisible
        isUserInteractionEnabled = tapModeEnabled
        tryAttach()
        applyInputPreferences()
    }

    private func tryAttach() {
        guard window != nil, attachedTerminal == nil else { return }
        // We're a transparent overlay in the same ZStack as
        // TerminalSurfaceView. Walk siblings + descendants to find the
        // UITerminalView that TerminalSurfaceView's representable
        // created. Climb to a common ancestor first so we cover both
        // "sibling" and "cousin" layouts.
        var ancestor: UIView? = superview
        for _ in 0..<6 {
            if let a = ancestor, let terminal = findTerminal(in: a) {
                attachedTerminal = terminal
                applyInputPreferences()
                return
            }
            ancestor = ancestor?.superview
            if ancestor == nil { break }
        }
    }

    private func applyInputPreferences() {
        guard let terminal = attachedTerminal else { return }
        if tapModeEnabled, terminal.isFirstResponder {
            terminal.resignFirstResponder()
        }

        #if !targetEnvironment(macCatalyst)
            let desiredItems: [TerminalInputAccessoryItem] = accessoryKeysVisible
                ? TerminalInputAccessoryItem.defaultItems
                : []
            if terminal.inputAccessoryItems != desiredItems {
                terminal.inputAccessoryItems = desiredItems
            }
        #endif
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard tapModeEnabled else { return }
        guard let terminal = attachedTerminal,
               terminal.zuko_mouseCaptured()
        else { return }
        // Translate tap location to the terminal's coordinate space. The
        // recognizer is attached to this overlay; UIKit can still report the
        // same touch in the sibling terminal view's coordinates. Ghostty then
        // converts pixels → cells using the current grid metrics.
        let location = gesture.location(in: terminal)
        terminal.zuko_sendMouseClick(at: location)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        guard tapModeEnabled, let terminal = attachedTerminal else { return }

        switch gesture.state {
        case .began:
            if terminal.isFirstResponder {
                terminal.resignFirstResponder()
            }
            gesture.setTranslation(.zero, in: self)

        case .changed:
            let translation = gesture.translation(in: terminal)
            gesture.setTranslation(.zero, in: terminal)
            guard abs(translation.y) >= 0.5 || abs(translation.x) >= 0.5 else { return }
            let location = gesture.location(in: terminal)
            terminal.zuko_sendMouseScroll(
                at: location,
                delta: CGPoint(
                    x: translation.x * touchScrollMultiplier,
                    y: translation.y * touchScrollMultiplier
                )
            )

        case .cancelled, .failed, .ended:
            gesture.setTranslation(.zero, in: self)

        default:
            break
        }
    }

    private func findTerminal(in view: UIView) -> UITerminalView? {
        if let terminal = view as? UITerminalView { return terminal }
        for sub in view.subviews {
            if let found = findTerminal(in: sub) { return found }
        }
        return nil
    }
}
