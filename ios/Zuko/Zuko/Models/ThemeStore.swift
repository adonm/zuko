import Foundation
import GhosttyTerminal
import GhosttyTheme
import Observation

/// Persists the user's terminal appearance preferences. Backed by UserDefaults
/// (the values are small primitives — Keychain isn't warranted).
///
/// Two concerns, co-located because they both flow through the same
/// `TerminalScreen` and are tiny individually:
/// - `selectedName` — color theme name (nil = libghostty default).
/// - `fontSize` — terminal body size in pt. Defaults to half of
///   libghostty-spm's iOS default of 10 (matches the v0.5 redesign brief).
///
/// If this grows beyond ~5 properties, split it into `ThemeStore` +
/// `FontPreferences`. Until then the single object keeps `TerminalScreen`'s
/// `@Environment` count to one.
///
/// Injected at the app root (`ZukoApp`) via `.environment(...)` so the
/// `TerminalScreen` toolbar picker and any future surfaces stay in sync.
/// Uses the Swift 5.9+ `@Observable` macro (iOS 17+) instead of the legacy
/// `ObservableObject` + `@Published` pair — fewer wrappers, finer-grained
/// observation (only the properties a view actually reads trigger updates,
/// not every `@Published` property on the object).
@MainActor
@Observable
final class ThemeStore {
    @ObservationIgnored private static let themeKey = "themeName"
    @ObservationIgnored private static let fontSizeKey = "fontSize"

    /// Default font size — half of libghostty-spm's iOS default of 10pt.
    static let defaultFontSize: Float = 5

    /// Stepper bounds for the toolbar Menu. Lower bound matches libghostty's
    /// `minFontSize` (`UITerminalView+PinchZoom.swift`); upper is a sanity
    /// cap (the package allows 64 but >30 is silly on a phone).
    static let minFontSize: Float = 4
    static let maxFontSize: Float = 30

    /// A curated short list for the toolbar Menu's "Popular" section. Names
    /// must match `GhosttyThemeDefinition.name` exactly (the catalog uses
    /// iTerm2-Color-Schemes naming). Mirrors the MobileGhosttyApp example's
    /// popular list so users coming from Ghostty's own iOS demo see the same
    /// defaults.
    static let popularThemeNames: [String] = [
        "Dracula",
        "Catppuccin Mocha",
        "Catppuccin Latte",
        "Nord",
        "Solarized Dark",
        "Solarized Light",
        "Gruvbox Dark",
        "Gruvbox Light",
        "Tokyo Night",
        "One Half Dark",
        "One Half Light",
        "Rose Pine",
        "Monokau Pro",
        "GitHub Dark",
        "GitHub Light",
    ]

    // Persisted UI state — observed by SwiftUI via the @Observable macro.
    // Writes go through the setters below, which also persist to UserDefaults.
    private(set) var selectedName: String?
    private(set) var fontSize: Float

    init() {
        selectedName = UserDefaults.standard.string(forKey: Self.themeKey)
        // Default to `defaultFontSize` when unset OR when an older release
        // left a 0/invalid value. The pinch-to-zoom gesture updates
        // `currentFontSize` on the UITerminalView but doesn't persist here —
        // this value is the cold-start size; in-session pinch deltas are
        // session-local (matches the package's "pinch to fit this screen"
        // mental model, not "pinch to change my global pref").
        let storedSize = UserDefaults.standard.object(forKey: Self.fontSizeKey) as? Float
        fontSize = (storedSize ?? Self.defaultFontSize).clamped(to: Self.minFontSize ... Self.maxFontSize)
    }

    /// Update the theme selection. `nil` restores libghostty-spm's default
    /// theme (Afterglow / Alabaster). Persisted synchronously.
    func setTheme(_ name: String?) {
        // The guard is load-bearing under @Observable: the macro doesn't
        // diff old vs new, so even a no-op write notifies observers.
        guard selectedName != name else { return }
        selectedName = name
        UserDefaults.standard.set(name, forKey: Self.themeKey)
    }

    /// Update the font size. Clamped to `[minFontSize, maxFontSize]`.
    /// Persisted synchronously; the caller is responsible for the live
    /// `setTerminalConfiguration` apply.
    func setFontSize(_ size: Float) {
        let clamped = size.clamped(to: Self.minFontSize ... Self.maxFontSize)
        guard fontSize != clamped else { return }
        fontSize = clamped
        UserDefaults.standard.set(clamped, forKey: Self.fontSizeKey)
    }

    /// The live `TerminalTheme` to hand to `TerminalController.setTheme`.
    /// Falls back to `.default` when no theme is picked or the saved name
    /// can't be resolved (e.g. catalog renamed it in a future release).
    var currentTheme: TerminalTheme {
        guard let name = selectedName,
              let definition = GhosttyThemeCatalog.theme(named: name)
        else { return .default }
        return definition.toTerminalTheme()
    }

    /// Popular themes resolved to definitions, in `popularThemeNames` order.
    /// Drops any name the catalog doesn't carry (defensive — shouldn't happen
    /// with the curated list above, but a typo shouldn't crash the picker).
    var popularThemes: [GhosttyThemeDefinition] {
        Self.popularThemeNames.compactMap { GhosttyThemeCatalog.theme(named: $0) }
    }
}

private extension FloatingPoint {
    /// Clamp to a `ClosedRange`. Foundation ships `clamped(to:)` on
    /// `Comparable` from iOS 17+ but the witness lookup is ambiguous on
    /// `Float` vs `Double` in some toolchains; a local helper sidesteps it.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
