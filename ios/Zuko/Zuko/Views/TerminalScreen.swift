import GhosttyTerminal
import GhosttyTheme
import SwiftUI

/// The live terminal. Owns the Iroh session and embeds GhosttyTerminal's
/// native SwiftUI `TerminalSurfaceView`, wired to the session's
/// host-managed I/O backend.
struct TerminalScreen: View {
    let connection: Connection

    // IrohSession stays ObservableObject — it has 1 @Published property
    // (`status`) + a dozen+ private/internal fields, so migrating to
    // @Observable would mean stamping @ObservationIgnored on everything
    // except `status`. The current @Published opt-in pattern is cleaner
    // for that shape, so @StateObject stays here.
    @StateObject private var session = IrohSession()

    /// GhosttyTerminal's observable state container. Initial font size comes
    /// from `ThemeStore.fontSize` (persisted); later changes flow through
    /// `terminalState.setTerminalConfiguration(...)` in `.onChange`.
    /// `TerminalViewState` is from libghostty-spm and stays
    /// `ObservableObject`-based — hence @StateObject, not @State.
    @StateObject private var terminalState = TerminalViewState(
        theme: .default,
        terminalConfiguration: TerminalConfiguration(startingFrom: .default) {
            $0.withFontSize(ThemeStore.defaultFontSize)
        }
    )

    @Environment(ConnectionStore.self) private var store
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dismiss) private var dismiss

    @State private var showingThemeBrowser = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TerminalSurfaceView(context: terminalState)
                .ignoresSafeArea(.container, edges: [.bottom])
                // Drive the system software keyboard suppression from the
                // persisted toggle. The modifier walks the view hierarchy
                // to find the underlying UITerminalView and sets its
                // inputView; re-evaluates on every SwiftUI update.
                .terminalKeyboardSuppression(themeStore.compactKeyboard)

            if let banner = statusMessage {
                statusBar(banner)
            }
        }
        .background(Color.black)
        .navigationTitle(connection.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                fontMenu
                themeMenu
                keyboardToggleButton
                Button("Disconnect") {
                    session.disconnect()
                    dismiss()
                }
            }
        }
        .sheet(isPresented: $showingThemeBrowser) {
            ThemeBrowserView()
                .environment(themeStore)
        }
        .task {
            // Apply persisted appearance prefs before connect so the first
            // frame already has them. Each setter is a no-op when the value
            // matches the controller's current state, so the cold-start
            // path (defaults) costs only three cheap equality checks.
            terminalState.setTheme(themeStore.currentTheme)
            applyFontSize(themeStore.fontSize)
            // Resume the prior session if we have a saved id for this host;
            // the host replays recent output.
            session.onSessionID = { [connection] id in
                store.updateSessionID(id, for: connection)
            }
            // Attach the session's host-managed I/O backend before connect so
            // the first HELLO carries the surface's actual grid size. This
            // access also realises `session.inMemorySession` (lazy) before the
            // read loop can touch it.
            terminalState.configuration = TerminalSurfaceOptions(
                backend: .inMemory(session.inMemorySession)
            )
            session.connect(ticket: connection.ticket, sessionID: connection.lastSessionID)
        }
        .onChange(of: themeStore.selectedName) {
            // Live theme switch from the toolbar picker / browser sheet.
            terminalState.setTheme(themeStore.currentTheme)
        }
        .onChange(of: themeStore.fontSize) {
            // Live font size change from the toolbar stepper.
            applyFontSize(themeStore.fontSize)
        }
        .onDisappear {
            session.disconnect()
        }
    }

    /// Rebuilds the terminal configuration with the current font size and
    /// pushes it to the controller. The package doesn't expose a single
    /// "set just the font size" call — `setTerminalConfiguration` replaces
    /// the whole per-session override, so we compose it from `.default`
    /// + the size. Themes don't carry font settings (only colors), so this
    /// doesn't fight with `setTheme`.
    private func applyFontSize(_ size: Float) {
        let config = TerminalConfiguration(startingFrom: .default) {
            $0.withFontSize(size)
        }
        terminalState.setTerminalConfiguration(config)
    }

    /// Type-size Menu: A− / A+ / reset, plus the live value. Stepper would
    /// also work but Buttons give bigger tap targets and the menu closes
    /// after each tap (acceptable — coarse adjustment; pinch-to-zoom covers
    /// fine adjustment on the surface itself).
    private var fontMenu: some View {
        Menu {
            Section("Font size") {
                Button("A−  smaller") {
                    themeStore.setFontSize(themeStore.fontSize - 1)
                }
                Text("\(Int(themeStore.fontSize.rounded())) pt")
                Button("A+  larger") {
                    themeStore.setFontSize(themeStore.fontSize + 1)
                }
            }
            Section {
                Button("Reset to \(Int(ThemeStore.defaultFontSize)) pt") {
                    themeStore.setFontSize(ThemeStore.defaultFontSize)
                }
            }
        } label: {
            Image(systemName: "textformat")
        }
        .accessibilityLabel("Font size")
    }

    /// Palette-button dropdown for quick theme switching. Popular section +
    /// "Browse all…" (opens the searchable sheet with the full 485 catalog).
    /// Tap-to-apply; `.onChange(of: themeStore.selectedName)` above pushes
    /// the new theme to the terminal surface immediately.
    private var themeMenu: some View {
        Menu {
            Section("Popular") {
                ForEach(themeStore.popularThemes) { theme in
                    Button {
                        themeStore.setTheme(theme.name)
                    } label: {
                        if themeStore.selectedName == theme.name {
                            Label(theme.name, systemImage: "checkmark")
                        } else {
                            Text(theme.name)
                        }
                    }
                }
            }
            Section {
                Button {
                    themeStore.setTheme(nil)
                } label: {
                    if themeStore.selectedName == nil {
                        Label("Default (Afterglow / Alabaster)", systemImage: "checkmark")
                    } else {
                        Text("Default (Afterglow / Alabaster)")
                    }
                }
            }
            Button("Browse all (\(GhosttyThemeCatalog.allThemes.count))…") {
                showingThemeBrowser = true
            }
        } label: {
            Image(systemName: "paintpalette")
        }
        .accessibilityLabel("Color theme")
    }

    /// Toggle the compact-keyboard mode. When on, the system software
    /// keyboard is suppressed (only the translucent accessory bar shows)
    /// via the `terminalKeyboardSuppression` modifier on the surface.
    /// The icon swaps to make the state obvious.
    private var keyboardToggleButton: some View {
        Button {
            themeStore.setCompactKeyboard(!themeStore.compactKeyboard)
        } label: {
            Image(systemName: themeStore.compactKeyboard
                ? "keyboard.chevron.compact.down.fill"
                : "keyboard.chevron.compact.down")
        }
        .accessibilityLabel(themeStore.compactKeyboard
            ? "Show software keyboard"
            : "Hide software keyboard (keep accessory bar)")
    }

    private var statusMessage: String? {
        switch session.status {
        case .connecting:
            return "Connecting to host…"
        case .reconnecting:
            return "Reconnecting…"
        case .stalled:
            return "Connection stalled — will resume"
        case .failed(let reason):
            return "Failed: \(reason)"
        case .disconnected(let reason):
            return reason == "disconnected" ? nil : reason
        case .connected, .idle:
            return nil
        }
    }

    private func statusBar(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.opacity)
    }
}
