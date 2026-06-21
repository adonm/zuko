import GhosttyTerminal
import ObjectiveC
import UIKit

// Method swizzle that translates `"\n"` → `"\r"` in `-[UITerminalView insertText:]`
// before libghostty's text input pipeline sees it.
//
// Why: the iOS software keyboard's Return key calls `insertText("\n")` (UIKit
// UIKeyInput convention). Libghostty's `ghostty_surface_text` consumes that
// text through its IME/text-input path, which on the host-managed backend
// does NOT reliably forward raw `0x0A` via `receive_buffer_callback` — the
// exec backend's `queueWrite` `linefeed` flag (which would normally
// translate LF→CRLF) is ignored by the host-managed patch (see
// `Patches/ghostty/0002-host-managed-io.patch`). Result: Enter didn't
// trigger `accept-line` in readline, even though Ctrl-J (sent via
// `InMemoryTerminalSession.sendInput` which bypasses ghostty entirely)
// worked fine (v0.5.3 confirmed the wire path is OK).
//
// Fix: swap the byte before ghostty processes it. The standard terminal
// convention for the Return key is CR (`\r`, 0x0D); the kernel's ICRNL flag
// on the PTY then translates CR→LF for the reader, so both readline's `\r`
// binding and canonical-mode NL line-termination work.
//
// We also translate CRLF (`\r\n`) → just `\r` to avoid sending two line
// endings when a multi-line paste includes both, which would otherwise
// produce phantom empty command submissions.
//
// Swizzle scope: `UITerminalView` is final in the SwiftUI representable,
// so subclassing isn't an option. Method swizzling is the lightest-touch
// intercept point — affects only `-[UITerminalView insertText:]`, applied
// once at app launch via `TerminalInputFix.apply()`.
extension UITerminalView {
    /// Install the swizzle. Idempotent — the dispatch_once-style `static let`
    /// inside makes calling it more than once a no-op.
    static func installInputFix() {
        _ = Installer.shared
    }

    private final class Installer: @unchecked Sendable {
        static let shared = Installer()
        private init() {
            guard
                let original = class_getInstanceMethod(
                    UITerminalView.self,
                    #selector(UITerminalView.insertText(_:))
                ),
                let swizzled = class_getInstanceMethod(
                    UITerminalView.self,
                    #selector(zuko_insertText(_:))
                )
            else { return }
            method_exchangeImplementations(original, swizzled)
        }
    }

    @objc private func zuko_insertText(_ text: String) {
        // After `method_exchangeImplementations`, this method IS the original
        // implementation — calling it here forwards to the pre-swizzle code.
        // Translate every LF to CR so ghostty's text pipeline receives the
        // canonical Unix Return byte (CR; ICRNL on the PTY handles the
        // LF translation for the reader). For CRLF input (a multi-line
        // paste from the clipboard), the trailing LF in each `\r\n` pair
        // collapses into the leading CR so we don't double-submit.
        let needsTranslation = text.contains("\n")
        let translated = needsTranslation
            ? text.replacingOccurrences(of: "\r\n", with: "\r")
                .replacingOccurrences(of: "\n", with: "\r")
            : text
        self.zuko_insertText(translated)
    }
}
