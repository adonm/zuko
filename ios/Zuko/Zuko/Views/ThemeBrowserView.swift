import GhosttyTheme
import SwiftUI

/// Searchable list of all 485 catalog themes. Reached from the
/// `TerminalScreen` toolbar Menu ("Browse all…"). Tap a row to apply and
/// dismiss; the toolbar Menu's Popular section covers quick switching.
///
/// When the search field is empty the list shows a "Default" row at the top
/// (restores Afterglow / Alabaster), a curated Popular section, then the
/// full catalog. Typing filters via `GhosttyThemeCatalog.search(_:)` (a
/// case-insensitive `contains` on the theme name).
struct ThemeBrowserView: View {
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List {
                if searchText.isEmpty {
                    defaultRow
                    Section("Popular") {
                        ForEach(themeStore.popularThemes) { theme in
                            row(theme)
                        }
                    }
                    Section("All themes") {
                        ForEach(GhosttyThemeCatalog.allThemes) { theme in
                            row(theme)
                        }
                    }
                } else {
                    ForEach(GhosttyThemeCatalog.search(searchText)) { theme in
                        row(theme)
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search \(GhosttyThemeCatalog.allThemes.count) themes")
            .navigationTitle("Theme")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    /// The "use libghostty-spm's default" row (Afterglow dark + Alabaster
    /// light). Only shown when not searching — it's a starting point, not
    /// something to filter for.
    private var defaultRow: some View {
        Button {
            themeStore.setTheme(nil)
            dismiss()
        } label: {
            HStack {
                defaultSwatch
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default")
                    Text("Afterglow · Alabaster")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if themeStore.selectedName == nil {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(_ theme: GhosttyThemeDefinition) -> some View {
        Button {
            themeStore.setTheme(theme.name)
            dismiss()
        } label: {
            HStack(spacing: 10) {
                ThemeSwatch(definition: theme)
                VStack(alignment: .leading, spacing: 2) {
                    Text(theme.name)
                    Text(theme.isDark ? "Dark" : "Light")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if themeStore.selectedName == theme.name {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Two-tone swatch for the default row (one Afterglow-style dark circle,
    /// one Alabaster-style light circle) — matches the `.default` theme's
    /// dual light/dark variants rather than picking one.
    private var defaultSwatch: some View {
        HStack(spacing: 2) {
            Circle().fill(Color(hex: "212121") ?? .clear).frame(width: 12, height: 12)
            Circle().fill(Color(hex: "F7F7F7") ?? .clear).frame(width: 12, height: 12)
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
        // Thin border so the light half is visible against a light list row.
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(.quaternary, lineWidth: 0.5)
        )
    }
}

/// Five-dot color preview for a catalog theme. Shows background + foreground
/// + the first three non-monochrome palette entries (typically red/green/blue
/// or whatever the theme defines at indices 0-2), so the swatch gives a feel
/// for the theme's identity without trying to be a full palette grid.
struct ThemeSwatch: View {
    let definition: GhosttyThemeDefinition

    var body: some View {
        HStack(spacing: 2) {
            ForEach(swatchHexes, id: \.self) { hex in
                Circle()
                    .fill(Color(hex: hex) ?? .clear)
                    .frame(width: 12, height: 12)
            }
        }
        .padding(2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
    }

    /// Background + foreground + palette[0..3] (only those present). Capped
    /// at 5 dots so every row stays the same width.
    private var swatchHexes: [String] {
        var hexes = [definition.background, definition.foreground]
        for index in 0..<3 where definition.palette[index] != nil {
            hexes.append(definition.palette[index]!)
        }
        return Array(hexes.prefix(5))
    }
}

extension Color {
    /// Hex string (with or without leading `#`) → Color. Nil for unparseable
    /// input (catalog entries should always parse, but be defensive — a bad
    /// hex shouldn't blank out the whole picker).
    init?(hex string: String) {
        let trimmed = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard trimmed.count == 6,
              let r = UInt8(trimmed.prefix(2), radix: 16),
              let g = UInt8(trimmed.dropFirst(2).prefix(2), radix: 16),
              let b = UInt8(trimmed.dropFirst(4).prefix(2), radix: 16)
        else { return nil }
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255
        )
    }
}

#if canImport(PreviewsMacros)
#Preview {
    ThemeBrowserView()
        .environment(ThemeStore())
}
#endif
