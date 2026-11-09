import Foundation

extension AppModel {
    /// Shares access checks and Cleanup actions between Shortcuts and the menu bar.
    func startCleanup(removeSafeToRemove: Bool, presentMainWindow: (() -> Void)? = nil) throws {
        guard !isShowingWelcome else { throw MoppoOperationError.welcomeGuideIncomplete }
        guard !isBusyWithDisk, cleanup.pendingCleanUp == nil else { throw MoppoOperationError.operationInProgress }
        let background = presentMainWindow == nil
        guard !background || checkDiskAccess(automatic: true) else { throw MoppoOperationError.backgroundAccessRequired }
        presentMainWindow?()
        cleanup.startScan(automatic: background, refreshOverview: !background, removeSafeToRemove: removeSafeToRemove)
    }
}

enum MoppoOperationError: Error, Equatable, LocalizedError, CustomLocalizedStringResourceConvertible {
    case welcomeGuideIncomplete
    case operationInProgress
    case trashAccessRequired
    case backgroundAccessRequired
    case scanRequired

    var errorDescription: String? { String(localized: localizedStringResource) }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .welcomeGuideIncomplete: "Open Moppo and complete the welcome guide."
        case .operationInProgress: "Moppo is busy. Try again when the current task is complete."
        case .trashAccessRequired: "Moppo cannot read the Trash. Grant Full Disk Access to Moppo in System Settings."
        case .backgroundAccessRequired: "Grant Full Disk Access to Moppo in System Settings before running background cleanup."
        case .scanRequired: "Open Moppo and scan for Cleanup items first."
        }
    }
}
