import Foundation
import MoppoCore
import Testing

@Suite("Scan and removal flows")
@MainActor
struct OperationFlowTests {
    @Test("Storage Explorer discards the current result after a file change")
    func explorerInvalidation() async throws {
        let folder = try FixtureFolder()
        let file = try folder.write("file.txt")
        let model = StorageExplorerModel()
        model.selectLocation(folder.url)
        try await waitUntil { !model.isLoading }
        let snapshot = try #require(model.snapshot)
        model.selection = [try #require(snapshot.items.first).id]

        try FileManager.default.removeItem(at: file)
        model.invalidateCache()

        #expect(model.snapshot == nil)
        #expect(model.selection.isEmpty)
        #expect(model.currentURL == folder.url.resolvingSymlinksInPath())
        model.refresh()
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot?.items.isEmpty == true)
    }

    @Test("An old folder scan cannot replace a later navigation result")
    func explorerNavigation() async throws {
        let first = try FixtureFolder()
        let second = try FixtureFolder()
        _ = try first.write("first.txt")
        _ = try second.write("second.txt")
        let model = StorageExplorerModel()

        model.selectLocation(first.url)
        model.selectLocation(second.url)
        try await waitUntil { !model.isLoading }

        #expect(model.snapshot?.items.map(\.name) == ["second.txt"])
        #expect(model.currentURL == second.url.resolvingSymlinksInPath())
    }

    @Test("A stopped folder scan permits another scan")
    func explorerCancellation() async throws {
        let folder = try FixtureFolder()
        _ = try folder.write("file.txt")
        let model = StorageExplorerModel()
        model.selectLocation(folder.url)
        model.cancel()
        #expect(model.isInterrupting)
        try await waitUntil { !model.isLoading }
        #expect(model.wasCancelled)
        #expect(model.snapshot == nil)

        model.refresh()
        try await waitUntil { !model.isLoading }
        #expect(!model.wasCancelled)
        #expect(!model.isInterrupting)
        #expect(model.snapshot?.items.count == 1)
    }

    @Test("Removed children leave an application leftover group and its selection")
    func pruneLeftoverChildren() throws {
        let folder = try FixtureFolder()
        let missing = try folder.write("removed.txt")
        let kept = try folder.write("kept.txt")
        let children = [missing, kept].map {
            FileEntry(url: $0, kind: .file, allocatedBytes: 100)
        }
        let group = FileEntry(
            url: missing, kind: .folder, allocatedBytes: 200,
            removalAction: .orphanedApplication(bundleIdentifier: "test.app"),
            childCount: 2, children: children
        )
        let model = AppModel()
        model.scanResults = ScanResults(
            categories: [ScanCategoryResult(
                categoryID: .applicationLeftovers, totalBytes: 200, entries: [group]
            )], startedAt: .now, finishedAt: .now
        )
        model.scannerSelection = [missing.path]
        try FileManager.default.removeItem(at: missing)

        model.pruneVanishedEntries()

        let result = try #require(model.scanResults?.categories.first)
        #expect(result.entries.first?.children.map(\.id) == [kept.path])
        #expect(result.totalBytes == 100)
        #expect(model.scannerSelection.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "The operation did not finish before the deadline.")
    }

