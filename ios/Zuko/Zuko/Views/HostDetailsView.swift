import SwiftUI
import UIKit

/// Edit and recovery information for one saved host. Tickets remain hidden;
/// the only identity shown is the short public node id already used in the
/// connection list.
struct HostDetailsView: View {
    let connectionID: Connection.ID
    var onForgot: (Connection.ID) -> Void = { _ in }

    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var showingForgetConfirmation = false
    @State private var errorMessage: String?
    @State private var copiedRevokeCommand = false

    private var connection: Connection? {
        store.connections.first { $0.id == connectionID }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let connection {
                    Form {
                        Section("Host") {
                            TextField("Name", text: $label)
                                .textInputAutocapitalization(.words)
                                .submitLabel(.done)
                                .onSubmit(save)

                            LabeledContent("Node ID") {
                                Text(shortNodeId(for: connection))
                                    .font(.system(.body, design: .monospaced))
                                    .textSelection(.enabled)
                            }
                            LabeledContent("Added") {
                                Text(connection.addedAt, format: .dateTime.year().month().day())
                            }
                            LabeledContent("Last connected") {
                                if let date = connection.lastConnectedAt {
                                    Text(date, format: .dateTime.year().month().day().hour().minute())
                                } else {
                                    Text("Never").foregroundStyle(.secondary)
                                }
                            }
                        }

                        Section {
                            if let revokeCommand {
                                Button {
                                    UIPasteboard.general.string = revokeCommand
                                    copiedRevokeCommand = true
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                } label: {
                                    Label(
                                        copiedRevokeCommand ? "Copied revoke command" : "Copy revoke command",
                                        systemImage: copiedRevokeCommand ? "checkmark" : "doc.on.doc"
                                    )
                                }
                            } else {
                                Label("Authorization label unavailable", systemImage: "exclamationmark.triangle")
                                    .foregroundStyle(.secondary)
                            }
                        } header: {
                            Text("Revoke access")
                        } footer: {
                            Text(revokeInstructions)
                        }

                        Section {
                            Button("Forget this host", role: .destructive) {
                                showingForgetConfirmation = true
                            }
                        } footer: {
                            Text("This removes the saved connection from this device. It does not change the host's authorised-client list.")
                        }
                    }
                } else {
                    ContentUnavailableView("Host not found", systemImage: "externaldrive.badge.questionmark")
                }
            }
            .navigationTitle("Host details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if connection != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .bold()
                            .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .onAppear {
            if label.isEmpty { label = connection?.label ?? "" }
        }
        .confirmationDialog(
            "Forget \(connection?.label ?? "this host")?",
            isPresented: $showingForgetConfirmation,
            titleVisibility: .visible
        ) {
            Button("Forget on this device", role: .destructive, action: forget)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You can pair it again later. This does not revoke the device on the host.")
        }
        .alert(
            "Couldn't update host",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private var revokeCommand: String? {
        guard let label = connection?.authorizedClientLabel else { return nil }
        return "zuko rm \(shellQuote(label))"
    }

    private var revokeInstructions: String {
        if let revokeCommand {
            return "Forgetting below only removes this host from this device. To revoke shell access, run `\(revokeCommand)` on the host."
        }
        return "This host was saved by an older app version. Run `zuko ls` on the host, identify this device, then run `zuko rm <device-name>`."
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private func save() {
        do {
            try store.rename(connectionID, to: label)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func forget() {
        do {
            try store.remove(ids: [connectionID])
            onForgot(connectionID)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
