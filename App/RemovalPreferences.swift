import Foundation

/// Exclusions and the receipt setting that an operation captures when it starts.
struct RemovalPreferences: Sendable {
    var excludedPaths: [String] = []
    var excludedPatterns: [String] = []
    var keepReceipt = true
}

extension RemovalPreferences {
    /// Uses the default values when previews and tests supply no store.
    @MainActor
    init(settings: SettingsStore?) {
        self.init(
            excludedPaths: settings?.excludedFolderPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? [],
            keepReceipt: settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt
        )
    }
}
