import AppKit
import MoppoCore

protocol AppUninstallerScanning: Sendable {
    func plan(applicationURL: URL, context: ScanContext) async throws -> AppUninstallPlan
    func plans(
        applicationURLs: [URL], context: ScanContext,
        onProgress: @escaping @Sendable (Int) async -> Void
    ) async throws -> [Result<AppUninstallPlan, Error>]
    func installedApplications(context: ScanContext) async -> [InstalledApplication]
    func allocatedBytes(at url: URL, context: ScanContext) async throws -> Int64
    func leftovers(context: ScanContext) async throws -> OrphanedAppLeftoverPlan
}

struct AppUninstallerScanService: AppUninstallerScanning {
    var planner = AppUninstallPlanner()
    var leftoverPlanner = OrphanedAppLeftoverPlanner()

    func plan(applicationURL: URL, context: ScanContext) async throws -> AppUninstallPlan {
        try await planner.plan(applicationURL: applicationURL, context: context)
    }

    func plans(
        applicationURLs: [URL], context: ScanContext,
        onProgress: @escaping @Sendable (Int) async -> Void
    ) async throws -> [Result<AppUninstallPlan, Error>] {
        try await planner.plans(applicationURLs: applicationURLs, context: context, onProgress: onProgress)
    }

    func installedApplications(context: ScanContext) async -> [InstalledApplication] {
        let worker = Task.detached(priority: .userInitiated) {
            planner.installedApplications(context: context)
        }
        return await withTaskCancellationHandler {
            let applications = await worker.value
            return Task.isCancelled ? [] : applications
        } onCancel: {
            worker.cancel()
        }
    }

    func allocatedBytes(at url: URL, context: ScanContext) async throws -> Int64 {
        try await context.measurer.measure(url).allocatedBytes
    }

    func leftovers(context: ScanContext) async throws -> OrphanedAppLeftoverPlan {
        let candidates = await Task.detached(priority: .userInitiated) {
            leftoverPlanner.scanCandidates()
        }.value
        try Task.checkCancellation()
        let registered = await MainActor.run {
            ApplicationRuntime.registeredApplicationBundleIdentifiers(for: candidates.identifiers)
        }
        return try await leftoverPlanner.plan(
            context: context,
            registeredApplicationBundleIdentifiers: registered,
            candidates: candidates
        )
    }
}

protocol AppUninstallRemoving: Sendable {
    func removeSoundLibraries(
        _ plan: AppUninstallPlan, itemPaths: Set<String>,
        keepReceipt: Bool
    ) async throws -> CleanupOutcome

    func uninstall(
        _ plan: AppUninstallPlan, keepReceipt: Bool,
        confirmPermanentRemoval: @escaping @Sendable () async -> Bool
    ) async throws -> CleanupOutcome

    func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan,
        bundleIdentifiers: Set<String>,
        itemPaths: Set<String>?,
        registeredApplicationBundleIdentifiers: Set<String>,
        keepReceipt: Bool
    ) async throws -> CleanupOutcome
}

protocol HomebrewUninstallRemoving: Sendable {
    func uninstall(
        _ plan: AppUninstallPlan, keepReceipt: Bool
    ) async -> HomebrewUninstallOutcome
}

extension CleanupService: AppUninstallRemoving {}
extension HomebrewUninstallService: HomebrewUninstallRemoving {}

/// Checks the selected bundle and its helpers before removal.
@MainActor
struct AppUninstallApplications {
    var isRunning: @MainActor (URL) -> Bool = { !matching($0).isEmpty }
    var quit: @MainActor (URL) async -> Bool = { url in
        for application in matching(url) { application.terminate() }
        for _ in 0..<30 where !matching(url).isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return matching(url).isEmpty
    }
    var registeredIdentifiers: @MainActor (Set<String>) -> Set<String> = ApplicationRuntime.registeredApplicationBundleIdentifiers

    private static func matching(_ url: URL) -> [NSRunningApplication] {
        let path = url.standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { application in
            guard let bundle = application.bundleURL?.standardizedFileURL else { return false }
            return bundle.path == path || bundle.path.hasPrefix(path + "/")
        }
    }
}
