import Foundation
import Testing
@testable import MoppoCore

@Suite("Cleanup feature ownership")
@MainActor
struct CleanupModelTests {
    @Test("Cancellation retains the guard and rejects old callbacks after a restart")
    func scanLifetime() async throws {
        let scanner = HeldCleanupScanner()
        let app = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        let cleanup = app.cleanup
        cleanup.startScan(refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        app.view = .history
        #expect(app.isStorageExplorerMeasurementBlocked)
        #expect(app.operations.begin(.photoScan) == nil)
        #expect(app.operations.begin(.fileRemoval) == nil)
        cleanup.cancelScan()
        #expect(cleanup.isInterruptingScan)
        cleanup.startScan(refreshOverview: false)
        #expect(await scanner.requestCount == 1)
        await scanner.report(0, percent: 99)
        await scanner.finish(0, results: cleanupResults([]))
        try await waitUntil { !cleanup.isScanning }
        #expect(cleanup.scanResults == nil)
        #expect(cleanup.scanProgress == 0)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)

        cleanup.startScan(automatic: true, refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 2 }
        #expect(app.view == .history)
        await scanner.report(1, percent: 32)
        try await waitUntil { cleanup.scanProgress == 32 }
        await scanner.report(0, percent: 98)
        let latest = cleanupResults([])
        await scanner.finish(1, results: latest)
        try await waitUntil { !cleanup.isScanning }
        #expect(cleanup.scanResults == latest)
        #expect(cleanup.scanProgress == 32)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)
    }

    @Test("A failed scan releases the guard and permits another scan")
    func scanFailure() async throws {
        let scanner = HeldCleanupScanner()
        let app = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        app.cleanup.startScan(refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.fail(0)
        try await waitUntil { !app.cleanup.isScanning }
        #expect(app.notice?.title == "The Scan Did Not Finish")
        #expect(!app.isBusyWithDisk)
        app.cleanup.startScan(refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 2 }
        app.cleanup.invalidateResults()
        await scanner.finish(1, results: cleanupResults([]))
        try await waitUntil { !app.cleanup.isScanning }
        #expect(app.cleanup.scanResults == nil)
        #expect(!app.cleanup.hasStartedInitialScan)
    }

    @Test("Other operations block Cleanup scans and removal", arguments: [
        OperationCoordinator.Kind.photoScan, .photoDeletion, .fileScan, .fileRemoval, .cleanupQuit
    ])
    func sharedGuard(_ kind: OperationCoordinator.Kind) async throws {
        let operations = OperationCoordinator()
        let scanner = HeldCleanupScanner()
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(operations: operations, scanner: scanner, remover: removal)
        let item = cleanupEntry("guard")
        cleanup.scanResults = cleanupResults([item])
        cleanup.scannerSelection = [item.id]
        cleanup.requestCleanUp(in: .all)
        let operation = try #require(operations.begin(kind))
        cleanup.startScan()
        await cleanup.performCleanUp()
        #expect(await scanner.requestCount == 0)
        #expect(await removal.requestCount == 0)
        #expect(cleanup.pendingCleanUp != nil)
        #expect(!cleanup.isRemoving)
        operations.finish(operation)
        cleanup.cancelCleanUp()
    }

    @Test("Scans capture preferences and seed safe selection only once")
    func preferencesAndSelection() async throws {
        let scanner = HeldCleanupScanner()
        var preferences = CleanupModel.Preferences(
            enabledCategories: [.systemCaches], excludedPaths: ["/excluded"], excludedPatterns: ["*.keep"]
        )
        let suite = "CleanupModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cleanup = CleanupModel(
            operations: OperationCoordinator(), scanner: scanner,
            preferences: { preferences }, defaults: defaults
        )
        let child = cleanupEntry("child")
        var parent = cleanupEntry("parent")
        parent.children = [child]
        var protected = cleanupEntry("protected")
        protected.protectionReason = .userData
        cleanup.scannerSelection = [protected.id]
        cleanup.userDataRemovalOverrides = [protected.id]
        cleanup.startScan()
        preferences.excludedPaths = ["/later"]
        #expect(cleanup.userDataRemovalOverrides.isEmpty)
        #expect(cleanup.scannerSelection.isEmpty)
        try await waitUntil { await scanner.requestCount == 1 }
        let captured = try #require(await scanner.preferences.first)
        #expect(captured.excludedPaths == ["/excluded"])
        #expect(captured.excludedPatterns == ["*.keep"])
        #expect(captured.enabledCategories == [.systemCaches])
        let results = cleanupResults([parent, protected])
        await scanner.finish(0, results: results)
        try await waitUntil { !cleanup.isScanning }
        #expect(cleanup.scannerSelection == [parent.id])
        #expect(cleanup.openCategories.isEmpty)
        #expect(cleanup.lastScanFinishedAt == results.finishedAt)
        #expect(defaults.object(forKey: "lastScanFinishedAt") as? Date == results.finishedAt)
        cleanup.deselectAll()
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection.isEmpty)
        cleanup.scanFilter = .all
        cleanup.selectAllInCurrentView()
        #expect(cleanup.scannerSelection == [parent.id])
        #expect(!cleanup.scannerSelection.contains(child.id))
    }

