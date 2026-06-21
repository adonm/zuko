import GhosttyTerminal
import ObjectiveC
import os
import UIKit

// Method swizzle that routes software-keyboard Return **around** libghostty's
// text-input pipeline, directly into the host-managed backend via
// `InMemoryTerminalSession.sendInput`.
//
// ## Why
//
// The iOS software keyboard's Return key calls `insertText("\n")` (UIKit
// UIKeyInput convention). Libghostty's `ghostty_surface_text` consumes that
// text through its IME/text-input path, which on the host-managed backend
// does NOT invoke `receive_buffer_callback` — so the byte never reaches the
// wire, and Enter doesn't trigger `accept-line` in the remote shell. The
// exec backend would normally translate via `queueWrite`'s `linefeed` flag,
// but the host-managed patch ignores that flag (see
// `Patches/ghostty/0002-host-managed-io.patch`).
//
// The accessory bar's Ctrl-J/Ctrl-M path works because it calls
// `InMemoryTerminalSession.sendInput(...)` directly, bypassing ghostty and
// writing straight to the wire via the `writeHandler` closure. That's the
// proven-correct path for any byte we definitely want delivered.
//
// ## Fix
//
// Swizzle `-[UITerminalView insertText:]`. When the text contains a newline:
//
//   1. Pull the `InMemoryTerminalSession` off `self.configuration.backend`
//      (the same backend the accessory bar reads).
//   2. Translate every LF (0x0A) to CR (0x0D). The PTY's ICRNL flag then
//      translates CR→LF for the reader, so both raw-mode readline (`\r`
//      binding) and canonical-mode NL line-termination work.
//   3. Hand the bytes to `session.sendInput(...)` — direct to the wire,
//      ghostty never sees them.
//
// For text without a newline (letters, digits, IME composition, etc.), fall
// through to the original `insertText` — ghostty's text-input path handles
// those correctly, and routing them through `sendInput` would lose any
// client-side echo or IME bookkeeping ghostty does.
//
// Also collapses CRLF pairs in multi-line paste to a single CR, so a paste
// of `"foo\r\nbar\r\n"` doesn't submit `foo` and then an empty command before
// `bar`.
//
// Swizzle scope: `UITerminalView` is final in the SwiftUI representable, so
// subclassing isn't an option. Method swizzling is the lightest-touch
// intercept point — affects only `-[UITerminalView insertText:]`, applied
// once at app launch via `TerminalInputFix.apply()` (called from
// `ZukoApp.init`).
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
            else {
                // If the swizzle fails to register (e.g. the upstream
                // package renamed insertText), surface it loudly in debug
                // so we notice immediately. In release, log via os.Logger
                // so it's visible in Console.app.
                logger.error("UITerminalView.insertText swizzle failed to register — Return key will not work")
                assertionFailure("Could not resolve UITerminalView.insertText(_:) for swizzle")
                return
            }
            method_exchangeImplementations(original, swizzled)
            logger.notice("UITerminalView.insertText swizzle installed")
        }
    }

    @objc private func zuko_insertText(_ text: String) {
        // After `method_exchangeImplementations`, this method IS the original
        // implementation — calling it here forwards to the pre-swizzle code.
        // For any text containing LF, bypass ghostty entirely and route the
        // bytes straight to the in-memory backend via `sendInput` (the
        // same path the accessory bar uses for Ctrl-J / Ctrl-M, which the
        // user has confirmed works).
        if text.contains("\n"), case let .inMemory(session) = configuration.backend {
            // Collapse CRLF pairs to a single CR first (multi-line paste
            // from clipboard), then any remaining bare LF → CR. UTF-8
            // encodes U+000A and U+000D as single bytes, so byte-wise
            // replacement is correct for any text containing them.
            var bytes = Data()
            bytes.reserveCapacity(text.utf8.count)
            var prevWasCR = false
            for byte in text.utf8 {
                if byte == 0x0A {
                    if prevWasCR {
                        // CRLF pair — drop the LF, keep the CR we already emitted.
                    } else {
                        bytes.append(0x0D)
                    }
                    prevWasCR = false
                } else {
                    bytes.append(byte)
                    prevWasCR = byte == 0x0D
                }
            }
            logger.debug("insertText bypass: \(text.utf8.count) bytes → \(bytes.count) bytes via sendInput")
            session.sendInput(bytes)
            return
        }
        // No LF — let ghostty handle it normally.
        self.zuko_insertText(text)
    }
}

private let logger = Logger(subsystem: "dev.adonm.zuko", category: "TerminalInputFix")
