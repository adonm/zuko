import SwiftUI

/// Main screen. When there are no saved connections it shows the onboarding
/// (the host setup commands); otherwise it lists saved connections.
struct ConnectionListView: View {
    @EnvironmentObject private var store: ConnectionStore
    @State private var presentingAdd = false
    @State private var showingOnboarding = false

    var body: some View {
        NavigationStack {
            Group {
                if store.connections.isEmpty {
                    ScrollView {
                        VStack(spacing: 20) {
                            OnboardingView()
                            Button {
                                presentingAdd = true
                            } label: {
                                Label("Add connection", systemImage: "plus.circle.fill")
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            Text("No saved hosts yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding()
                    }
                } else {
                    List {
                        ForEach(store.connections) { connection in
                            NavigationLink(value: connection) {
                                ConnectionRow(connection: connection)
                            }
                        }
                        .onDelete { store.remove(at: $0) }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Zuko")
            .navigationDestination(for: Connection.self) { connection in
                TerminalScreen(connection: connection)
            }
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
                            presentingAdd = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Add connection")
                    }
                }
            }
            .sheet(isPresented: $presentingAdd) {
                AddConnectionView()
            }
            .sheet(isPresented: $showingOnboarding) {
                OnboardingSheet()
            }
        }
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
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
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
        .environmentObject(ConnectionStore())
}
#endif
