import GhosttyTerminal
import SwiftUI

@main
struct ZukoApp: App {
    // @State (not @StateObject) because ConnectionStore / ThemeStore are
    // @Observable — the macro handles change tracking, so SwiftUI's new
    // Observation-based ownership applies. @StateObject still works on
    // @Observable types but emits a runtime hint about preferring @State.
    @State private var store = ConnectionStore()
    @State private var themeStore = ThemeStore()

    init() {
        // Translate `"\n"` → `"\r"` in UITerminalView.insertText before
        // libghostty consumes it. Software-keyboard Return otherwise lands
        // as LF where shells expect CR. See TerminalInputFix.swift.
        UITerminalView.installInputFix()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(themeStore)
                // Follow the system color scheme (was force-dark pre v0.5).
                // libghostty-spm's default theme has light (Alabaster) and
                // dark (Afterglow) variants; picked themes apply to both.
                .tint(.orange)
        }
    }
}
