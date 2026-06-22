import SwiftUI
import UIKit

/// In-app log viewer over [`LogCapture`]. Reached from the TerminalScreen
/// overflow menu (under Font size / Color theme), so it's reachable *during*
/// a stall — open the menu → Logs → watch iroh's dial progress live and copy
/// the evidence out.
///
/// Shows both iroh internals (captured from stdout) and app lifecycle lines
/// (IrohSession status transitions, ClaimSession steps). Tints ERROR/WARN.
/// Copy puts the whole (filtered) buffer on the pasteboard; Share hands it to
/// the system share sheet (AirDrop, Mail, Files, …).
struct LogsView: View {
    @StateObject private var store = LogCapture.shared
    @Environment(\.dismiss) private var dismiss

    @State private var filter: String = ""
    @State private var autoScroll = true

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Logs")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .searchable(text: $filter, prompt: "Filter")
                .task { await poll() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                "No logs yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text(filter.isEmpty
                    ? "Connection + iroh logs appear here. Try connecting to a host."
                    : "No lines match “\(filter)”.")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { entry in
                            Text(entry.text)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(color(for: entry.level))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .textSelection(.enabled)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: filtered.last?.id) {
                    if autoScroll, let last = filtered.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Done") { dismiss() }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                autoScroll.toggle()
            } label: {
                Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
            }
            .accessibilityLabel(autoScroll ? "Pause auto-scroll" : "Resume auto-scroll")

            Button {
                UIPasteboard.general.string = filtered.map(\.text).joined(separator: "\n")
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel("Copy all logs")

            ShareLink(
                item: filtered.map(\.text).joined(separator: "\n"),
                label: { Image(systemName: "square.and.arrow.up") }
            )
            .accessibilityLabel("Share logs")

            Button(role: .destructive) {
                store.clear()
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Clear logs")
        }
    }

    /// Lines after the filter box is applied (case-insensitive substring).
    private var filtered: [LogEntry] {
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return store.entries }
        return store.entries.filter { $0.text.localizedCaseInsensitiveContains(needle) }
    }

    /// Tail the log file into the buffer while the sheet is open. Cancels
    /// automatically when the view goes away.
    private func poll() async {
        repeat {
            store.reload()
            try? await Task.sleep(for: LogCapture.pollInterval)
        } while !Task.isCancelled
    }

    private func color(for level: AppLogLevel) -> Color {
        switch level {
        case .error: .red
        case .warn: .orange
        case .debug, .trace: .secondary
        case .info: .primary
        }
    }
}
