import SwiftUI
import UIKit

/// The repo-tied install command shown on first run. We deliberately use the
/// raw.githubusercontent.com URL (versioned with the repo) rather than a
/// separate hostname, so this baked-in string can't rot if a vanity domain
/// ever moves.
enum HostSetup {
    static let repoOwner = "adonm"
    static let repoName = "zuko"
    static let branch = "main"

    static let installCommand =
        "curl -fsSL https://raw.githubusercontent.com/\(repoOwner)/\(repoName)/\(branch)/zuko/scripts/install.sh | sh"

    /// Where the ticket the host prints should be pasted back (user-facing hint).
    static let ticketPrefix = "endpointa"
}

/// Reusable card explaining how to set up a host and get a ticket.
struct OnboardingView: View {
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Add a host").font(.headline)
            } icon: {
                Image(systemName: "terminal")
                    .foregroundStyle(Color.accentColor)
            }

            Text("Run this once on the Mac/Linux box you want to shell into. It installs a small daemon that keeps a persistent, end-to-end-encrypted Iroh session and prints a ticket.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            CopyableCommand(command: HostSetup.installCommand)

            if copied {
                Text("Copied. After it runs, look for the line starting with `\(HostSetup.ticketPrefix)` — that's your ticket.")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Divider().padding(.vertical, 4)

            Text("Then tap **+**, name the connection, and paste the ticket.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

/// A monospaced, copyable single-line command box.
struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.footnote, design: .monospaced))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                UIPasteboard.general.string = command
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation { copied = false }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.bordered)
            .tint(copied ? Color.green : Color.accentColor)
        }
        .padding(10)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

#Preview {
    OnboardingView()
        .padding()
}
