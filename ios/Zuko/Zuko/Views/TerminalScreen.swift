import SwiftUI

/// The live terminal. Owns the Iroh session and embeds SwiftTerm.
struct TerminalScreen: View {
    let connection: Connection
    @StateObject private var session = IrohSession()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            TerminalRepresentable(session: session)
                .ignoresSafeArea(.container, edges: [.bottom])

            if let banner = statusMessage {
                statusBar(banner)
            }
        }
        .background(Color.black)
        .navigationTitle(connection.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Disconnect") {
                    session.disconnect()
                    dismiss()
                }
            }
        }
        .task {
            // Tiny delay so SwiftTerm lays out before we report a real size.
            session.connect(ticket: connection.ticket)
        }
        .onDisappear {
            session.disconnect()
        }
    }

    private var statusMessage: String? {
        switch session.status {
        case .connecting:
            return "Connecting to host…"
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
