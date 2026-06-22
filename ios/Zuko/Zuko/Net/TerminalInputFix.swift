import GhosttyTerminal
import ObjectiveC
import os
import UIKit

// Method swizzle that routes software-keyboard text input **around**
// libghostty's text-input pipeline, directly into the host-managed
// backend via `InMemoryTerminalSession.sendInput`.
//
// ## Why
//
// Libghostty's `ghostty_surface_text` on the host-managed backend does
// NOT invoke `receive_buffer_callback` — the bytes the user types never
// reach the wire. We first noticed this for Return (`"\n"` → Enter
// didn't work); the same broken path affects every ASCII keystroke.
// At a bash prompt characters *appear* to work because the kernel's
// line discipline echoes them — but in raw-mode TUI apps (zellij's
// tab mode, vim's insert mode) the byte is silently lost and the app
// never sees it.
//
// The accessory bar's Ctrl-J / Ctrl-M path works because it calls
// `InMemoryTerminalSession.sendInput(...)` directly, bypassing ghostty
// and writing straight to the wire via `writeHandler`. That's the
// proven-correct path for any byte we definitely want delivered.
//
// ## Fix
//
// Swizzle `-[UITerminalView insertText:]`. When the text is ASCII and
// there are no active sticky modifiers (Ctrl/Alt/Cmd armed on the
// accessory bar), bypass ghostty entirely and route the bytes straight
// to `session.sendInput(...)`. The original `insertText` still handles:
//
//   - **Sticky modifier sequences** (e.g. Ctrl-T in zellij). When a
//     sticky modifier is armed, the original `handleStickyTextInput`
//     path generates the control byte (`0x14` for Ctrl-T) via
//     `sendControlByte` → `sendInput`, which works correctly. The
//     sticky state is then consumed; the *next* `insertText("n")` has
//     no sticky active → our bypass fires → "n" reaches the wire.
//   - **Non-ASCII text** (IME composition — CJK, emoji). Those need
//     ghostty's marked-text / preedit handling, which `sendInput`
//     can't replicate.
//
// For ASCII text without sticky modifiers (the common case: typing in
// zellij tab mode, vim insert mode, bash prompt, etc.), we translate
// every LF (0x0A) to CR (0x0D) — the PTY's ICRNL flag then translates
// CR→LF for the reader — and collapse CRLF pairs in multi-line paste
// so we don't emit phantom empty command submissions.
//
// ## Detecting active sticky modifiers
//
// `TerminalStickyModifierState` and its `hasActiveModifiers` property
// are both `internal` in libghostty-spm. We Mirror-reflect on the
// stored `ctrl`/`alt`/`command` activation enums (also internal) and
// pattern-match against their `String(describing:)` form. Brittle
// against upstream enum-case renames, but the failure mode is fail-closed:
// if the reflection misses, we fall through to the original `insertText`
// so we don't accidentally bypass and drop a sticky Ctrl/Alt/Cmd modifier.
//
// Swizzle scope: `UITerminalView` is final in the SwiftUI representable,
// so subclassing isn't an option. Method swizzling is the lightest-touch
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
                logger.error("UITerminalView.insertText swizzle failed to register — software keyboard input will be unreliable")
                assertionFailure("Could not resolve UITerminalView.insertText(_:) for swizzle")
                return
            }
            method_exchangeImplementations(original, swizzled)
            logger.notice("UITerminalView.insertText swizzle installed")
        }
    }

    @objc private func zuko_insertText(_ text: String) {
        // After `method_exchangeImplementations`, this method IS the
        // original implementation — calling it forwards to the pre-swizzle
        // code. Use it for cases we don't want to claim (sticky modifiers,
        // non-ASCII text).
        if zuko_hardwareKeyWasAlreadyHandled() {
            // Hardware keyboard presses are delivered first through
            // `pressesBegan`, which may already send the byte directly to
            // the in-memory backend and set `hardwareKeyHandled` so UIKit's
            // follow-up `insertText` is suppressed. Preserve that upstream
            // duplicate-suppression path before our ASCII bypass can fire.
            self.zuko_insertText(text)
            return
        }

        let isAllASCII = text.utf8.allSatisfy { $0 < 0x80 }
        if isAllASCII, zuko_hasActiveStickyModifiers() == false, case let .inMemory(session) = configuration.backend {
            // Bypass ghostty for plain ASCII input. Translate LF → CR
            // (canonical Unix Return convention; the PTY's ICRNL flag
            // translates CR→LF for the reader) and collapse CRLF pairs
            // in multi-line paste so we don't double-submit.
            var bytes = Data()
            bytes.reserveCapacity(text.utf8.count)
            var prevWasCR = false
            for byte in text.utf8 {
                if byte == 0x0A {
                    if !prevWasCR {
                        bytes.append(0x0D)
                    }
                    // else: this LF immediately follows a CR — drop it
                    // (avoids emitting two line endings for one paste
                    // newline).
                    prevWasCR = false
                } else {
                    bytes.append(byte)
                    prevWasCR = byte == 0x0D
                }
            }
            logger.debug("insertText bypass: \(text.utf8.count) utf8 bytes → \(bytes.count) wire bytes via sendInput")
            session.sendInput(bytes)
            return
        }
        // Sticky modifier active, non-ASCII text (IME), or no in-memory
        // backend — let ghostty handle it via the original path.
        self.zuko_insertText(text)
    }

    /// Whether any accessory-bar sticky modifier (Ctrl/Alt/Cmd) is currently
    /// armed or locked. We need to know because the original
    /// `insertText` consumes the modifier and dispatches via
    /// `handleStickyTextInput` → `sendControlByte` → `sendInput`, which
    /// works correctly; bypassing it would lose the modifier.
    ///
    /// Reads the internal `stickyModifiers` state via `Mirror` reflection
    /// (the type itself is internal in libghostty-spm). The activation
    /// enum cases are matched as strings so we don't need to import the
    /// internal enum — brittle against upstream renames, but a missed match
    /// returns `nil` so callers fail closed to the original path.
    private func zuko_hasActiveStickyModifiers() -> Bool? {
        #if targetEnvironment(macCatalyst)
            return false
        #else
            let viewMirror = Mirror(reflecting: self)
            guard let sticky = viewMirror.descendant("stickyModifiers") else {
                return nil
            }
            let stickyMirror = Mirror(reflecting: sticky)
            for mod in ["ctrl", "alt", "command"] {
                guard let activation = stickyMirror.descendant(mod) else {
                    return nil
                }
                let desc = String(describing: activation).lowercased()
                if desc == "armed" || desc == "locked" {
                    return true
                }
                if desc != "inactive" {
                    return nil
                }
            }
            return false
        #endif
    }

    /// True when libghostty-spm's hardware-key path has already handled this
    /// keypress and expects `insertText` to only clear the suppression flag.
    private func zuko_hardwareKeyWasAlreadyHandled() -> Bool {
        Mirror(reflecting: self).children
            .first { $0.label == "hardwareKeyHandled" }?
            .value as? Bool ?? false
    }
}

private let logger = Logger(subsystem: "dev.adonm.zuko", category: "TerminalInputFix")
