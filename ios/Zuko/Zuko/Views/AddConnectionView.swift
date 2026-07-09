import SwiftUI

/// Sheet for pairing with a host via a `zuko share` code.
///
/// Replaces the old paste-a-raw-ticket flow (which violated the project's
/// security model — sensitive connection information doesn't belong on the
/// clipboard).
/// The code is a *one-time* symmetric secret: the iOS app derives the same
/// throwaway Iroh key as the CLI's `zuko share`, dials the derived NodeId,
/// and reads the real ticket off an end-to-end-encrypted uni stream. The
/// raw ticket never touches the UI surface. See [`ClaimSession`] + the
/// `src/handoff.rs` Rust reference.
struct AddConnectionView: View {
    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // @State (not @StateObject): ClaimSession is @Observable, so it follows
    // the same Observation-based ownership rules as our other stores.
    @State private var claimSession = ClaimSession()

    @State private var code: String = ""
    @State private var error: String?
    @FocusState private var codeFieldFocused: Bool

    private let codePlaceholder = "iridescent-hilton"

    /// Is a claim in flight? Drives the button → spinner swap + disables input.
    private var isClaiming: Bool {
        switch claimSession.status {
        case .idle, .failed: return false
        default: return true
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(codePlaceholder, text: $code)
                        .focused($codeFieldFocused)
                        .font(.system(.body, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .onSubmit { claim() }
                        .disabled(isClaiming)
                } header: {
                    Text("Pairing code")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("On the host, run:")
                            .font(.caption).fontWeight(.semibold)
                        Text(HostSetup.shareCommand)
                            .font(.system(.caption, design: .monospaced))
                        Text("Type the code here. The host's real ticket arrives over an E2E-encrypted Iroh stream — it never touches the clipboard.")
                            .padding(.top, 2)
                    }
                }

                if case .failed(let msg) = claimSession.status {
                    Section {
                        Label(msg, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }

                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Pair with a host")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isClaiming)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isClaiming {
                        // Step label + spinner: the claim has three phases
                        // (derive / dial / read), and each can take a few
                        // seconds, so show which one rather than an opaque
                        // spinner.
                        HStack(spacing: 6) {
                            Text(claimSession.status.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ProgressView()
                        }
                    } else {
                        Button("Pair", action: claim)
                            .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .bold()
                    }
                }
            }
            .onAppear { codeFieldFocused = true }
        }
    }

    // MARK: - Actions

    private func claim() {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        error = nil

        Task {
            do {
                let result = try await claimSession.claim(code: trimmed)
                // Save the claimed ticket under the host's label (sent in the
                // payload). `ConnectionStore.add` validates + de-dupe + saves
                // to the Keychain — same path as the old paste-ticket flow,
                // just fed from the handoff instead of the clipboard.
                _ = try store.add(label: result.label, ticket: result.ticket)
                dismiss()
            } catch {
                // ClaimSession.status already carries the failed message; the
                // `error` state is a fallback for save failures specifically.
                self.error = error.localizedDescription
            }
        }
    }
}
