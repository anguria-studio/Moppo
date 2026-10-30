import Foundation
@testable import MoppoCore
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

    @Test("Cleanup Explorer navigation preserves selections and excludes applications",
          arguments: ["Project", "cache.log", "Sample.app", "Downloaded.app"])
    func cleanupExplorerNavigation(name: String) async throws {
        let folder = try TemporaryFolder()
        let url = folder.url.appendingPathComponent(name)
        if name == "cache.log" {
            try Data("Fixture".utf8).write(to: url)
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data("Fixture".utf8).write(to: url.appendingPathComponent("contents.txt"))
        }
        let kind: FileEntry.Kind = switch name {
        case "Sample.app": .appBundle
        case "Downloaded.app": .downloadedApp
        default: .cache
        }
        let entry = FileEntry(url: url, kind: kind, allocatedBytes: 100)
        let model = AppModel()
        let results = ScanResults(categories: [.init(categoryID: .systemCaches, totalBytes: 100, entries: [entry])],
            startedAt: .now, finishedAt: .now)
        model.cleanup.scanResults = results
        model.cleanup.scanFilter = .all
        model.cleanup.scannerSelection = [entry.id]
        model.view = .scanner

        model.showInStorageExplorer(entry)
        if name.hasSuffix(".app") {
            #expect(model.view == .scanner)
            #expect(model.storageExplorer.currentURL == nil)
            #expect(!model.operations.isBusy)
            #expect(model.cleanup.scannerSelection == [entry.id])
            return
        }
        #expect(model.view == .storageExplorer)
        try await waitUntil { !model.storageExplorer.isLoading }
        let snapshot = try #require(model.storageExplorer.snapshot)
        #expect(snapshot.directory.standardizedFileURL.path
            == (name == "Project" ? url : folder.url).standardizedFileURL.path)
        #expect(model.storageExplorer.selectedItems.map { $0.url.standardizedFileURL.path }
            == (name == "Project" ? [] : [url.standardizedFileURL.path]))
        #expect(model.cleanup.pendingCleanUp == nil)
        model.view = .scanner
        #expect(model.cleanup.scannerSelection == [entry.id])
        #expect(model.cleanup.scanResults?.startedAt == results.startedAt)
        #expect(model.cleanup.scanFilter == .all)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("Cleanup Explorer navigation respects active operations and file URLs")
    func cleanupExplorerWhileBusy() throws {
        let model = AppModel()
        model.view = .scanner
        let entry = FileEntry(url: URL(fileURLWithPath: "/unused-fixture"), kind: .folder, allocatedBytes: 100)
        let operation = try #require(model.operations.begin(.cleanupRemoval))
        model.showInStorageExplorer(entry)
        #expect(model.operations.blockedAction?.operation == operation)
        #expect(model.view == .scanner)
        #expect(model.storageExplorer.currentURL == nil)
        model.operations.finish(operation)

        var docker = entry
        docker.url = try #require(URL(string: "docker://fixture/image"))
        model.showInStorageExplorer(docker)
        #expect(model.view == .scanner)
        #expect(model.storageExplorer.currentURL == nil)
        #expect(!model.operations.isBusy)
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

    @Test("The Cleanup banner names empty, permanent, and Trash results with correct counts")
    func cleanupBannerText() {
        let cases: [(CleanupOutcome, String, String?)] = [
            (CleanupOutcome(failed: ["runtime"]), "No items removed", "1 item could not be removed."),
            (CleanupOutcome(removedCount: 1, deletedCount: 1), "1 item removed", nil),
            (CleanupOutcome(removedBytes: 2_048, removedCount: 2, failed: ["a", "b"], trashedCount: 2),
             "\(ByteFormatting.string(2_048)) moved to Trash", "2 items could not be removed."),
        ]
        for (outcome, title, note) in cases {
            #expect(ScannerView.completionTitle(outcome) == title)
            #expect(ScannerView.failureNote(outcome) == note)
        }
    }

    enum ToolCommandResultCase: CaseIterable { case verified, failed, retainedStorage, unverifiedRecovery }

    @Test("Cleanup shows a tool command alert only when the result needs attention",
          arguments: ToolCommandResultCase.allCases)
    func toolCommandNotice(resultCase: ToolCommandResultCase) {
        let model = AppModel(launchAccess: .limited, hasFullDiskAccess: { false })
        model.view = .scanner
        var result = ToolCommandRemovalResult(targetID: "runtime", name: "iOS 18.1 Simulator Runtime (22B81)",
            command: "xcrun simctl runtime delete")
        result.status = .completed
        result.beforeBytes = 100
        result.afterBytes = 0
        result.freedBytes = 100
        switch resultCase {
        case .verified: break
        case .failed:
            result.status = .failed
            result.failureReason = "The command reached its time limit."
        case .retainedStorage:
            result.afterBytes = 100
            result.remainingStorageReason = "macOS still stores the downloaded image."
        case .unverifiedRecovery: result.freedBytes = nil
        }
        let completed = result.status == .completed
        model.cleanup.onEvent(.removed(CleanupOutcome(removedCount: completed ? 1 : 0,
            failed: completed ? [] : [result.targetID], deletedCount: completed ? 1 : 0, toolCommandResults: [result])))

        #expect((model.notice == nil) == (resultCase == .verified))
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
