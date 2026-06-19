import SwiftUI

/// Sheet for pasting a host ticket and naming the connection.
struct AddConnectionView: View {
    @EnvironmentObject private var store: ConnectionStore
    @Environment(\.dismiss) private var dismiss

    @State private var label: String = ""
    @State private var ticket: String = ""
    @State private var error: String?
    @FocusState private var focusedField: Field?

    private enum Field { case label, ticket }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. home server", text: $label)
                        .focused($focusedField, equals: .label)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .ticket }
                }
                Section {
                    TextEditor(text: $ticket)
                        .focused($focusedField, equals: .ticket)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 96)
                        .overlay(alignment: .topLeading) {
                            if ticket.isEmpty {
                                Text("Paste the ticket your host printed (starts with \(HostSetup.ticketPrefix)…)")
                                    .foregroundStyle(.secondary)
                                    .font(.subheadline)
                                    .padding(.top, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                } header: {
                    Text("Ticket")
                } footer: {
                    Text("On the host: `mise use --global github:adonm/zuko && zuko install`. The host's node id is stable across restarts, so this connection keeps working.")
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("New connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") { add() }
                        .disabled(ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .bold()
                }
            }
            .onAppear { focusedField = .ticket }
        }
    }

    private func add() {
        do {
            _ = try store.add(label: label, ticket: ticket)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
