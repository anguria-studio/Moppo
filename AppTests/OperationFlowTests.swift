import Foundation
import MoppoCore
import Testing

@Suite("Scan and removal flows")
@MainActor
struct OperationFlowTests {
    @Test("Storage Explorer discards the current result after a file change")
    func explorerInvalidation() async throws {
        let folder = try TemporaryFolder()
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

    @Test("Removed children leave an application leftover group and its selection")
    func pruneLeftoverChildren() throws {
        let folder = try TemporaryFolder()
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
        model.cleanup.scanResults = ScanResults(
            categories: [ScanCategoryResult(
                categoryID: .applicationLeftovers, totalBytes: 200, entries: [group]
            )], startedAt: .now, finishedAt: .now
        )
        model.cleanup.scannerSelection = [missing.path]
        try FileManager.default.removeItem(at: missing)

        model.cleanup.pruneVanishedEntries()

        let result = try #require(model.cleanup.scanResults?.categories.first)
        #expect(result.entries.first?.children.map(\.id) == [kept.path])
        #expect(result.totalBytes == 100)
        #expect(model.cleanup.scannerSelection.isEmpty)
    }

    @Test("An unavailable cached folder reports an error and permits retry", arguments: [false, true])
    func unavailableCachedFolder(denyAccess: Bool) async throws {
        let folder = try TemporaryFolder()
        let other = try TemporaryFolder()
        _ = try folder.write("file.txt")
        let model = StorageExplorerModel()
        model.selectLocation(folder.url)
        try await waitUntil { !model.isLoading }
        model.navigate(to: other.url)
        try await waitUntil { !model.isLoading }

        let moved = other.url.appendingPathComponent("disconnected")
        if denyAccess {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.url.path)
        } else {
            try FileManager.default.moveItem(at: folder.url, to: moved)
        }
        defer {
            if denyAccess {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path)
            }
        }
        model.goBack()
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot == nil)
        #expect(model.selection.isEmpty)
        #expect(model.error == .unavailable(folder.url.path))

        if denyAccess {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.url.path)
        } else {
            try FileManager.default.moveItem(at: moved, to: folder.url)
        }
        model.refresh()
        try await waitUntil { !model.isLoading }
        #expect(model.error == nil)
        #expect(model.snapshot?.items.map(\.name) == ["file.txt"])
    }

    @Test("A replacement folder cannot reuse a previous folder result")
    func replacedCachedFolder() async throws {
        let folder = try TemporaryFolder()
        let other = try TemporaryFolder()
        _ = try folder.write("old.txt")
        let model = StorageExplorerModel()
        model.selectLocation(folder.url)
        try await waitUntil { !model.isLoading }
        model.navigate(to: other.url)
        try await waitUntil { !model.isLoading }
        try FileManager.default.moveItem(at: folder.url, to: other.url.appendingPathComponent("old"))
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        _ = try folder.write("new.txt")
        model.goBack()
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot?.items.map(\.name) == ["new.txt"])
    }

    @Test("A disconnected volume discards cached results and permits reconnection")
    func disconnectedVolume() async throws {
        let folder = try TemporaryFolder()
        let image = folder.url.appendingPathComponent("volume.dmg")
        let mount = folder.url.appendingPathComponent("mount")
        defer { _ = try? Self.runHdiutil(["detach", "-quiet", mount.path]) }
        try #require(Self.runHdiutil([
            "create", "-quiet", "-size", "32m", "-fs", "APFS", "-volname", "MoppoRecoveryTest", image.path
        ]) == 0)
        let attach = ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image.path]
        try #require(Self.runHdiutil(attach) == 0)
        try Data("Fixture".utf8).write(to: mount.appendingPathComponent("file.txt"))
        let model = StorageExplorerModel()
        model.selectLocation(mount)
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot?.items.contains { $0.name == "file.txt" } == true)
        model.navigate(to: folder.url)
        try await waitUntil { !model.isLoading }
        try #require(Self.runHdiutil(["detach", "-quiet", mount.path]) == 0)
        model.goBack()
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot == nil)
        #expect(model.error == .unavailable(mount.path))
        try #require(Self.runHdiutil(attach) == 0)
        model.refresh()
        try await waitUntil { !model.isLoading }
        #expect(model.error == nil)
        #expect(model.snapshot?.items.contains { $0.name == "file.txt" } == true)
    }

    private static func runHdiutil(_ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test("Put Back waits for scans and clears old folder results after restoration")
    func putBackAfterScan() async throws {
        let folder = try TemporaryFolder()
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
        model.cleanup.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        let operation = try #require(model.operations.begin(.fileScan))
        let item = TrashItem(url: trashed, bytes: 7, canPutBack: true)

        await model.recovery.putBack(item)
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(!FileManager.default.fileExists(atPath: original.path))

        model.operations.finish(operation)
        await model.recovery.putBack(item)
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(model.recovery.trashSummary?.itemCount == 0)
        #expect(model.recovery.cleanupHistory?.items.first?.state == .restored)
        #expect(model.storageExplorer.snapshot == nil)
        #expect(model.storageExplorer.needsRefresh)
        #expect(model.cleanup.scanResults == nil)
        #expect(!model.isBusyWithDisk)
    }

    @Test("A cancelled Trash refresh keeps the last complete result")
    func cancelledTrashRefresh() async throws {
        let folder = try TemporaryFolder()
        let model = AppModel(trashService: TrashService(home: folder.url))
        let previous = TrashSummary(totalBytes: 123, itemCount: 1)
        model.recovery.trashSummary = previous
        let task = Task { await model.recovery.loadTrash() }
        task.cancel()
        await task.value

        #expect(model.recovery.trashSummary == previous)
        #expect(model.notice == nil)
    }

    @Test("Uninstall review waits for another scan")
    func uninstallReviewWhileBusy() {
        let model = AppModel(launchAccess: .limited, hasFullDiskAccess: { false })
        _ = model.operations.begin(.fileScan)

        model.uninstaller.planAppUninstall(URL(fileURLWithPath: "/unused-fixture.app"))

        #expect(!model.uninstaller.isPlanningAppUninstall)
        #expect(model.notice == nil)
        #expect(model.operations.blockedAction?.message
                == "Duplicate file scan is running. Wait for it to finish, or stop the scan.")
    }

    @Test("Dashboard history rows use scan feedback without opening a folder or an alert")
    func growthRowWhileBusy() throws {
        let model = AppModel(launchAccess: .limited, hasFullDiskAccess: { false })
        model.view = .dashboard
        let operation = try #require(model.operations.begin(.cleanupScan))
        let attribution = GrowthAttribution(
            path: "/unused-fixture/Documents", segment: .documentsDesktop, deltaBytes: 100, kind: .grew
        )

        model.revealGrowth(attribution)

        let feedback = try #require(model.operations.blockedAction)
        #expect(feedback.operation == operation)
        #expect(model.notice == nil)
        #expect(model.view == .dashboard)
        #expect(model.storageExplorer.currentURL == nil)
        model.revealGrowth(attribution)
        #expect(model.operations.blockedAction == feedback)
        model.operations.finish(operation)
        #expect(model.operations.blockedAction == nil)
        #expect(model.view == .dashboard)
        #expect(model.storageExplorer.currentURL == nil)
    }

    @Test("History selects the recorded Trash item and rejects a replacement")
    func historyTrashLink() async throws {
        let fixture = try TrashFixture()
        let model = fixture.model()
        let receipt = try #require(fixture.history.summary().items.first)
        model.recovery.showInTrash(receipt)
        await model.recovery.loadTrash()
        #expect(model.view == .trash)
        let selected = try #require(model.recovery.trashSummary?.items.first {
            model.recovery.selectedTrashItemIDs.contains($0.id)
        })
        #expect(FileIdentity.of(selected.url) == FileIdentity.of(fixture.trashed))
        #expect(selected.originalURL == fixture.original)

        try FileManager.default.moveItem(
            at: fixture.trashed, to: fixture.folder.url.appendingPathComponent("moved.txt")
        )
        _ = try fixture.folder.write(".Trash/item.txt")
        model.recovery.showInTrash(receipt)
        await model.recovery.loadTrash()
        #expect(model.recovery.selectedTrashItemIDs.isEmpty)
        #expect(model.notice?.title == "Item Not Found")
    }

    @Test("A failed Put Back leaves both files intact and permits another attempt")
    func putBackRecovery() async throws {
        let fixture = try TrashFixture()
        _ = try fixture.folder.write("item.txt")
        let model = fixture.model()
        let item = TrashItem(url: fixture.trashed, bytes: 7, canPutBack: true)

        await model.recovery.putBack(item)
        #expect(FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(model.notice != nil)
        #expect(!model.isBusyWithDisk)

        try FileManager.default.removeItem(at: fixture.original)
        model.notice = nil
        await model.recovery.putBack(item)
        #expect(!FileManager.default.fileExists(atPath: fixture.trashed.path))
        #expect(FileManager.default.fileExists(atPath: fixture.original.path))
        #expect(model.notice == nil)
        #expect(!model.isBusyWithDisk)
    }
}

private struct TrashFixture {
    let folder: TemporaryFolder
    let trashed: URL
    let original: URL
    let service: TrashService
    let history: CleanupHistoryService

    init() throws {
        folder = try TemporaryFolder()
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
