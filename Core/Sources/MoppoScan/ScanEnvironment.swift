import AppKit
import MoppoCore

public enum ScanEnvironment {
    public static func scan(_ configuration: ScanConfiguration,
                            progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }) async throws -> ScanResults {
        let context = try await context(configuration: configuration)
        return try await ScanCoordinator.standard().scan(enabled: configuration.enabledCategories,
                                                         context: context, onProgress: progress)
    }

    /// Cleanup cannot quit Moppo or Finder to release their files.
    @MainActor
    public static func canQuitForCleanup(_ owner: FileEntry.RunningOwner) -> Bool {
        if let identifier = owner.bundleIdentifier,
           identifier == ScanConfiguration.applicationDomain || identifier == Bundle.main.bundleIdentifier
            || identifier == "com.apple.finder" { return false }
        return URL(fileURLWithPath: owner.bundlePath).standardizedFileURL.path != Bundle.main.bundleURL.standardizedFileURL.path
    }

    @MainActor
    public static func currentRunningOwners() -> [FileEntry.RunningOwner] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular else { return nil }
            guard let url = application.bundleURL else { return nil }
            let owner = FileEntry.RunningOwner(
                name: application.localizedName
                    ?? url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: application.bundleIdentifier,
                bundlePath: url.path
            )
            return canQuitForCleanup(owner) ? owner : nil
        }
    }
    @MainActor
    public static func registeredApplicationBundleIdentifiers(
        for candidates: Set<String>
    ) -> Set<String> {
        let fileManager = FileManager.default
        return OrphanedAppLeftoverPlanner.registeredApplicationBundleIdentifiers(
            for: candidates,
            running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            isInstalled: { identifier in
                guard let application = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: identifier
                ) else { return false }
                return fileManager.fileExists(atPath: application.path)
            }
        )
    }

    public static func context(configuration: ScanConfiguration,
                               leftoverPlanner: OrphanedAppLeftoverPlanner = OrphanedAppLeftoverPlanner()) async throws -> ScanContext {
        let runtimeSpan = ScanDiagnostics.current?.begin("running_application_inventory")
        let (running, owners) = await MainActor.run {
            (
                Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL?.path }),
                ScanEnvironment.currentRunningOwners()
            )
        }
        ScanDiagnostics.current?.end(runtimeSpan, details: ["running_applications": "\(running.count)"])
        var registered: Set<String> = []
        var candidates: OrphanedAppLeftoverPlanner.CandidateScan?
        if configuration.enabledCategories.contains(.applicationLeftovers) {
            let planner = leftoverPlanner
            let discoverySpan = ScanDiagnostics.current?.begin("application_leftover_discovery")
            let diagnostics = ScanDiagnostics.current
            let scanned = await Task.detached {
                ScanDiagnostics.$current.withValue(diagnostics) { planner.scanCandidates() }
            }.value
            ScanDiagnostics.current?.end(discoverySpan, details: ["identifiers": "\(scanned.identifiers.count)"])
            try Task.checkCancellation()
            candidates = scanned
            let registrationSpan = ScanDiagnostics.current?.begin("registered_application_inventory")
            registered = await MainActor.run {
                ScanEnvironment.registeredApplicationBundleIdentifiers(for: scanned.identifiers)
            }
            ScanDiagnostics.current?.end(registrationSpan, details: ["registered_identifiers": "\(registered.count)"])
        }
        try Task.checkCancellation()
        let context = ScanContext(
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: configuration.excludedPaths,
            excludedPatterns: configuration.excludedPatterns,
            runningApplicationPaths: running,
            runningApplications: owners,
            registeredApplicationBundleIdentifiers: registered,
            applicationLeftoverCandidates: candidates
        )
        return context
    }
}
