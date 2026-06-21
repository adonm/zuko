import SwiftUI
import UIKit

/// The repo-tied install commands shown on first run.
enum HostSetup {
    static let repoOwner = "adonm"
    static let repoName = "zuko"

    /// Install zuko (mise pulls a prebuilt binary from GitHub Releases) and
    /// the host daemon as a user service. Prerequisite: mise on the host
    /// (`curl https://mise.run | sh`).
    static let zukoInstallCommand = "mise use --global github:adonm/zuko && zuko install"

    /// Mint a one-time pairing code on the host. The iOS app doesn't speak
    /// the pairing protocol yet — pair through the CLI on another machine
    /// (`zuko <code>`) to save the host, then it's available here.
    static let shareCommand = "zuko share"

    /// The string prefix every Iroh `EndpointTicket` starts with. Iroh's
    /// ticket string form is `<KIND><base32 of bytes>` lowercased, and
    /// `EndpointTicket::KIND == "endpoint"` (see iroh-tickets 1.0). Used by
    /// the paste-ticket UI as a hint for what a valid ticket looks like.
    /// Stable across Iroh 1.x; if a future Iroh bumps the KIND, the host's
    /// tickets would stop round-tripping through `EndpointTicket.fromString`
    /// anyway, so this would surface as a parse error rather than silent
    /// breakage.
    static let ticketPrefix = "endpoint"
}

/// Reusable card explaining how to set up a host.
struct OnboardingView: View {
    @State private var copiedStep: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Add a host").font(.headline)
            } icon: {
                Image(systemName: "terminal")
                    .foregroundStyle(Color.accentColor)
            }

            Text("Run this once on the Mac/Linux box you want to shell into. `zuko install` sets up a background daemon (systemd on Linux, launchd on macOS) that keeps a persistent, end-to-end-encrypted Iroh session. Prerequisite: [mise](https://mise.jdx.dev) on the host (`curl https://mise.run | sh`).")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 10) {
                step(1, "Install zuko + the host service", HostSetup.zukoInstallCommand)
                step(2, "Mint a pairing code (on the host)", HostSetup.shareCommand)
            }

            if let copiedStep {
                Text("Copied step \(copiedStep).")
                    .font(.footnote)
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }

            Divider().padding(.vertical, 4)

            Text("Pair through the CLI: on another machine with `zuko` installed, run `zuko <code>`. That saves the host, which you can then connect to from any client.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Divider().padding(.vertical, 4)

            Label {
                Text("Using the terminal").font(.headline)
            } icon: {
                Image(systemName: "lightbulb")
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                tip(
                    icon: "magnifyingglass.circle",
                    "Pinch the terminal to zoom font size live — coarse adjustment without leaving the session."
                )
                tip(
                    icon: "paintpalette",
                    "Tap the palette icon in the top bar for quick theme switching (Dracula, Catppuccin, Nord, …) or \"Browse all\" for the full 485-theme catalog with live preview."
                )
                tip(
                    icon: "textformat",
                    "Tap the Aa icon to grow or shrink the default font size. Persists across sessions."
                )
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    /// A single tip row: icon + body text.
    private func tip(icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20, alignment: .center)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// A numbered, monospaced, copyable single-line command box.
    private func step(_ n: Int, _ title: String, _ command: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(n). \(title)")
                .font(.caption)
                .foregroundStyle(.secondary)
            CopyableCommand(command: command) {
                withAnimation { copiedStep = n }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { if copiedStep == n { copiedStep = nil } }
                }
            }
        }
    }
}

/// A monospaced, copyable single-line command box.
struct CopyableCommand: View {
    let command: String
    var onCopy: (() -> Void)? = nil
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
                onCopy?()
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

#if canImport(PreviewsMacros)
#Preview {
    OnboardingView()
        .padding()
}
#endif
