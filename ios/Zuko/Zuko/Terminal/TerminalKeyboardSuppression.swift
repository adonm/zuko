import GhosttyTerminal
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
/// `readonly`; the readwrite half lives in a private class extension, so
/// plain assignment (`view.inputView = …`) won't compile against a UIView
/// subclass that didn't re-declare it. KVC (`setValue(_:forKey:)`) reaches
/// the private setter; this is the same path `UITextField`'s public
/// readwrite override forwards to internally. The pattern is widely used
/// (calculator apps, scanner apps, etc.) and stable.
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
            // KVC reaches the private readwrite half of UIResponder.inputView
            // (see extension docstring). Plain `terminal.inputView = …` won't
            // compile — UITerminalView inherits the readonly declaration.
            // `nil` is the documented "use system keyboard" value.
            terminal.setValue(
                suppress ? UIView(frame: .zero) : nil,
                forKey: "inputView"
            )
            // `reloadInputViews` refreshes the keyboard system's read of
            // inputView/inputAccessoryView while first responder. If the
            // terminal isn't first responder the new value is picked up on
            // the next becomeFirstResponder — no reload needed.
            if terminal.isFirstResponder {
                terminal.reloadInputViews()
            }
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

