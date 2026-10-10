import Foundation
import Testing
@testable import MoppoCore

@Suite("File duplicate feature ownership")
@MainActor
struct FileDuplicatesModelTests {
    @Test("A stopped scan holds the guard and rejects late progress and results")
    func cancellationAndNavigation() async throws {
        let service = HeldFileScanner()
        let app = AppModel(fileDuplicateService: service)
        let files = app.fileDuplicates
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { await service.pendingCount == 1 }
        #expect(app.view == .duplicates)
        #expect(app.duplicateKind == .files)
        app.view = .history
        #expect(app.isBusyWithDisk)
        #expect(app.storageExplorer.isMeasurementBlocked)
        app.cleanup.startScan()
        #expect(!app.cleanup.isScanning)
        #expect(app.isBusyWithDisk)

        files.cancelScan()
        #expect(files.isInterrupting)
        files.startScan(roots: [URL(fileURLWithPath: "/blocked-fixture")])
        #expect(await service.requestCount == 1)
        #expect(app.isBusyWithDisk)
        await service.report(0, completed: 90)
        await service.finish(0, results: fileResults("cancelled"))
        try await waitUntil { !files.isScanning }
        #expect(files.results == nil)
        #expect(files.progress == nil)
        #expect(!files.isInterrupting)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)

        files.startScan(roots: [URL(fileURLWithPath: "/current-fixture")])
        try await waitUntil { await service.pendingCount == 1 }
        app.view = .dashboard
        await service.report(1, completed: 32)
        try await waitUntil { files.progress?.completed == 32 }
        await service.report(0, completed: 99)
        await service.finish(1, results: fileResults("current"))
        try await waitUntil { !files.isScanning }
        #expect(files.groups.first?.id == "current")
        #expect(files.progress?.completed == 32)
        #expect(files.selection.isEmpty)
        #expect(app.view == .dashboard)
        #expect(!app.isBusyWithDisk)
    }

    @Test("Another operation blocks file scans and removal")
    func otherOperationsBlockFiles() async throws {
        let scanner = HeldFileScanner(results: fileResults("initial"))
        let removal = HeldFileRemoval()
        let app = AppModel(fileDuplicateService: scanner, fileDuplicateRemovalService: removal)
        let files = app.fileDuplicates
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        _ = app.operations.begin(.photoScan)
        files.startScan()
        await files.removeSelected()
        #expect(!files.isScanning)
        #expect(!files.isRemoving)
        #expect(await scanner.requestCount == 1)
        #expect(await removal.requestCount == 0)
        #expect(!files.selection.isEmpty)
    }

    @Test("Filters and keeper changes cannot select a keeper or a hidden file")
    func selectionOwnership() async throws {
        var results = fileResults("small", bytes: 10)
        results.groups += fileResults("large", bytes: 100).groups
        let scanner = HeldFileScanner(results: results)
        let files = FileDuplicatesModel(operations: OperationCoordinator(), service: scanner)
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.toggle("/small/keeper")
        files.toggle("/unknown")
        #expect(files.selection.isEmpty)
        files.toggleGroup("small")
        #expect(files.isGroupSelected("small"))
        files.keepInstead(groupID: "small", fileID: "/small/copy-1")
        #expect(files.groups.first?.keeper.id == "/small/copy-1")
        #expect(files.selection == ["/small/keeper", "/small/copy-2"])
        #expect(files.selectionBytes == 20)
        files.selectAll()
        files.minimumBytes = 50
        #expect(files.groups.map(\.id) == ["large"])
        #expect(files.selection == ["/large/copy-1", "/large/copy-2"])
        files.toggleGroup("small")
        files.toggle("/small/keeper")
        files.keepInstead(groupID: "small", fileID: "/small/copy-2")
        files.minimumBytes = 0
        #expect(!files.selection.contains("/small/keeper"))
        #expect(files.groups.first?.keeper.id == "/small/copy-1")
        #expect(await scanner.requestCount == 1)
        files.deselectAll()
        #expect(files.selection.isEmpty)
    }