    @Test("Removal uses the captured plan and survives caller cancellation")
    func capturedPlanAndRemovalLifetime() async throws {
        let fixture = try CleanupFixture()
        let first = try fixture.entry("first")
        var protected = try fixture.entry("protected")
        protected.protectionReason = .userData
        let later = try fixture.entry("later")
        let removal = HeldCleanupRemoval()
        let operations = OperationCoordinator()
        var preferences = CleanupModel.Preferences(keepReceipt: false)
        let cleanup = CleanupModel(
            operations: operations, remover: removal, preferences: { preferences }, measureSaving: { _ in nil }
        )
        cleanup.scanResults = cleanupResults([first, protected, later])
        cleanup.scannerSelection = [first.id, protected.id]
        cleanup.userDataRemovalOverrides = [protected.id, later.id]
        cleanup.requestCleanUp(in: .all)
        #expect(cleanup.pendingCleanUp?.protectedDataCount == 1)
        cleanup.scannerSelection = [later.id]
        cleanup.userDataRemovalOverrides = [later.id]
        preferences.keepReceipt = true
        let refresh = CleanupGate()
        var completed: CleanupOutcome?
        cleanup.onEvent = { event in
            if case .removed(let outcome) = event { completed = outcome }
        }
        cleanup.refreshAfterRemoval = {
            #expect(!operations.isBusy)
            #expect(!cleanup.isRemoving)
            #expect(completed?.removedCount == 1)
            await refresh.wait()
        }
        let caller = Task { await cleanup.performCleanUp() }
        try await waitUntil { await removal.isPending }
        caller.cancel()
        #expect(operations.isBusy)
        #expect(cleanup.pendingCleanUp == nil)
        #expect(await removal.entries.map(\.id) == [first.id, protected.id])
        #expect(await removal.overrides == [protected.id])
        #expect(await removal.keepReceipt == false)
        #expect(await removal.trashFirst)
        #expect(await removal.privilegedFallback)
        #expect(operations.begin(.photoDeletion) == nil)
        await removal.finish(CleanupOutcome(
            removedBytes: first.allocatedBytes, removedCount: 1,
            failed: [protected.id], trashedCount: 1
        ))
        try await waitUntil { await refresh.isPending }
        #expect(cleanup.scanResults == nil)
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.userDataRemovalOverrides.isEmpty)
        #expect(completed?.failed == [protected.id])
        await refresh.finish()
        await caller.value
    }

    @Test("Cancelling confirmation rejects its delayed size measurement")
    func cancelledAndReplacedPlan() async throws {
        let fixture = try CleanupFixture()
        let first = try fixture.entry("first")
        let second = try fixture.entry("second")
        let measurements = CleanupMeasurements()
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(
            operations: OperationCoordinator(), remover: removal,
            measureSaving: { await measurements.measure($0) }
        )
        cleanup.scanResults = cleanupResults([first, second])
        cleanup.scannerSelection = [first.id]
        cleanup.requestCleanUp(in: .all)
        try await waitUntil { await measurements.count == 1 }
        let previous = cleanup.pendingCleanUp?.id
        cleanup.cancelCleanUp()
        await cleanup.performCleanUp()
        #expect(await removal.requestCount == 0)
        cleanup.scannerSelection = [second.id]
        cleanup.requestCleanUp(in: .all)
        try await waitUntil { await measurements.count == 2 }
        #expect(cleanup.pendingCleanUp?.id != previous)
        await measurements.finish(0, bytes: 99)
        await measurements.finish(1, bytes: 42)
        try await waitUntil { cleanup.pendingCleanUp?.freed?.privateBytes == 42 }
        #expect(cleanup.pendingCleanUp?.entries.map(\.id) == [second.id])
        cleanup.cancelCleanUp()
    }

    @Test("Quit refusal removes nothing and keeps the guard until the quit request returns")
    func quitRefusal() async throws {
        let removal = HeldCleanupRemoval()
        let gate = CleanupGate()
        let owner = FileEntry.RunningOwner(name: "Fixture", bundleIdentifier: "test.cleanup", bundlePath: "/fixture.app")
        var item = cleanupEntry("running")
        item.inUseBy = owner
        let operations = OperationCoordinator()
        let cleanup = CleanupModel(
            operations: operations, remover: removal,
            applications: CleanupApplications(stillRunning: { $0 }, quit: { owners in
                await gate.wait()
                return owners
            }, registeredIdentifiers: { _ in [] }),
            measureSaving: { _ in nil }
        )
        var failure: String?
        cleanup.onEvent = { event in
            if case .failure(let title, _) = event { failure = title }
        }
        cleanup.scanResults = cleanupResults([item])
        cleanup.scannerSelection = [item.id]
        cleanup.requestCleanUp(in: .all)
        let caller = Task { await cleanup.performCleanUp(quittingOwners: true) }
        try await waitUntil { await gate.isPending }
        caller.cancel()
        #expect(operations.isBusy)
        await gate.finish()
        await caller.value
        #expect(await removal.requestCount == 0)
        #expect(failure == "Nothing Was Removed")
        #expect(!operations.isBusy)
        #expect(cleanup.pendingCleanUp == nil)
        #expect(cleanup.scannerSelection == [item.id])
    }

    @Test("Partial cleanup retains its receipt and Put Back invalidates later results")
    func partialRemovalAndRecovery() async throws {
        let fixture = try CleanupFixture()
        let removable = try fixture.entry("removable")
        var protected = try fixture.entry("protected")
        protected.protectionReason = .userData
        let log = MoppoCore.RemovalLog(directory: fixture.root.appendingPathComponent("logs"))
        let suite = "CleanupRecoveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        settings.confirmBeforeCleanup = true
        let app = AppModel(
            settings: settings, launchAccess: .limited, hasFullDiskAccess: { false },
            trashService: TrashService(log: log),
            cleanupHistoryService: CleanupHistoryService(log: log),
            cleanupService: CleanupService(log: log)
        )
        app.cleanup.scanResults = cleanupResults([removable, protected])
        app.cleanup.scannerSelection = [removable.id, protected.id]
        app.cleanup.requestCleanUp(in: .all)
        #expect(app.activeSheet == .cleanUp)
        await app.cleanup.performCleanUp()
        #expect(app.activity == nil)
        #expect(!app.isBusyWithDisk)
        #expect(app.cleanupCompletion == nil)
        #expect(app.notice?.title == "Some Items Could Not Be Removed")
        #expect(app.cleanup.cleanupOutcome?.removedCount == 1)
        #expect(app.cleanup.scanResults == nil)
        #expect(FileManager.default.fileExists(atPath: protected.url.path))
        let receipt = try #require(log.recentEntries(limit: 10).first { $0.disposition == .trashed })
        let trashed = URL(fileURLWithPath: try #require(receipt.trashedPath))
        defer { try? FileManager.default.removeItem(at: trashed) }
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(receipt.originalPath == removable.id)
        app.cleanup.scanResults = cleanupResults([protected])
        app.cleanup.scannerSelection = [protected.id]
        app.cleanup.userDataRemovalOverrides = [protected.id]
        app.cleanup.requestCleanUp(in: .all)
        await app.recovery.putBack(TrashItem(url: trashed, bytes: receipt.bytes, canPutBack: true))
        #expect(FileManager.default.fileExists(atPath: removable.id))
        #expect(app.cleanup.scanResults == nil)
        #expect(app.cleanup.scannerSelection.isEmpty)
        #expect(app.cleanup.pendingCleanUp == nil)
        #expect(app.cleanup.userDataRemovalOverrides.isEmpty)
        #expect(app.recovery.cleanupHistory?.items.first { $0.originalURL.path == removable.id }?.state == .restored)
    }

    @Test("The scan service preserves exclusions, category settings, and leftover candidates", arguments: [false, true])
    func scanContext(leftoversEnabled: Bool) async throws {
        let fixture = try CleanupFixture()
        let evidence = fixture.root.appendingPathComponent("Library/Saved Application State/com.moppo.cleanupfixture.savedState")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let recorder = CleanupContextRecorder(id: .systemCaches)
        let disabled = CleanupContextRecorder(id: .documentsAndFiles)
        let planner = AppUninstallPlanner(
            home: fixture.root, systemLibrary: fixture.root.appendingPathComponent("SystemLibrary"),
            applicationRoots: [fixture.root.appendingPathComponent("Applications")],
            darwinCache: nil, darwinTemp: nil
        )
        let service = CleanupScanService(
            coordinator: ScanCoordinator(scanners: [recorder, disabled]),
            leftoverPlanner: OrphanedAppLeftoverPlanner(pathPlanner: planner)
        )
        let preferences = CleanupModel.Preferences(
            enabledCategories: leftoversEnabled ? [.systemCaches, .applicationLeftovers] : [.systemCaches],
            excludedPaths: ["/excluded"], excludedPatterns: ["*.keep"]
        )
        let result = try await service.scan(preferences: preferences, onProgress: { _ in })
        let context = try #require(await recorder.context)
        #expect(context.excludedPaths == ["/excluded"])
        #expect(context.excludedPatterns == ["*.keep"])
        #expect(context.measurer.protectedPatterns == ["*.keep"])
        #expect(!context.measurer.followSymlinks)
        #expect(await disabled.context == nil)
        #expect(result.categories.map(\.categoryID) == [.systemCaches])
        if leftoversEnabled {
            #expect(context.applicationLeftoverCandidates?.identifiers == ["com.moppo.cleanupfixture"])
        } else {
            #expect(context.applicationLeftoverCandidates == nil)
        }
    }

    @Test("Cleanup without confirmation captures the selection before its task starts")
    func immediateRemoval() async throws {
        let fixture = try CleanupFixture()
        let first = try fixture.entry("first")
        let later = try fixture.entry("later")
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(
            operations: OperationCoordinator(), remover: removal,
            preferences: { CleanupModel.Preferences(confirmBeforeCleanup: false) }
        )
        cleanup.scanResults = cleanupResults([first, later])
        cleanup.scannerSelection = [first.id]
        cleanup.requestCleanUp(in: .all)
        #expect(cleanup.isRemoving)
        #expect(cleanup.pendingCleanUp == nil)
        cleanup.scannerSelection = [later.id]
        cleanup.requestCleanUp(in: .all)
        try await waitUntil { await removal.isPending }
        #expect(await removal.entries.map(\.id) == [first.id])
        #expect(await removal.requestCount == 1)
        await removal.finish(CleanupOutcome(failed: [first.id]))
        try await waitUntil { !cleanup.isRemoving }
        #expect(cleanup.cleanupOutcome?.failed == [first.id])
        #expect(cleanup.scanResults != nil)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "The operation did not finish before the deadline.")
    }
}

