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
        let diagnostics = try ScanLog.begin(preferences)
        return try await ScanDiagnostics.$current.withValue(diagnostics?.context) {
            var succeeded = false
            defer {
                diagnostics?.finish(outcome: Task.isCancelled ? "cancelled" : succeeded ? "completed" : "failed")
                diagnostics?.flush()
            }
            let runtimeSpan = diagnostics?.context.begin("running_application_inventory")
            let (running, owners) = await MainActor.run {
                (
                    Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }),
                    ApplicationRuntime.currentRunningOwners()
                )
            }
            diagnostics?.context.end(runtimeSpan, details: ["running_applications": "\(running.count)"])
            var registered: Set<String> = []
            var candidates: OrphanedAppLeftoverPlanner.CandidateScan?
            if preferences.enabledCategories?.contains(.applicationLeftovers) ?? true {
                let planner = leftoverPlanner
                let discoverySpan = diagnostics?.context.begin("application_leftover_discovery")
                let scanned = await Task.detached {
                    ScanDiagnostics.$current.withValue(diagnostics?.context) { planner.scanCandidates() }
                }.value
                diagnostics?.context.end(discoverySpan, details: ["identifiers": "\(scanned.identifiers.count)"])
                try Task.checkCancellation()
                candidates = scanned
                let registrationSpan = diagnostics?.context.begin("registered_application_inventory")
                registered = await MainActor.run {
                    ApplicationRuntime.registeredApplicationBundleIdentifiers(for: scanned.identifiers)
                }
                diagnostics?.context.end(registrationSpan, details: ["registered_identifiers": "\(registered.count)"])
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