    @Test("File removal survives caller cancellation and publishes completion before refresh")
    func removalLifetime() async throws {
        let scanner = HeldFileScanner(results: fileResults("initial"))
        let removal = HeldFileRemoval()
        let app = AppModel(fileDuplicateService: scanner, fileDuplicateRemovalService: removal)
        let files = app.fileDuplicates
        let refresh = TestGate()
        files.refreshAfterRemoval = {
            #expect(!app.isBusyWithDisk)
            #expect(app.activity == nil)
            #expect(app.removalCompletion?.title == "Some items were not removed")
            await refresh.wait()
        }
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        let task = Task { await files.removeSelected() }
        try await waitUntil { await removal.isPending }
        #expect(files.isRemoving)
        #expect(app.isRemovingDuplicateFiles)
        #expect(app.storageExplorer.isMeasurementBlocked)
        #expect(app.removalCompletion == nil)
        let selected = files.selection
        files.keepInstead(groupID: "initial", fileID: "/initial/copy-1")
        files.deselectAll()
        files.toggleGroup("initial")
        #expect(files.selection == selected)
        #expect(files.groups.first?.keeper.id == "/initial/keeper")
        await files.removeSelected()
        files.startScan()
        #expect(await removal.requestCount == 1)
        #expect(await scanner.requestCount == 1)
        task.cancel()
        await removal.finish(FileDuplicateRemovalOutcome(cleanup: CleanupOutcome(
            removedBytes: 10, removedCount: 1,
            failed: ["/initial/copy-2"], permissionDenied: ["/initial/copy-2"], trashedCount: 1
        )))
        try await waitUntil { await refresh.isPending }
        #expect(!files.isRemoving)
        #expect(files.selection == ["/initial/copy-2"])
        #expect(files.groups.first?.removable.map(\.id) == ["/initial/copy-2"])
        #expect(app.removalCompletion?.destination == .duplicates)
        #expect(app.removalCompletion?.isSuccess == false)

        // A finished refresh cannot clear the operation started after removal.
        await scanner.hold()
        files.startScan()
        try await waitUntil { await scanner.pendingCount == 1 }
        await refresh.finish()
        await task.value
        #expect(files.isScanning)
        #expect(app.isBusyWithDisk)
        await scanner.finish(1, results: fileResults("later"))
        try await waitUntil { !files.isScanning }
        #expect(files.groups.first?.id == "later")
        #expect(!app.isBusyWithDisk)
    }

    @Test("Changed groups and files leave the results and selection")
    func staleRemoval() async throws {
        var results = fileResults("changed-group")
        results.groups += fileResults("changed-copy").groups
        let removal = HeldFileRemoval()
        let files = FileDuplicatesModel(
            operations: OperationCoordinator(), service: HeldFileScanner(results: results), removalService: removal
        )
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        let task = Task { await files.removeSelected() }
        try await waitUntil { await removal.isPending }
        await removal.finish(FileDuplicateRemovalOutcome(
            cleanup: CleanupOutcome(failed: Array(files.selection)),
            staleFileIDs: ["/changed-copy/copy-1"], staleGroupIDs: ["changed-group"]
        ))
        await task.value
        #expect(files.groups.map(\.id) == ["changed-copy"])
        #expect(files.selection == ["/changed-copy/copy-2"])
        #expect(!files.isBusyWithDisk)
    }

    @Test("Failed scans and removals release the guard and permit retry")
    func serviceFailures() async throws {
        let scanner = HeldFileScanner(results: fileResults("initial"))
        let removal = HeldFileRemoval()
        let app = AppModel(fileDuplicateService: scanner, fileDuplicateRemovalService: removal)
        let files = app.fileDuplicates
        files.refreshAfterRemoval = {}
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        let selected = files.selection
        let task = Task { await files.removeSelected() }
        try await waitUntil { await removal.isPending }
        await removal.fail()
        await task.value
        #expect(files.selection == selected)
        #expect(app.notice?.title == "The Duplicates Could Not Be Moved")
        #expect(app.activity == nil)
        #expect(!app.isBusyWithDisk)

        await scanner.hold()
        files.startScan()
        try await waitUntil { await scanner.pendingCount == 1 }
        await scanner.fail(1)
        try await waitUntil { !files.isScanning }
        #expect(app.notice?.title == "The Duplicate Scan Did Not Finish")
        #expect(files.groups.first?.id == "initial")
        #expect(files.selection.isEmpty)
        #expect(!app.isBusyWithDisk)
        files.startScan()
        try await waitUntil { await scanner.pendingCount == 1 }
        await scanner.finish(2, results: fileResults("retry"))
        try await waitUntil { !files.isScanning }
        #expect(files.groups.first?.id == "retry")
    }