private func cleanupEntry(_ name: String) -> FileEntry {
    FileEntry(url: URL(fileURLWithPath: "/cleanup-fixture/\(name)"), kind: .file, allocatedBytes: 100, isRegenerable: true)
}

private func cleanupResults(_ entries: [FileEntry]) -> ScanResults {
    ScanResults(categories: [ScanCategoryResult(
        categoryID: .systemCaches, totalBytes: entries.reduce(0) { $0 + $1.allocatedBytes }, entries: entries
    )], startedAt: .now, finishedAt: .now)
}

private actor HeldCleanupScanner: CleanupScanning {
    private(set) var preferences: [CleanupModel.Preferences] = []
    private var scans: [Int: CheckedContinuation<ScanResults, any Error>] = [:]
    private var reports: [Int: @Sendable (ScanProgress) -> Void] = [:]
    var requestCount: Int { preferences.count }
    func scan(
        preferences: CleanupModel.Preferences,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResults {
        let index = requestCount
        self.preferences.append(preferences)
        reports[index] = onProgress
        return try await withCheckedThrowingContinuation { scans[index] = $0 }
    }
    func report(_ index: Int, percent: Int) {
        reports[index]?(ScanProgress(percent: percent, completedCategories: 1, totalCategories: 2))
    }
    func finish(_ index: Int, results: ScanResults) { scans.removeValue(forKey: index)?.resume(returning: results) }
    func fail(_ index: Int) { scans.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadUnknown)) }
}