    @Test("Put Back waits for scans and clears old folder results after restoration")
    func putBackAfterScan() async throws {
        let folder = try FixtureFolder()
        let trash = folder.url.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let trashed = try folder.write(".Trash/restore.txt")
        let original = folder.url.appendingPathComponent("restore.txt")
        let log = MoppoCore.RemovalLog(directory: folder.url.appendingPathComponent("logs"))
        try log.append([RemovalRecord(
            timestamp: .now, originalPath: original.path, bytes: 7,
            disposition: .trashed, trashedPath: trashed.path,
            trashedIdentity: FileIdentity.of(trashed)
        )])
        let model = AppModel(
            launchAccess: .limited,
            hasFullDiskAccess: { false },
            trashService: TrashService(home: folder.url, log: log),
            cleanupHistoryService: CleanupHistoryService(log: log)
        )
        model.storageExplorer.selectLocation(folder.url)
        try await waitUntil { !model.storageExplorer.isLoading }
        model.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        model.isScanningDuplicateFiles = true
        let item = TrashItem(url: trashed, bytes: 7, canPutBack: true)

        await model.putBack(item)
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))

        model.isScanningDuplicateFiles = false
        await model.putBack(item)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(model.trashSummary?.itemCount == 0)
        #expect(model.cleanupHistory?.items.first?.state == .restored)
        #expect(model.storageExplorer.snapshot == nil)
        #expect(model.storageExplorer.needsRefresh)
        #expect(model.scanResults == nil)
        #expect(!model.isBusyWithDisk)
    }

    @Test("A cancelled Trash refresh keeps the last complete result")
    func cancelledTrashRefresh() async throws {
        let folder = try FixtureFolder()
        let model = AppModel(trashService: TrashService(home: folder.url))
        let previous = TrashSummary(totalBytes: 123, itemCount: 1)
        model.trashSummary = previous
        let task = Task { await model.loadTrash() }
        task.cancel()
        await task.value

        #expect(model.trashSummary == previous)
        #expect(model.notice == nil)
    }

    @Test("Uninstall review waits for another scan")
    func uninstallReviewWhileBusy() {
        let model = AppModel(launchAccess: .limited, hasFullDiskAccess: { false })
        model.isScanningDuplicateFiles = true

        model.planAppUninstall(URL(fileURLWithPath: "/unused-fixture.app"))

        #expect(!model.isPlanningAppUninstall)
        #expect(model.notice?.title == "Wait for the Current Operation")
    }

    @Test("Uninstall planning blocks Storage Explorer until cancellation completes")
    func uninstallPlanningBlocksExplorer() async throws {
        let folder = try FixtureFolder()
        let model = AppModel(launchAccess: .limited, hasFullDiskAccess: { false })
        model.planAppUninstall(folder.url.appendingPathComponent("fixture.app"))
        #expect(model.isPlanningAppUninstall)
        #expect(model.isStorageExplorerMeasurementBlocked)

        model.resetAppUninstall()
        try await waitUntil { !model.isPlanningAppUninstall }
        #expect(!model.isStorageExplorerMeasurementBlocked)
        #expect(model.appUninstallPlan == nil)
    }

    @Test("A file duplicate scan continues after navigation and can restart after stopping")
    func duplicateScanNavigationAndRestart() async throws {
        let folder = try FixtureFolder()
        _ = try folder.write("first.txt")
        _ = try folder.write("second.txt")
        let model = AppModel()
        model.fileDuplicateMinimumBytes = 0
        model.startFileDuplicateScan(roots: [folder.url])
        model.cancelFileDuplicateScan()
        #expect(model.isInterruptingFileDuplicateScan)
        try await waitUntil { !model.isScanningDuplicateFiles }
        #expect(!model.isInterruptingFileDuplicateScan)

        model.startFileDuplicateScan(roots: [folder.url])
        model.view = .history
        try await waitUntil { !model.isScanningDuplicateFiles }
        #expect(model.view == .history)
        #expect(model.fileDuplicateResults?.groups.count == 1)
        #expect(!model.isBusyWithDisk)
    }

    @Test("History selects the recorded Trash item and rejects a replacement")
    func historyTrashLink() async throws {
        let fixture = try TrashFixture()
        let model = fixture.model()
        let receipt = try #require(fixture.history.summary().items.first)
        model.showInTrash(receipt)
        await model.loadTrash()
        #expect(model.view == .trash)
        let selected = try #require(model.trashSummary?.items.first {
            $0.id == model.selectedTrashItemID
        })
        #expect(FileIdentity.of(selected.url) == FileIdentity.of(fixture.trashed))

        try FileManager.default.moveItem(
            at: fixture.trashed, to: fixture.folder.url.appendingPathComponent("moved.txt")
        )
        _ = try fixture.folder.write(".Trash/item.txt")
        model.showInTrash(receipt)
        await model.loadTrash()
        #expect(model.selectedTrashItemID == nil)
        #expect(model.notice?.title == "Item Not Found")
    }

    @Test("A failed Put Back leaves both files intact and permits another attempt")
    func putBackRecovery() async throws {
        let fixture = try TrashFixture()
        _ = try fixture.folder.write("item.txt")
        let model = fixture.model()
        let item = TrashItem(url: fixture.trashed, bytes: 7, canPutBack: true)

        await model.putBack(item)
        #expect(FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(model.notice != nil)
        #expect(!model.isBusyWithDisk)

        try FileManager.default.removeItem(at: fixture.original)
        model.notice = nil
        await model.putBack(item)
        #expect(!FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(model.notice == nil)
        #expect(!model.isBusyWithDisk)
    }
}

private struct TrashFixture {
    let folder: FixtureFolder
    let trashed: URL
    let original: URL
    let service: TrashService
    let history: CleanupHistoryService

    init() throws {
        folder = try FixtureFolder()
        let trash = folder.url.appendingPathComponent(".Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        trashed = try folder.write(".Trash/item.txt")
        original = folder.url.appendingPathComponent("item.txt")
        let log = MoppoCore.RemovalLog(directory: folder.url.appendingPathComponent("logs"))
        try log.append([RemovalRecord(
            timestamp: .now, originalPath: original.path, bytes: 7,
            disposition: .trashed, trashedPath: trashed.path,
            trashedIdentity: FileIdentity.of(trashed)
        )])
        service = TrashService(home: folder.url, log: log)
        history = CleanupHistoryService(log: log)
    }

    @MainActor
    func model() -> AppModel {
        AppModel(
            launchAccess: .limited, hasFullDiskAccess: { false },
            trashService: service, cleanupHistoryService: history
        )
    }
}

private final class FixtureFolder {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("moppo-flow-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ name: String) throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data("Fixture".utf8).write(to: file)
        return file
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