    @Test("Invalidation rejects an unfinished scan without releasing its guard early")
    func invalidateDuringScan() async throws {
        let scanner = HeldFileScanner()
        let files = FileDuplicatesModel(operations: OperationCoordinator(), service: scanner)
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { await scanner.pendingCount == 1 }
        files.invalidateResults()
        #expect(files.isBusyWithDisk)
        #expect(files.isInterrupting)
        await scanner.finish(0, results: fileResults("obsolete"))
        try await waitUntil { !files.isScanning }
        #expect(files.results == nil)
        #expect(files.selection.isEmpty)
        #expect(!files.isBusyWithDisk)
    }

    @Test("Each operation reads current exclusions and receipt preferences")
    func preferences() async throws {
        let scanner = HeldFileScanner(results: fileResults("initial"))
        let removal = HeldFileRemoval()
        var preferences = FileDuplicatesModel.Preferences(excludedPaths: ["/excluded"], excludedPatterns: ["*.tmp"])
        let files = FileDuplicatesModel(
            operations: OperationCoordinator(), service: scanner, removalService: removal, preferences: { preferences }
        )
        files.minimumBytes = 0
        let roots = [URL(fileURLWithPath: "/file-fixture")]
        files.startScan(roots: roots)
        preferences.excludedPaths = ["/later"]
        try await waitUntil { !files.isScanning }
        let first = try #require(await scanner.requests.first)
        #expect(first.roots == roots)
        #expect(first.options.minimumLogicalBytes == 0)
        #expect(first.excludedPaths == ["/excluded"])
        #expect(first.excludedPatterns == ["*.tmp"])
        files.startScan()
        try await waitUntil { !files.isScanning }
        #expect(await scanner.requests.last?.excludedPaths == ["/later"])
        preferences.keepReceipt = false
        files.selectAll()
        let task = Task { await files.removeSelected() }
        try await waitUntil { await removal.isPending }
        #expect(await removal.keepsReceipt == false)
        #expect(await removal.usesPrivilegedFallback == true)
        await removal.finish(FileDuplicateRemovalOutcome(cleanup: CleanupOutcome(failed: Array(files.selection))))
        await task.value
    }

