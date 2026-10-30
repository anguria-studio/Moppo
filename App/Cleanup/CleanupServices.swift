import AppKit
import MoppoCore
import MoppoScan

protocol CleanupScanning: Sendable {
    func scan(
        preferences: CleanupModel.Preferences,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResults
}

/// Builds one scan context from preferences and current application owners.
struct CleanupScanService: CleanupScanning {
    let coordinator: ScanCoordinator
    let leftoverPlanner: OrphanedAppLeftoverPlanner

    init(
        coordinator: ScanCoordinator = .standard(),
        leftoverPlanner: OrphanedAppLeftoverPlanner = OrphanedAppLeftoverPlanner()
    ) {
        self.coordinator = coordinator
        self.leftoverPlanner = leftoverPlanner
    }

    func scan(
        preferences: CleanupModel.Preferences,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResults {
        let diagnostics = try ScanLog.begin(preferences)
        return try await ScanDiagnostics.$current.withValue(diagnostics?.context) {
            var succeeded = false
            defer {
                diagnostics?.finish(outcome: Task.isCancelled ? "cancelled" : succeeded ? "completed" : "failed")
                diagnostics?.flush()
            }
            let context = try await ScanEnvironment.context(
                configuration: ScanConfiguration(enabledCategories: preferences.enabledCategories ?? Set(CategoryID.allCases),
                    excludedPaths: preferences.excludedPaths, excludedPatterns: preferences.excludedPatterns,
                    showsSmallItems: preferences.showsSmallItems),
                leftoverPlanner: leftoverPlanner
            )
            let result = try await coordinator.scan(
                enabled: preferences.enabledCategories, context: context, onProgress: onProgress
            )
            succeeded = true
            return result
        }
    }
}

protocol CleanupRemoving: Sendable {
    func remove(
        entries: [FileEntry],
        trashFirst: Bool,
        keepReceipt: Bool,
        userDataRemovalOverrides: Set<FileEntry.ID>,
        appDataRemovalOverrides: Set<FileEntry.ID>,
        expectedIdentities: [FileEntry.ID: String],
        confirmedToolCommands: [FileEntry.ID: ToolCommandRemoval]
    ) async throws -> CleanupOutcome

    func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan,
        bundleIdentifiers: Set<String>,
        itemPaths: Set<String>?,
        registeredApplicationBundleIdentifiers: Set<String>,
        keepReceipt: Bool
    ) async throws -> CleanupOutcome
}

extension CleanupService: CleanupRemoving {}
