import SwiftUI

/// Main screen. When there are no saved connections it shows the onboarding
/// (the host setup commands); otherwise it lists saved connections.
struct ConnectionListView: View {
    @Environment(ConnectionStore.self) private var store
    @State private var presentingAdd = false
    @State private var showingOnboarding = false
    @State private var selectedConnectionID: Connection.ID?
    @State private var detailsConnection: Connection?
    @State private var pendingForget: ForgetRequest?
    @State private var errorMessage: String?
    @State private var incomingPairingCode = ""
    @State private var preferredCompactColumn = NavigationSplitViewColumn.sidebar

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
            Group {
                if store.connections.isEmpty {
                    ScrollView {
                        VStack(spacing: 20) {
                            OnboardingView()
                            Button {
                                beginPairing()
                            } label: {
                                Label("Add connection", systemImage: "plus.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding()
                    }
                } else {
                    List(selection: $selectedConnectionID) {
                        ForEach(store.connections) { connection in
                            NavigationLink(value: connection.id) {
                                ConnectionRow(connection: connection)
                            }
                            .contextMenu {
                                Button {
                                    detailsConnection = connection
                                } label: {
                                    Label("Host details", systemImage: "info.circle")
                                }
                                Button(role: .destructive) {
                                    pendingForget = ForgetRequest(connections: [connection])
                                } label: {
                                    Label("Forget host", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete(perform: requestForget)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Zuko")
            .toolbar {
                if !store.connections.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showingOnboarding = true
                        } label: {
                            Image(systemName: "info.circle")
                        }
                        .accessibilityLabel("How to add a host")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            beginPairing()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add connection")
                        .keyboardShortcut("n", modifiers: .command)
                    }
                }
            }
        } detail: {
            if let connection = selectedConnection {
                TerminalScreen(connection: connection)
                    .id(connection.id)
            } else {
                ContentUnavailableView(
                    "Select a host",
                    systemImage: "terminal",
                    description: Text("Choose a saved host from the sidebar to open its terminal.")
                )
            }
        }
        .sheet(isPresented: $presentingAdd) {
            AddConnectionView(initialCode: incomingPairingCode) { connection in
                selectedConnectionID = connection.id
                preferredCompactColumn = .detail
            }
        }
        .sheet(isPresented: $showingOnboarding) {
            OnboardingSheet()
        }
        .sheet(item: $detailsConnection) { connection in
            HostDetailsView(connectionID: connection.id) { forgottenID in
                if selectedConnectionID == forgottenID {
                    selectedConnectionID = nil
                    preferredCompactColumn = .sidebar
                }
            }
        }
        .confirmationDialog(
            pendingForget?.title ?? "Forget host?",
            isPresented: Binding(
                get: { pendingForget != nil },
                set: { if !$0 { pendingForget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(pendingForget?.buttonTitle ?? "Forget", role: .destructive, action: forgetPending)
            Button("Cancel", role: .cancel) { pendingForget = nil }
        } message: {
            Text("This only removes the saved connection from this device. Revoke access separately on the host with `zuko rm <device-name>`.")
        }
        .alert(
            "Couldn't update hosts",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .onChange(of: store.connections) {
            if let selectedConnectionID,
               !store.connections.contains(where: { $0.id == selectedConnectionID }) {
                self.selectedConnectionID = nil
                preferredCompactColumn = .sidebar
            }
        }
    }

    private var selectedConnection: Connection? {
        guard let selectedConnectionID else { return nil }
        return store.connections.first { $0.id == selectedConnectionID }
    }

    private func beginPairing(code: String = "") {
        incomingPairingCode = code
        presentingAdd = true
    }

    private func requestForget(at offsets: IndexSet) {
        let connections = offsets.compactMap { index in
            store.connections.indices.contains(index) ? store.connections[index] : nil
        }
        guard !connections.isEmpty else { return }
        pendingForget = ForgetRequest(connections: connections)
    }

    private func forgetPending() {
        guard let request = pendingForget else { return }
        do {
            try store.remove(ids: Set(request.connections.map(\.id)))
            if let selectedConnectionID,
               request.connections.contains(where: { $0.id == selectedConnectionID }) {
                self.selectedConnectionID = nil
                preferredCompactColumn = .sidebar
            }
            pendingForget = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ForgetRequest: Identifiable {
    let id = UUID()
    let connections: [Connection]

    var title: String {
        connections.count == 1
            ? "Forget \(connections[0].label)?"
            : "Forget \(connections.count) hosts?"
    }

    var buttonTitle: String {
        connections.count == 1 ? "Forget on this device" : "Forget hosts on this device"
    }
}

struct ConnectionRow: View {
    let connection: Connection
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(connection.label)
                .font(.body)
            HStack(spacing: 6) {
                Image(systemName: "key.horizontal")
                    .font(.caption2)
                Text(shortNodeId(for: connection))
                    .font(.system(.caption, design: .monospaced))
                if let lastConnectedAt = connection.lastConnectedAt {
                    Text("·")
                    Text(lastConnectedAt, style: .relative)
                } else {
                    Text("· Never connected")
                }
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(connection.label)
        .accessibilityValue(connection.lastConnectedAt == nil ? "Never connected" : "Previously connected")
    }
}

/// Wraps the onboarding card in a sheet for re-display from the list.
struct OnboardingSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                OnboardingView().padding()
            }
            .navigationTitle("Add a host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#if canImport(PreviewsMacros)
#Preview {
    ConnectionListView()
        .environment(ConnectionStore())
}
#endif
