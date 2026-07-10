import SwiftUI
import UIKit
import ZukoWire

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
    let initialCode: String
    let expectedHostNodeID: String?
    var onPaired: (Connection) -> Void

    @Environment(ConnectionStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    // @State (not @StateObject): ClaimSession is @Observable, so it follows
    // the same Observation-based ownership rules as our other stores.
    @State private var claimSession = ClaimSession()

    @State private var code: String
    @State private var error: String?
    @State private var showingScanner = false
    @State private var claimTask: Task<Void, Never>?
    @FocusState private var codeFieldFocused: Bool

    private let codePlaceholder = "iridescent-hilton"

    init(
        initialCode: String = "",
        expectedHostNodeID: String? = nil,
        onPaired: @escaping (Connection) -> Void = { _ in }
    ) {
        self.initialCode = initialCode
        self.expectedHostNodeID = expectedHostNodeID
        self.onPaired = onPaired
        _code = State(initialValue: initialCode)
    }

    /// Is a claim in flight? Drives the button → spinner swap + disables input.
    private var isClaiming: Bool {
        switch claimSession.status {
        case .idle, .failed: return false
        default: return true
        }
    }

    private var isFinalizing: Bool {
        if case .authorizing = claimSession.status { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField(codePlaceholder, text: $code)
                            .focused($codeFieldFocused)
                            .font(.system(.body, design: .monospaced))
                            .textContentType(.oneTimeCode)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit { claim() }
                            .disabled(isClaiming)
                            .accessibilityIdentifier("pairing-code-field")

                        if PairingCodeScanner.isSupported {
                            Button {
                                codeFieldFocused = false
                                showingScanner = true
                            } label: {
                                Image(systemName: "qrcode.viewfinder")
                            }
                            .accessibilityLabel("Scan pairing QR code")
                            .disabled(isClaiming)
                        }
                    }
                } header: {
                    Text("Pairing code")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("On the host, run:")
                            .font(.caption).fontWeight(.semibold)
                        Text(HostSetup.shareCommand)
                            .font(.system(.caption, design: .monospaced))
                        Text("Type the code or scan the QR shown by `zuko share`. The host's real ticket arrives over an E2E-encrypted Iroh stream — it never touches the clipboard.")
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
                    Button("Cancel", action: cancel)
                        .disabled(isFinalizing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isClaiming {
                        // Step label + spinner: the claim has three phases
                        // (derive / dial / read / authorize), and each can take a few
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
                            .accessibilityIdentifier("pair-host-button")
                    }
                }
            }
            .onAppear { codeFieldFocused = initialCode.isEmpty }
        }
        .sheet(isPresented: $showingScanner) {
            PairingCodeScanner { scannedCode in
                code = scannedCode
                showingScanner = false
                codeFieldFocused = true
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        .interactiveDismissDisabled(isFinalizing)
        .onDisappear { claimTask?.cancel() }
    }

    // MARK: - Actions

    private func claim() {
        let entered = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entered.isEmpty else { return }
        guard let pairingCode = PairingLink.code(from: entered) else {
            error = "Enter the two-word code from `zuko share` or scan its QR code."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        code = pairingCode
        error = nil

        claimTask?.cancel()
        claimTask = Task {
            do {
                var savedConnection: Connection?
                try await claimSession.claim(
                    code: pairingCode,
                    expectedHostNodeID: expectedHostNodeID
                ) { label, ticket, clientLabel in
                    try Task.checkCancellation()
                    // Persist before authorizing the client on the host. A
                    // Keychain failure therefore cannot leave remote trust
                    // behind for a connection the app failed to save.
                    savedConnection = try store.add(
                        label: label,
                        ticket: ticket,
                        authorizedClientLabel: clientLabel
                    )
                }
                guard let connection = savedConnection else {
                    throw ConnectionStore.AddError.persistence("Pairing completed without saving the host.")
                }
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onPaired(connection)
                dismiss()
            } catch is CancellationError {
                claimSession.reset()
            } catch {
                // ClaimSession.status already carries the failed message; the
                // `error` state is a fallback for save failures specifically.
                if case .failed = claimSession.status {
                    self.error = nil
                } else {
                    self.error = error.localizedDescription
                }
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
        }
    }

    private func cancel() {
        claimTask?.cancel()
        dismiss()
    }
}
