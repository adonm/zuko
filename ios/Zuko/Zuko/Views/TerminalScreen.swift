import GhosttyTerminal
import GhosttyTheme
import SwiftUI
import UIKit

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
    @Environment(\.scenePhase) private var scenePhase

    @State private var showingThemeBrowser = false
    @State private var showingLogs = false
    @State private var showingRePair = false
    @State private var accessoryKeysVisible = false
    @State private var inputMode: TerminalInputMode = .keyboard
    @State private var showingInputHint = false
    @State private var storeError: String?
    @AppStorage("hasShownTerminalInputHint") private var hasShownInputHint = false
    @FocusState private var terminalFocused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            terminalContent
            if let banner = statusMessage {
                statusOverlay(banner)
            }
            if showingInputHint {
                inputHint
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
        .background(Color.black)
        .navigationTitle(connection.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Refresh stays top-level for mid-session redraws. The two input
            // toggles share one labelled menu so the compact iPhone toolbar
            // doesn't rely on two unfamiliar stateful glyphs.
            ToolbarItemGroup(placement: .topBarTrailing) {
                refreshButton
                inputMenu
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
        .sheet(isPresented: $showingRePair) {
            AddConnectionView(expectedHostNodeID: hostNodeID(forTicket: connection.ticket)) { repairedConnection in
                session.disconnect()
                session.connect(ticket: repairedConnection.ticket)
            }
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
        .onChange(of: session.status) { _, status in
            handleStatusChange(status)
        }
        .onChange(of: scenePhase) { _, phase in
            // Returning from the background: the QUIC link is usually dead
            // after iOS suspends us, so recover immediately instead of waiting
            // out the reconnect backoff. See IrohSession.foregrounded().
            switch phase {
            case .active:
                session.foregrounded()
            case .background:
                session.backgrounded()
            case .inactive:
                break
            @unknown default:
                break
            }
        }
        .onDisappear {
            session.disconnect()
        }
        .alert(
            "Couldn't update host",
            isPresented: Binding(
                get: { storeError != nil },
                set: { if !$0 { storeError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(storeError ?? "Unknown error")
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

    private enum TerminalInputMode: Equatable {
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

    private var inputMenu: some View {
        Menu {
            Section("Input mode") {
                Button {
                    setInputMode(.keyboard)
                } label: {
                    Label("Keyboard", systemImage: inputMode == .keyboard ? "checkmark" : "keyboard")
                }
                Button {
                    setInputMode(.tap)
                } label: {
                    Label("Tap and scroll", systemImage: inputMode == .tap ? "checkmark" : "hand.tap")
                }
            }
            Section("Keyboard") {
                Button(action: toggleAccessoryKeys) {
                    Label(
                        accessoryKeysVisible ? "Hide shortcut keys" : "Show shortcut keys",
                        systemImage: "command"
                    )
                }
            }
            Divider()
            Button {
                withAnimation { showingInputHint = true }
            } label: {
                Label("Input help", systemImage: "questionmark.circle")
            }
        } label: {
            Label("Input", systemImage: inputMode == .tap ? "hand.tap.fill" : "keyboard")
        }
        .accessibilityLabel("Terminal input")
        .accessibilityValue(inputMode == .tap ? "Tap and scroll" : "Keyboard")
        .accessibilityHint("Choose keyboard or touch input and show shortcut keys.")
    }

    private func setInputMode(_ mode: TerminalInputMode) {
        guard inputMode != mode else { return }
        inputMode = mode
        terminalFocused = mode == .keyboard
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func toggleAccessoryKeys() {
        accessoryKeysVisible.toggle()
        if inputMode == .keyboard { terminalFocused = true }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var statusMessage: String? {
        switch session.status {
        case .connecting:
            return "Connecting to host…"
        case .reconnecting(let attempt, let delay, let reason):
            return "Connection lost: \(reason). Reconnecting in \(delay)s (try \(attempt)); reattaches if the host lease is alive…"
        case .disconnected(let reason):
            if reason == "disconnected" { return nil }
            return reason == "session ended" ? "The remote shell exited." : reason
        case .failed(let reason, _):
            return reason
        case .connected, .idle:
            return nil
        }
    }

    @ViewBuilder
    private func statusOverlay(_ text: String) -> some View {
        switch session.status {
        case .connecting:
            statusCard(title: "Connecting", detail: text, showsProgress: true) {
                Button("Logs") { showingLogs = true }
            }
        case .reconnecting(_, let delay, let reason):
            statusCard(
                title: "Reconnecting in \(delay)s",
                detail: reason,
                showsProgress: true
            ) {
                Button("Retry now") { session.retryNow() }
                Button("Logs") { showingLogs = true }
            }
        case .disconnected:
            statusCard(title: "Session ended", detail: text) {
                Button("Reconnect") { session.retryNow() }
                Button("Logs") { showingLogs = true }
            }
        case .failed(_, let recovery):
            statusCard(title: "Connection failed", detail: text) {
                switch recovery {
                case .retry:
                    Button("Retry") { session.retryNow() }
                case .rePair:
                    Button("Pair again") { showingRePair = true }
                case .none:
                    EmptyView()
                }
                Button("Logs") { showingLogs = true }
            }
        case .idle, .connected:
            EmptyView()
        }
    }

    private func statusCard<Actions: View>(
        title: String,
        detail: String?,
        showsProgress: Bool = false,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if showsProgress { ProgressView().controlSize(.small) }
                Text(title).font(.footnote.weight(.semibold))
            }
            if let detail, !detail.isEmpty, detail != title {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 8) { actions() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.updatesFrequently)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var inputHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "keyboard")
                .foregroundStyle(.tint)
            Text("Use **Input** to switch between typing and touch navigation. Tap mode hides the keyboard; taps click and swipes scroll mouse-aware terminal apps.")
                .font(.footnote)
            Button {
                withAnimation { showingInputHint = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .accessibilityLabel("Dismiss input help")
        }
        .padding(12)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding()
        .accessibilityElement(children: .contain)
    }

    private func handleStatusChange(_ status: SessionStatus) {
        switch status {
        case .connected:
            do {
                try store.markConnected(connection.id)
            } catch {
                storeError = error.localizedDescription
            }
            UIAccessibility.post(notification: .announcement, argument: "Connected to \(connection.label)")
            if !hasShownInputHint {
                hasShownInputHint = true
                withAnimation { showingInputHint = true }
                Task {
                    try? await Task.sleep(for: .seconds(10))
                    if !Task.isCancelled {
                        withAnimation { showingInputHint = false }
                    }
                }
            }
        case .reconnecting(_, let delay, _):
            UIAccessibility.post(
                notification: .announcement,
                argument: "Connection lost. Reconnecting in \(delay) seconds."
            )
        case .failed(let reason, _):
            UIAccessibility.post(notification: .announcement, argument: "Connection failed. \(reason)")
        case .disconnected(let reason) where reason != "disconnected":
            UIAccessibility.post(notification: .announcement, argument: "Session ended. \(reason)")
        case .idle, .connecting, .disconnected:
            break
        }
    }
}