private actor HeldCleanupRemoval: CleanupRemoving {
    private(set) var requestCount = 0
    private(set) var entries: [FileEntry] = []
    private(set) var overrides: Set<FileEntry.ID> = []
    private(set) var keepReceipt = true
    private(set) var trashFirst = false
    private(set) var privilegedFallback = false
    private var continuation: CheckedContinuation<CleanupOutcome, Never>?
    var isPending: Bool { continuation != nil }
    func remove(
        entries: [FileEntry], trashFirst: Bool, privilegedFallback: Bool, keepReceipt: Bool,
        userDataRemovalOverrides: Set<FileEntry.ID>, appDataRemovalOverrides: Set<FileEntry.ID>,
        expectedIdentities: [FileEntry.ID: String]
    ) async throws -> CleanupOutcome {
        requestCount += 1
        self.entries = entries
        self.overrides = userDataRemovalOverrides
        self.keepReceipt = keepReceipt
        self.trashFirst = trashFirst
        self.privilegedFallback = privilegedFallback
        return await withCheckedContinuation { continuation = $0 }
    }
    func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan, bundleIdentifiers: Set<String>, itemPaths: Set<String>?,
        registeredApplicationBundleIdentifiers: Set<String>, privilegedFallback: Bool, keepReceipt: Bool
    ) async throws -> CleanupOutcome {
        CleanupOutcome(failed: plan.items(for: bundleIdentifiers, itemPaths: itemPaths).map(\.id))
    }
    func finish(_ result: CleanupOutcome) { continuation?.resume(returning: result); continuation = nil }
}

