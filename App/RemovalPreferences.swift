import Foundation

/// Exclusions and removal settings captured when an operation starts.
struct RemovalPreferences: Sendable {
    var excludedPaths: [String] = []
    var excludedPatterns: [String] = []
    var confirmBeforeCleanup = false
    var keepReceipt = true

    @MainActor
    func confirmRemoval(
        _ request: RemovalConfirmation,
        using confirm: (RemovalConfirmation) async -> Bool
    ) async -> Bool {
        guard confirmBeforeCleanup else { return true }
        return await confirm(request)
    }
}

/// Describes a captured selection and its removal method.
enum RemovalConfirmation: Equatable {
    case trash(itemCount: Int, totalBytes: Int64, protectedDataCount: Int = 0)
    case photos(itemCount: Int)
    case permanentApplication(name: String)
}

extension RemovalPreferences {
    /// Uses the default values when previews and tests supply no store.
    @MainActor
    init(settings: SettingsStore?) {
        self.init(
            excludedPaths: settings?.excludedPaths ?? [],
            excludedPatterns: settings?.excludedPatterns ?? [],
            confirmBeforeCleanup: settings?.confirmBeforeCleanup ?? SettingsStore.Defaults.confirmBeforeCleanup,
            keepReceipt: settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt
        )
    }
}
