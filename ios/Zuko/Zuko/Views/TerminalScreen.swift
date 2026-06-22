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
    @State private var showingLogs = false
    @State private var accessoryKeysVisible = false
    @State private var inputMode: TerminalInputMode = .keyboard
    @FocusState private var terminalFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            terminalContent
            if let banner = statusMessage {
                statusBar(banner)
            }
        }
        .background(Color.black)
        .navigationTitle(connection.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Refresh stays as a top-level icon — it's the one users reach
            // for mid-session (after a garbled reconnect, etc.). Input-mode
            // toggles are also top-level because they affect every tap/key.
            // Font and theme are set-once-and-forget, so they fold into a
            // single overflow Menu with Disconnect (destructive, lives behind
            // a tap to avoid accidental hits).
            ToolbarItemGroup(placement: .topBarTrailing) {
                refreshButton
                accessoryKeysButton
                inputModeButton
                Menu {
                    Menu("Font size") {
                        Button("A−  smaller") {
                            themeStore.setFontSize(themeStore.fontSize - 1)
                        }
                        Text("\(Int(themeStore.fontSize.rounded())) pt")
                        Button("A+  larger") {
                            themeStore.setFontSize(themeStore.fontSize + 1)
                        }
                        Divider()
                        Button("Reset to \(Int(ThemeStore.defaultFontSize)) pt") {
                            themeStore.setFontSize(ThemeStore.defaultFontSize)
                        }
                    }
                    Menu("Color theme") {
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
                        Button {
                            themeStore.setTheme(nil)
                        } label: {
                            if themeStore.selectedName == nil {
                                Label("Default (Afterglow / Alabaster)", systemImage: "checkmark")
                            } else {
                                Text("Default (Afterglow / Alabaster)")
                            }
                        }
                        Divider()
                        Button("Browse all (\(GhosttyThemeCatalog.allThemes.count))…") {
                            showingThemeBrowser = true
                        }
                    }
                    Divider()
                    Button("Logs…") {
                        showingLogs = true
                    }
                    Divider()
                    Button("Disconnect", role: .destructive) {
                        session.disconnect()
                        dismiss()
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Appearance and session")
            }
        }
        .sheet(isPresented: $showingThemeBrowser) {
            ThemeBrowserView()
                .environment(themeStore)
        }
        .sheet(isPresented: $showingLogs) {
            LogsView()
        }
        .task {
            // Apply persisted appearance prefs before connect so the first
            // frame already has them. Each setter is a no-op when the value
            // matches the controller's current state, so the cold-start
            // path (defaults) costs only three cheap equality checks.
            terminalState.setTheme(themeStore.currentTheme)
            applyFontSize(themeStore.fontSize)
            // Attach the session's host-managed I/O backend before connect so
            // the first RESIZE carries the surface's actual grid size. This
            // access also realises `session.inMemorySession` (lazy) before the
            // read loop can touch it.
            terminalState.configuration = TerminalSurfaceOptions(
                backend: .inMemory(session.inMemorySession)
            )
            session.connect(ticket: connection.ticket)
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

    /// The terminal surface + touch-mouse overlay. Extracted from `body`
    /// so Swift's type-checker can resolve the parent ZStack in reasonable
    /// time — putting these in the body alongside the toolbar Menu above
    /// pushes the body over the compiler's complexity budget.
    private var terminalContent: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TerminalSurfaceView(context: terminalState)
                .terminalFocused($terminalFocused)
                .onAppear {
                    terminalFocused = inputMode == .keyboard
                }
                .ignoresSafeArea(.container, edges: [.bottom])
            // Touch-to-mouse bridge for TUI apps that enable mouse capture
            // (btop, yazi, zellij, vim+`set mouse=a`). See TouchMouseInput.swift.
            TouchMouseInput(
                tapModeEnabled: inputMode == .tap,
                accessoryKeysVisible: accessoryKeysVisible
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.bottom])
        }
    }

    private enum TerminalInputMode {
        case keyboard
        case tap
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

    /// Ask the host-side PTY to redraw without injecting a keystroke. We send a
    /// same-size RESIZE so shells/fullscreen TUIs/multiplexers get SIGWINCH and
    /// repaint. This is gentler than the old local RIS + Ctrl-L combo: it
    /// doesn't wipe Ghostty state and doesn't clear zellij/tmux panes.
    private var refreshButton: some View {
        Button {
            session.requestRedraw()
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel("Refresh terminal")
    }

    /// Show/hide libghostty's iOS shortcut-key accessory row. The default is
    /// hidden so first tap gives the plain software keyboard only.
    private var accessoryKeysButton: some View {
        Button {
            accessoryKeysVisible.toggle()
            if inputMode == .keyboard {
                terminalFocused = true
            }
        } label: {
            Image(systemName: accessoryKeysVisible ? "command.circle.fill" : "command.circle")
        }
        .accessibilityLabel(accessoryKeysVisible ? "Hide accessory keys" : "Show accessory keys")
    }

    /// Switch between normal keyboard input and tap/cursor input. Tap mode
    /// intentionally drops first-responder focus so the software keyboard stays
    /// hidden while taps are delivered to mouse-aware terminal apps.
    private var inputModeButton: some View {
        Button {
            switch inputMode {
            case .keyboard:
                inputMode = .tap
                terminalFocused = false
            case .tap:
                inputMode = .keyboard
                terminalFocused = true
            }
        } label: {
            Image(systemName: inputMode == .tap ? "hand.tap.fill" : "hand.tap")
        }
        .accessibilityLabel(inputMode == .keyboard ? "Enable tap mode" : "Disable tap mode")
        .accessibilityHint("Tap mode hides the keyboard and sends taps to mouse-aware terminal apps.")
    }

    private var statusMessage: String? {
        switch session.status {
        case .connecting:
            return "Connecting to host…"
        case .reconnecting(let attempt, let delay, let reason):
            return "Connection lost: \(reason). Reconnecting in \(delay)s (try \(attempt)); reattaches if the host lease is alive…"
        case .disconnected(let reason):
            return reason == "disconnected" ? nil : reason
        case .failed(let reason):
            return "Failed: \(reason)"
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
