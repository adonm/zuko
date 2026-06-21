import GhosttyTerminal
import ObjectiveC
import SwiftUI
import UIKit

/// SwiftUI view modifier that finds the underlying `UITerminalView` created
/// by `TerminalSurfaceView` and toggles the system software keyboard via the
/// inherited `UIResponder.inputView` property.
///
/// ## How the suppression works
///
/// UIKit decides what to display above/below the system keyboard by reading
/// `inputView` and `inputAccessoryView` on the first responder:
/// - `inputView == nil` (default) → UIKit shows the standard system keyboard.
/// - `inputView != nil` → UIKit shows that view *instead* of the keyboard.
///
/// `UITerminalView` overrides only `inputAccessoryView` (to provide the
/// Esc/Tab/arrows/modifiers/Paste bar) — `inputView` is inherited from
/// `UIResponder`. The public UIKit header declares `inputView` as
/// `readonly`, so plain assignment (`view.inputView = …`) won't compile
/// against a UIView subclass that didn't re-declare it. The readwrite half
/// is a private ivar on UIResponder; we write it directly via the ObjC
/// runtime (see `FinderUIView.apply()`). Earlier iOS versions let KVC
/// (`setValue(_:forKey:)`) reach the same storage via
/// `accessInstanceMethodsDirectly`, but iOS 26 tightened UIView's
/// `setValue:forKey:` override to raise `NSUnknownKeyException` for
/// `inputView` — and Swift can't catch `NSException`, so that path now
/// terminates the process.
///
/// Setting `inputView` to an empty `UIView` makes UIKit swap the system
/// keyboard for that empty view, leaving the accessory bar visible on its
/// own. That gives the terminal ~70% of the screen back while keeping every
/// key in the accessory bar functional.
///
/// Toggling while the terminal is already first responder requires
/// `reloadInputViews()` to take effect immediately; a plain setter write is
/// picked up only on the next `becomeFirstResponder`.
///
/// ## Why introspection (vs. a UIViewRepresentable subclass)
///
/// Replacing `TerminalSurfaceView` with a custom `UIViewRepresentable` would
/// let us set up a `UITerminalView` subclass directly, but we'd have to
/// re-implement the colour-scheme adoption, focus binding, and lifecycle
/// wiring the package's representable already does. Walking the rendered view
/// hierarchy to find the existing `UITerminalView` keeps `TerminalSurfaceView`
/// intact and confines the keyboard hack to one file.
extension View {
    /// When `suppress` is true, hides the system software keyboard on the
    /// terminal while keeping the accessory bar visible. Re-evaluates on
    /// every SwiftUI update so the binding stays in sync.
    func terminalKeyboardSuppression(_ suppress: Bool) -> some View {
        background(
            TerminalKeyboardFinder(suppress: suppress)
                .frame(width: 0, height: 0)
                .opacity(0)
        )
    }
}

/// Invisible `UIViewRepresentable` that performs the actual hierarchy walk.
/// Re-runs `scan()` on every update so flips in `suppress` propagate.
private struct TerminalKeyboardFinder: UIViewRepresentable {
    let suppress: Bool

    func makeUIView(context: Context) -> FinderUIView {
        FinderUIView(suppress: suppress)
    }

    func updateUIView(_ uiView: FinderUIView, context: Context) {
        guard uiView.suppress != suppress else { return }
        uiView.suppress = suppress
        uiView.scan()
    }

    /// `didMoveToWindow` + an explicit `scan()` cover the two timings we
    /// care about: cold start (FinderUIView lands in the hierarchy at the
    /// same time as the UITerminalView) and toggle updates (hierarchy
    /// already settled, just need to reapply).
    final class FinderUIView: UIView {
        var suppress: Bool

        init(suppress: Bool) {
            self.suppress = suppress
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            scan()
        }

        func scan() {
            guard window != nil else { return }
            // Defer one runloop: TerminalSurfaceView's underlying
            // UITerminalView is created in the same SwiftUI layout pass as
            // this FinderUIView, so a synchronous walk would race and miss
            // it. The async hop lets SwiftUI finish attaching siblings.
            DispatchQueue.main.async { [weak self] in
                self?.apply()
            }
        }

        private func apply() {
            guard let terminal = findTerminal() else { return }
            // UIResponder's `inputView` is publicly `readonly`; the backing
            // storage is a private ivar. The original implementation reached
            // it via `setValue(_:forKey:)`, but iOS 26 tightened UIView's KVC
            // override to raise `NSUnknownKeyException` for `inputView` — and
            // Swift can't catch NSException, so the process terminates with
            // SIGABRT (see testflight_feedback/crashlog.crash, frames 4-5).
            //
            // Write the backing ivar directly via the ObjC runtime — the same
            // storage KVC's `accessInstanceMethodsDirectly` reached before
            // UIView's override started short-circuiting the lookup. Safe
            // across iOS versions: if the ivar is renamed in a future release
            // we silently no-op (the terminal still works; only the
            // keyboard-suppression shortcut degrades).
            guard let ivar = Self.inputViewIvar(of: terminal) else { return }
            // `object_setIvarWithStrongDefault` honors the ivar's declared
            // memory semantics (strong by default for UIView references), so
            // ARC-style retain/release happens correctly on the old and new
            // values. `nil` is the documented "use system keyboard" value.
            let newValue: UIView? = suppress ? UIView(frame: .zero) : nil
            object_setIvarWithStrongDefault(terminal, ivar, newValue)
            // `reloadInputViews` refreshes the keyboard system's read of
            // inputView/inputAccessoryView while first responder. If the
            // terminal isn't first responder the new value is picked up on
            // the next becomeFirstResponder — no reload needed.
            if terminal.isFirstResponder {
                terminal.reloadInputViews()
            }
        }

        /// Walks the class hierarchy looking for the UIResponder-private ivar
        /// that backs `inputView`. UIResponder historically stores it as
        /// `_inputView`; some Apple subclasses shadow it as `inputView`.
        /// Returns `nil` if neither is present (e.g., on a future OS that
        /// reworked responder storage) so callers can no-op safely.
        private static func inputViewIvar(of responder: UIResponder) -> Ivar? {
            let candidates = ["_inputView", "inputView"]
            var cls: AnyClass? = type(of: responder)
            while let c = cls {
                for name in candidates {
                    if let ivar = class_getInstanceVariable(c, name) {
                        return ivar
                    }
                }
                cls = class_getSuperclass(c)
            }
            return nil
        }

        /// Walk up to the closest common ancestor (the SwiftUI platform
        /// view that hosts both this FinderUIView and TerminalSurfaceView's
        /// UITerminalView), then descend looking for a `UITerminalView`.
        /// A breadth-first descent would be slightly faster but the tree
        /// here is ~3 levels deep so the simpler DFS is fine.
        private func findTerminal() -> UITerminalView? {
            // Climb to a sensible ancestor. SwiftUI typically wraps sibling
            // platforms views under one `_UIHostingView`, so going up 2-3
            // levels then descending lands us in TerminalSurfaceView's tree.
            var ancestor: UIView? = superview
            for _ in 0..<6 {
                if let a = ancestor, let found = descend(a) { return found }
                ancestor = ancestor?.superview
                if ancestor == nil { break }
            }
            return descend(self)
        }

        private func descend(_ view: UIView) -> UITerminalView? {
            if let terminal = view as? UITerminalView { return terminal }
            for sub in view.subviews {
                if let found = descend(sub) { return found }
            }
            return nil
        }
    }
}