    @Test("Partial removal preserves receipts and Put Back clears the file review")
    func partialRemovalAndRecovery() async throws {
        let fixture = try FileRemovalFixture()
        let log = MoppoCore.RemovalLog(directory: fixture.root.appendingPathComponent("logs"))
        defer { fixture.removeTrashedFixtures(log) }
        let app = AppModel(
            launchAccess: .limited, hasFullDiskAccess: { false },
            trashService: TrashService(home: fixture.root, log: log),
            cleanupHistoryService: CleanupHistoryService(log: log),
            fileDuplicateRemovalService: FileDuplicateRemovalService(cleanup: CleanupService(log: log))
        )
        let files = app.fileDuplicates
        files.minimumBytes = 0
        files.startScan(roots: [fixture.root])
        try await waitUntil { !files.isScanning }
        let group = try #require(files.groups.first)
        let changed = try #require(group.removable.first)
        try Data("Changed after the scan".utf8).write(to: changed.url)
        files.selectAll()
        app.cleanup.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        app.storageExplorer.selectLocation(fixture.root)
        try await waitUntil { !app.storageExplorer.isLoading }
        await files.removeSelected()
        #expect(FileManager.default.fileExists(atPath: group.keeper.url.path))
        #expect(FileManager.default.fileExists(atPath: changed.url.path))
        #expect(files.groups.isEmpty)
        #expect(files.selection.isEmpty)
        #expect(app.removalCompletion?.title == "Some items were not removed")
        #expect(app.cleanup.scanResults == nil)
        #expect(app.storageExplorer.snapshot == nil)
        #expect(app.storageExplorer.needsRefresh)
        #expect(!app.isBusyWithDisk)
        let receipts = log.recentEntries(limit: 10).filter { $0.disposition == .trashed }
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        let trashed = URL(fileURLWithPath: try #require(receipt.trashedPath))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        await app.recovery.loadCleanupHistory()
        #expect(app.recovery.cleanupHistory?.items.first?.state == .availableInTrash)

        // A later review must be discarded when a removed file returns.
        _ = try fixture.writeCopy("later")
        files.startScan(roots: [fixture.root])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        #expect(!files.selection.isEmpty)
        await app.recovery.putBack(TrashItem(url: trashed, bytes: receipt.bytes, canPutBack: true))
        #expect(FileManager.default.fileExists(atPath: receipt.originalPath))
        #expect(files.results == nil)
        #expect(files.selection.isEmpty)
        #expect(app.recovery.cleanupHistory?.items.first?.state == .restored)
    }
}

private func fileResults(_ id: String, bytes: Int64 = 10) -> FileDuplicateResults {
    let file: (String) -> DuplicateFile = { name in
        DuplicateFile(url: URL(fileURLWithPath: "/\(id)/\(name)"), logicalBytes: bytes, allocatedBytes: bytes)
    }
    return FileDuplicateResults(groups: [FileDuplicateGroup(
        id: id, keeper: file("keeper"), removable: [file("copy-1"), file("copy-2")], contentDigest: "fixture"
    )], roots: [URL(fileURLWithPath: "/\(id)")])
}

private actor HeldFileScanner: FileDuplicatesScanning {
    struct Request: Sendable {
        let roots: [URL]
        let options: FileDuplicateService.Options
        let excludedPaths: [String]
        let excludedPatterns: [String]
    }
    private var results: FileDuplicateResults?
    private var scans: [Int: CheckedContinuation<FileDuplicateResults, any Error>] = [:]
    private var reports: [Int: @Sendable (FileDuplicateService.Progress) -> Void] = [:]
    private(set) var requests: [Request] = []
    var requestCount: Int { requests.count }
    var pendingCount: Int { scans.count }
    init(results: FileDuplicateResults? = nil) { self.results = results }
    func hold() { results = nil }

    func scan(
        roots: [URL], options: FileDuplicateService.Options,
        excludedPaths: [String], excludedPatterns: [String],
        onProgress: (@Sendable (FileDuplicateService.Progress) -> Void)?
    ) async throws -> FileDuplicateResults {
        let index = requests.count
        requests.append(Request(roots: roots, options: options, excludedPaths: excludedPaths, excludedPatterns: excludedPatterns))
        reports[index] = onProgress
        if let results { return results }
        return try await withCheckedThrowingContinuation { scans[index] = $0 }
    }
    func report(_ index: Int, completed: Int) {
        reports[index]?(.init(stage: .verifying, completed: completed, total: 100))
    }
    func finish(_ index: Int, results: FileDuplicateResults) {
        scans.removeValue(forKey: index)?.resume(returning: results)
    }
    func fail(_ index: Int) {
        scans.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadUnknown))
    }
}

private actor HeldFileRemoval: FileDuplicatesRemoving {
    private var continuation: CheckedContinuation<FileDuplicateRemovalOutcome, any Error>?
    private(set) var requestCount = 0
    private(set) var keepsReceipt = true
    private(set) var usesPrivilegedFallback = false
    var isPending: Bool { continuation != nil }
    func remove(
        selectedIDs: Set<DuplicateFile.ID>, from groups: [FileDuplicateGroup],
        privilegedFallback: Bool, keepReceipt: Bool
    ) async throws -> FileDuplicateRemovalOutcome {
        requestCount += 1
        keepsReceipt = keepReceipt
        usesPrivilegedFallback = privilegedFallback
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ outcome: FileDuplicateRemovalOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
    func fail() {
        continuation?.resume(throwing: CocoaError(.fileWriteUnknown))
        continuation = nil
    }
}

private final class FileRemovalFixture {
    private let folder: TemporaryFolder
    private let suffix = UUID().uuidString
    var root: URL { folder.url }

    init() throws {
        folder = try TemporaryFolder(prefix: "moppo-file-model")
        for name in ["first", "second", "third"] { _ = try writeCopy(name) }
    }

    func writeCopy(_ name: String) throws -> URL {
        try folder.write("moppo-\(name)-\(suffix).txt", contents: "Verified fixture contents")
    }

    func removeTrashedFixtures(_ log: MoppoCore.RemovalLog) {
        for receipt in log.recentEntries(limit: 10) where receipt.disposition == .trashed {
            guard let path = receipt.trashedPath,
                  URL(fileURLWithPath: path).lastPathComponent.contains(suffix) else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
