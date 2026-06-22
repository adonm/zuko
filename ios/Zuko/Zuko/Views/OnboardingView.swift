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

    /// Mint a one-time pairing code on the host. The iOS add-host sheet claims
    /// this directly via the same handoff protocol as `zuko <code>`.
    static let shareCommand = "zuko share"

}

/// Reusable card explaining how to set up a host.
struct OnboardingView: View {
    private static let introText = "Run this once on the Mac/Linux box you want to shell into. "
        + "`zuko install` sets up a background daemon (systemd on Linux, launchd on macOS) "
        + "that keeps a persistent, end-to-end-encrypted Iroh session. Prerequisite: "
        + "[mise](https://mise.jdx.dev) on the host (`curl https://mise.run | sh`)."

    @State private var copiedStep: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                Text("Add a host").font(.headline)
            } icon: {
                Image(systemName: "terminal")
                    .foregroundStyle(Color.accentColor)
            }

            Text(Self.introText)
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

            Text("Tap +, type the `zuko share` code, and the app saves the host. "
                + "The real ticket arrives over an E2E-encrypted Iroh stream "
                + "and never touches the clipboard.")
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
                    "Pinch to zoom font size live."
                )
                tip(
                    icon: "arrow.clockwise",
                    "Refresh icon asks the remote PTY to redraw without clearing zellij/tmux panes."
                )
                tip(
                    icon: "command.circle",
                    "Command-circle toggles the iOS shortcut-key row (Esc, Tab, arrows, Ctrl/Alt/Cmd). "
                        + "It starts hidden so the default keyboard is plain."
                )
                tip(
                    icon: "hand.tap",
                    "Hand-tap toggles cursor/tap mode: the keyboard stays hidden, taps become mouse clicks, "
                        + "and one-finger swipes scroll TUI panes like opencode or zellij."
                )
                tip(
                    icon: "rectangle.split.2x1",
                    "Run `tmux` or `zellij` on the host for sessions that survive disconnects — zuko itself starts a fresh PTY per connect."
                )
                tip(
                    icon: "paintpalette",
                    "Appearance menu (•••) has themes (Dracula, Nord, …) and font size."
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
    var onCopy: (() -> Void)?
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
