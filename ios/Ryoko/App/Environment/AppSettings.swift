import Foundation

/// UserDefaults keys for device-only settings. Read them with `@AppStorage`:
///
///     @AppStorage(AppSettings.showsRomanizationKey) private var showsRomanization = true
nonisolated enum AppSettings {
    /// Me's romanization toggle (pinyin, romaji). It only hides the row; on by default.
    /// The preference stays on the device and never goes into the profile (design §7.2).
    static let showsRomanizationKey = "RyokoShowsRomanization"

    /// Which `RyokoAPI` the app uses: `fixture` or `live` (`APIStore.Mode`).
    /// In DEBUG it can be set at launch: `-RyokoAPIMode fixture`.
    static let apiModeKey = "RyokoAPIMode"
}
