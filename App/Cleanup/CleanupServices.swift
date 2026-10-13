import AppKit
import MoppoCore

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
        let (running, owners) = await MainActor.run {
            (
                Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }),
                ApplicationRuntime.currentRunningOwners()
            )
        }
        var registered: Set<String> = []
        var candidates: OrphanedAppLeftoverPlanner.CandidateScan?
        if preferences.enabledCategories?.contains(.applicationLeftovers) ?? true {
            let planner = leftoverPlanner
            let scanned = await Task.detached { planner.scanCandidates() }.value
            try Task.checkCancellation()
            candidates = scanned
            registered = await MainActor.run {
                ApplicationRuntime.registeredApplicationBundleIdentifiers(for: scanned.identifiers)
            }
        }
        try Task.checkCancellation()
        let context = ScanContext(
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: preferences.excludedPaths,
            excludedPatterns: preferences.excludedPatterns,
            runningApplicationPaths: running,
            runningApplications: owners,
            registeredApplicationBundleIdentifiers: registered,
            applicationLeftoverCandidates: candidates
        )
        return try await coordinator.scan(
            enabled: preferences.enabledCategories, context: context, onProgress: onProgress
        )
    }
}

protocol CleanupRemoving: Sendable {
    func remove(
        entries: [FileEntry],
        trashFirst: Bool,
        keepReceipt: Bool,
        userDataRemovalOverrides: Set<FileEntry.ID>,
        appDataRemovalOverrides: Set<FileEntry.ID>,
        expectedIdentities: [FileEntry.ID: String]
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