private actor CleanupGate {
    private var continuation: CheckedContinuation<Void, Never>?
    var isPending: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}

private actor CleanupMeasurements {
    private var continuations: [Int: CheckedContinuation<PrivateSizeMeasurement?, Never>] = [:]
    private(set) var count = 0
    func measure(_ urls: [URL]) async -> PrivateSizeMeasurement? {
        let index = count
        count += 1
        return await withCheckedContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, bytes: Int64) {
        continuations.removeValue(forKey: index)?.resume(returning: PrivateSizeMeasurement(privateBytes: bytes))
    }
}

private final class CleanupFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-cleanup-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    func entry(_ name: String) throws -> FileEntry {
        let url = root.appendingPathComponent("\(name)-\(root.lastPathComponent).txt")
        try Data("Disposable Cleanup fixture".utf8).write(to: url)
        return FileEntry(url: url, kind: .file, allocatedBytes: 4096, isRegenerable: true)
    }
    deinit { try? FileManager.default.removeItem(at: root) }
}

private actor CleanupContextRecorder: CategoryScanner {
    nonisolated let id: CategoryID
    private(set) var context: ScanContext?
    init(id: CategoryID) { self.id = id }
    func scan(context: ScanContext) async throws -> ScanCategoryResult {
        self.context = context
        return ScanCategoryResult(categoryID: id, totalBytes: 0, entries: [])
    }
}
