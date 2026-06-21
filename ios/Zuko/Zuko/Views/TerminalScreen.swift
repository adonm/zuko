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

            if let banner = statusMessage {
                statusBar(banner)
            }
        }
        .background(Color.black)
        .navigationTitle(connection.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Refresh stays as a top-level icon — it's the one users reach
            // for mid-session (after a garbled reconnect, etc.). Font and
            // theme are set-once-and-forget, so they fold into a single
            // overflow Menu with Disconnect (destructive, lives behind a
            // tap to avoid accidental hits). Two trailing items instead of
            // four keeps the inline nav title from getting squeezed on
            // iPhone.
            ToolbarItemGroup(placement: .topBarTrailing) {
                refreshButton
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

    /// Force-clear the local surface and trigger a redraw on the host. Use
    /// after a garbled resume replay (fullscreen TUI apps like `btop` leave
    /// the snapshot mid-ANSI-sequence) or any time the display looks stuck.
    ///
    /// Two-step:
    ///   1. RIS (`\x1b c`) straight to the local ghostty surface via
    ///      `receive(...)` — bypasses the wire, resets all terminal state
    ///      (screen, scrollback, SGR attributes, alternate buffer) so any
    ///      half-rendered frame is wiped before the redraw arrives.
    ///   2. Ctrl-L (`\x0c`, form feed) up the wire to the host shell/TUI.
    ///      Universal "redraw" key: bash/readline clears + redraws the
    ///      prompt; vim/less/btop/man redraw their UI. Apps that don't
    ///      intercept it just see a form feed — terminal clears the screen
    ///      and the cursor jumps home, which is also what we want.
    private var refreshButton: some View {
        Button {
            // Local hard reset. Goes to the surface only — not the wire.
            session.inMemorySession.receive(Data("\u{1B}c".utf8))
            // Ctrl-L up the wire. writeHandler's LF→CR translation doesn't
            // affect 0x0C, so bypass via sendInput (skips the libghostty
            // surface callback path; identical bytes either way).
            session.inMemorySession.sendInput(Data([0x0C]))
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel("Refresh terminal")
    }

    private var statusMessage: String? {
        switch session.status {
        case .connecting:
            return "Connecting to host…"
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
