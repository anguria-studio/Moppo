import Foundation
import MoppoCore
import Testing

@Suite("Storage Explorer operation ownership")
@MainActor
struct StorageExplorerModelTests {
    @Test("Cached breadcrumbs and history display results without entering loading")
    func cachedNavigation() async throws {
        let parent = try TemporaryFolder()
        let child = parent.url.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let service = HeldExplorerScanner()
        let operations = OperationCoordinator()
        let model = StorageExplorerModel(operations: operations, service: service)
        let parentSnapshot = explorerSnapshot(parent.url)
        let childSnapshot = explorerSnapshot(child)
        model.selectLocation(parent.url)
        try await waitUntil { await service.scans.count == 1 }
        await service.finishScan(0, parentSnapshot)
        try await waitUntil { !model.isLoading }
        model.navigate(to: child)
        try await waitUntil { await service.scans.count == 2 }
        await service.finishScan(1, childSnapshot)
        try await waitUntil { !model.isLoading }

        model.navigate(to: parent.url)
        #expect(model.snapshot == parentSnapshot)
        #expect(!model.isLoading)
        #expect(!operations.isBusy)
        model.goBack()
        #expect(model.snapshot == childSnapshot)
        #expect(!model.isLoading)
        model.goForward()
        #expect(model.snapshot == parentSnapshot)
        #expect(!model.isLoading)
        #expect(await service.scans.count == 2)

        model.refresh()
        try await waitUntil { await service.scans.count == 3 }
        await service.finishScan(2, explorerSnapshot(parent.url))
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot?.measuredAt != parentSnapshot.measuredAt)
    }

    @Test("Folder sizes update across page changes and partial rows cannot be removed")
    func partialMeasurements() async throws {
        let service = HeldExplorerScanner()
        let app = AppModel(storageExplorerService: service)
        let model = app.storageExplorer
        let folder = URL(fileURLWithPath: "/explorer-fixture")
        model.selectLocation(folder)
        try await waitUntil { await service.scans.count == 1 }
        await service.report(0, bytes: 32)
        try await waitUntil { model.snapshot?.allocatedBytes == 32 }
        app.view = .history
        await service.report(0, bytes: 64)
        try await waitUntil { model.snapshot?.allocatedBytes == 64 }
        #expect(model.progress.allocatedBytes == 64)
        #expect(model.snapshot?.isComplete == false)
        #expect(model.isLoading)
        #expect(app.isBusyWithDisk)
        model.selection = Set(try #require(model.snapshot).items.map(\.id))
        #expect(!model.canRemoveSelection)
        await model.requestRemoval()
        #expect(await service.reviews.isEmpty)
        app.view = .storageExplorer
        #expect(model.snapshot?.items.first?.allocatedBytes == 64)
        let complete = explorerSnapshot(folder)
        await service.finishScan(0, complete)
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot == complete)
        #expect(model.canRemoveSelection)
        await service.report(0, bytes: 999)
        await Task.yield()
        #expect(model.snapshot == complete)
    }

    @Test("Cached results appear while an interrupted child returns without caching partial rows")
    func cachedNavigationDuringMeasurement() async throws {
        let parent = try TemporaryFolder()
        let child = parent.url.appendingPathComponent("Child")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let service = HeldExplorerScanner()
        let operations = OperationCoordinator()
        let model = StorageExplorerModel(operations: operations, service: service)
        let complete = explorerSnapshot(parent.url)
        model.selectLocation(parent.url)
        try await waitUntil { await service.scans.count == 1 }
        await service.finishScan(0, complete)
        try await waitUntil { !model.isLoading }
        model.navigate(to: child)
        try await waitUntil { await service.scans.count == 2 }
        await service.report(1, bytes: 32)
        try await waitUntil { model.snapshot?.isComplete == false }
        model.navigate(to: parent.url)
        #expect(model.snapshot == complete)
        #expect(operations.isBusy)
        await service.report(1, bytes: 99)
        await service.finishScan(1, explorerSnapshot(child))
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot == complete)
        #expect(await service.scans.count == 2)
        #expect(!operations.isBusy)
        model.navigate(to: child)
        #expect(model.snapshot == nil)
        try await waitUntil { await service.scans.count == 3 }
        await service.finishScan(2, explorerSnapshot(child))
        try await waitUntil { !model.isLoading }
    }

    @Test("Cancellation holds the shared guard until measurement returns")
    func scanCancellation() async throws {
        let service = HeldExplorerScanner()
        let app = AppModel(storageExplorerService: service)
        let model = app.storageExplorer
        let folder = URL(fileURLWithPath: "/explorer-fixture/first")
        model.selectLocation(folder)
        try await waitUntil { await service.scans.count == 1 }
        await service.report(0, bytes: 32)
        try await waitUntil { model.snapshot?.allocatedBytes == 32 }
        app.view = .history
        model.cancel()
        #expect(model.isInterrupting)
        #expect(app.isBusyWithDisk)
        await service.report(0, bytes: 99)
        await service.finishScan(0, explorerSnapshot(folder))
        try await waitUntil { !model.isLoading }
        #expect(model.wasCancelled)
        #expect(model.snapshot == nil)
        #expect(model.progress.allocatedBytes == 32)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)
        model.refresh()
        try await waitUntil { await service.scans.count == 2 }
        await service.finishScan(1, explorerSnapshot(folder))
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot?.directory == folder)
        #expect(!model.wasCancelled)
        await service.report(1, bytes: 999)
        await Task.yield()
        #expect(model.progress.allocatedBytes == 0)
    }

    @Test("Replacement measurements wait for cancellation and retain one guard")
    func replacedMeasurement() async throws {
        let service = HeldExplorerScanner()
        let operations = OperationCoordinator()
        let model = StorageExplorerModel(operations: operations, service: service)
        let first = URL(fileURLWithPath: "/explorer-fixture/first")
        let next = URL(fileURLWithPath: "/explorer-fixture/next")
        model.selectLocation(first)
        try await waitUntil { await service.scans.count == 1 }
        let operation = try #require(operations.activeOperation)
        model.selectLocation(next, revealing: next.appendingPathComponent("item"))
        await Task.yield()
        #expect(await service.scans.count == 1)
        #expect(operations.activeOperation == operation)
        await service.report(0, bytes: 80)
        await service.finishScan(0, explorerSnapshot(first))
        try await waitUntil { await service.scans.count == 2 }
        #expect(model.snapshot == nil)
        #expect(model.progress.allocatedBytes == 0)
        #expect(operations.activeOperation == operation)
        await service.finishScan(1, explorerSnapshot(next))
        try await waitUntil { !model.isLoading }
        #expect(model.snapshot?.directory == next)
        #expect(model.selection == [next.appendingPathComponent("item").path])
        #expect(await service.cancelled == [true, false])
        #expect(!operations.isBusy)
    }

    @Test("Cancelling a queued replacement waits for the earlier measurement")
    func cancelledReplacement() async throws {
        let operations = OperationCoordinator()
        let service = HeldExplorerScanner()
        let model = StorageExplorerModel(operations: operations, service: service)
        let first = URL(fileURLWithPath: "/explorer-fixture/first")
        let second = URL(fileURLWithPath: "/explorer-fixture/second")
        model.selectLocation(first)
        try await waitUntil { await service.scans.count == 1 }
        model.selectLocation(second)
        model.cancel()
        await Task.yield()
        #expect(operations.isBusy)
        #expect(model.isInterrupting)
        #expect(await service.scans.count == 1)
        await service.finishScan(0, explorerSnapshot(first))
        try await waitUntil { !model.isLoading }
        #expect(await service.scans.count == 1)
        #expect(!operations.isBusy)
        #expect(model.wasCancelled)
        #expect(model.snapshot == nil)
        #expect(model.currentURL == second)
    }

    @Test("Invalidation rejects a late measurement without releasing its guard early")
    func invalidatedMeasurement() async throws {
        let service = HeldExplorerScanner()
        let operations = OperationCoordinator()
        let model = StorageExplorerModel(operations: operations, service: service)
        let folder = URL(fileURLWithPath: "/explorer-fixture")
        model.selectLocation(folder, revealing: folder.appendingPathComponent("item"))
        try await waitUntil { await service.scans.count == 1 }
        model.invalidateCache()
        model.refreshIfNeeded()
        #expect(model.isLoading)
        #expect(model.isInterrupting)
        #expect(operations.isBusy)
        #expect(await service.scans.count == 1)
        await service.finishScan(0, explorerSnapshot(folder))
        try await waitUntil { !model.isLoading }
        #expect(!model.wasCancelled)
        #expect(model.needsRefresh)
        #expect(model.snapshot == nil)
        #expect(!operations.isBusy)
        model.refreshIfNeeded()
        try await waitUntil { await service.scans.count == 2 }
        await service.finishScan(1, explorerSnapshot(folder))
        try await waitUntil { !model.isLoading }
        #expect(!model.needsRefresh)
        #expect(model.selection.isEmpty)
    }

    @Test("Another operation blocks new Explorer work")
    func sharedGuard() async throws {
        let operations = OperationCoordinator()
        let service = HeldExplorerScanner()
        let model = StorageExplorerModel(operations: operations, service: service)
        let folder = URL(fileURLWithPath: "/explorer-fixture")
        let snapshot = explorerSnapshot(folder)
        model.currentURL = folder
        model.snapshot = snapshot
        model.selection = Set(snapshot.items.map(\.id))
        let operation = try #require(operations.begin(.photoScan))
        model.selectLocation(folder.appendingPathComponent("other"))
        model.navigate(to: folder.appendingPathComponent("other"))
        model.refresh()
        await model.requestRemoval()
        #expect(model.currentURL == folder)
        #expect(model.snapshot == snapshot)
        #expect(!model.canGoBack)
        #expect(!model.isRemoving)
        #expect(!model.isLoading)
        #expect(await service.scans.isEmpty)
        #expect(await service.reviews.isEmpty)
        operations.finish(operation)
    }

    @Test("Removal captures its selection and preferences and survives caller cancellation")
    func removalLifetime() async throws {
        let operations = OperationCoordinator()
        let service = HeldExplorerScanner()
        let remover = HeldExplorerRemover()
        var preferences = StorageExplorerModel.Preferences(excludedPaths: ["original"], excludedPatterns: ["*.keep"], keepReceipt: false)
        let model = StorageExplorerModel(
            operations: operations, service: service, removalService: remover, preferences: { preferences }
        )
        let folder = URL(fileURLWithPath: "/explorer-fixture")
        let snapshot = explorerSnapshot(folder)
        model.currentURL = folder
        model.snapshot = snapshot
        model.selection = Set(snapshot.items.map(\.id))
        var outcome: CleanupOutcome?
        var refreshes = 0
        model.onEvent = { if case .removed(let result) = $0 { outcome = result } }
        model.refreshAfterRemoval = {
            #expect(!operations.isBusy)
            #expect(!model.isRemoving)
            refreshes += 1
        }
        let caller = Task { await model.requestRemoval() }
        try await waitUntil { await service.reviews.count == 1 }
        caller.cancel()
        model.selectLocation(folder.appendingPathComponent("other"))
        model.selection = []
        preferences.keepReceipt = true
        preferences.excludedPaths = []
        preferences.excludedPatterns = []
        #expect(model.currentURL == folder)
        #expect(operations.isBusy)
        await service.finishReview(0, readyReview(snapshot))
        try await waitUntil { await remover.requests.count == 1 }
        await model.requestRemoval()
        let request = try #require(await remover.requests.first)
        #expect(request.items == snapshot.items)
        #expect(request.directory == folder)
        #expect(!request.keepReceipt)
        #expect(await service.reviews.first?.excludedPaths == ["original"])
        #expect(await service.reviews.first?.excludedPatterns == ["*.keep"])
        await remover.finish(0, CleanupOutcome(removedCount: 1, failed: ["survivor"], trashedCount: 1))
        await caller.value
        #expect(await service.reviewCancelled == [false])
        #expect(await remover.cancelled == [false])
        #expect(outcome?.removedCount == 1)
        #expect(outcome?.failed == ["survivor"])
        #expect(model.snapshot == nil)
        #expect(model.selection.isEmpty)
        #expect(model.needsRefresh)
        #expect(refreshes == 1)
    }

    enum ReviewFailure: CaseIterable { case changed, protected, empty, unreadable }

    @Test("A failed review reports its reason without removing files", arguments: ReviewFailure.allCases)
    func reviewFailure(_ failure: ReviewFailure) async throws {
        let service = HeldExplorerScanner()
        let remover = HeldExplorerRemover()
        let app = AppModel(storageExplorerService: service, storageExplorerRemover: remover)
        let model = app.storageExplorer
        let snapshot = explorerSnapshot(URL(fileURLWithPath: "/explorer-fixture"))
        model.currentURL = snapshot.directory
        model.snapshot = snapshot
        model.selection = Set(snapshot.items.map(\.id))
        let caller = Task { await model.requestRemoval() }
        try await waitUntil { await service.reviews.count == 1 }
        #expect(app.activity == .reviewingStorageItems(itemCount: 1))
        let title: String
        switch failure {
        case .changed:
            title = "The Selection Changed"
            await service.finishReview(0, StorageExplorerSelectionReview(snapshot: snapshot, items: [], changedPaths: ["item"], protectedPaths: []))
        case .protected:
            title = "Some Items Are Protected"
            await service.finishReview(0, StorageExplorerSelectionReview(snapshot: snapshot, items: [], changedPaths: [], protectedPaths: ["item"]))
        case .empty:
            title = "Nothing Left to Remove"
            await service.finishReview(0, StorageExplorerSelectionReview(snapshot: snapshot, items: [], changedPaths: [], protectedPaths: []))
        case .unreadable:
            title = "The Selection Could Not Be Checked"
            await service.failReview(0)
        }
        await caller.value
        #expect(app.notice?.title == title)
        #expect(app.activity == nil)
        #expect(!app.isBusyWithDisk)
        #expect(await remover.requests.isEmpty)
    }

    @Test("Invalidated reviews cannot restore rows or begin removal")
    func invalidatedReview() async throws {
        let service = HeldExplorerScanner()
        let remover = HeldExplorerRemover()
        let operations = OperationCoordinator()
        let model = StorageExplorerModel(operations: operations, service: service, removalService: remover)
        let snapshot = explorerSnapshot(URL(fileURLWithPath: "/explorer-fixture"))
        model.currentURL = snapshot.directory
        model.snapshot = snapshot
        model.selection = Set(snapshot.items.map(\.id))
        let caller = Task { await model.requestRemoval() }
        try await waitUntil { await service.reviews.count == 1 }
        model.invalidateCache()
        await service.finishReview(0, readyReview(snapshot))
        await caller.value
        #expect(await remover.requests.isEmpty)
        #expect(model.snapshot == nil)
        #expect(model.selection.isEmpty)
        #expect(!operations.isBusy)
    }

    @Test("A failed removal releases its guard and refreshes affected results")
    func removalFailure() async throws {
        let service = HeldExplorerScanner()
        let remover = HeldExplorerRemover()
        let app = AppModel(
            launchAccess: .limited, hasFullDiskAccess: { false },
            storageExplorerService: service, storageExplorerRemover: remover
        )
        let model = app.storageExplorer
        let snapshot = explorerSnapshot(URL(fileURLWithPath: "/explorer-fixture"))
        model.currentURL = snapshot.directory
        model.snapshot = snapshot
        model.selection = Set(snapshot.items.map(\.id))
        app.cleanup.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        let caller = Task { await model.requestRemoval() }
        try await waitUntil { await service.reviews.count == 1 }
        await service.finishReview(0, readyReview(snapshot))
        try await waitUntil { await remover.requests.count == 1 }
        await remover.fail(0)
        await caller.value
        #expect(app.notice?.title == "The Items Could Not Be Moved")
        #expect(app.activity == nil)
        #expect(!app.isBusyWithDisk)
        #expect(app.cleanup.scanResults == nil)
        #expect(model.snapshot == nil)
        #expect(model.needsRefresh)
    }

    @Test("Explorer removal retains a receipt and Put Back refreshes History")
    func removalAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ExplorerRecovery-\(UUID())")
        let folder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("disposable.txt")
        try Data("Disposable fixture".utf8).write(to: file)
        let log = MoppoCore.RemovalLog(directory: root.appendingPathComponent("receipts"))
        let app = AppModel(
            launchAccess: .limited, hasFullDiskAccess: { false },
            trashService: TrashService(log: log), cleanupHistoryService: CleanupHistoryService(log: log),
            storageExplorerRemover: StorageExplorerRemovalService(cleanup: CleanupService(log: log))
        )
        let model = app.storageExplorer
        model.selectLocation(folder)
        try await waitUntil { !model.isLoading }
        let item = try #require(model.snapshot?.items.first { $0.url.lastPathComponent == file.lastPathComponent })
        model.selection = [item.id]
        await model.requestRemoval()
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(app.removalCompletion?.title == "Moved to Trash")
        #expect(model.snapshot == nil)
        #expect(model.selection.isEmpty)
        #expect(!app.isBusyWithDisk)
        #expect(app.recovery.cleanupHistory?.items.first?.state == .availableInTrash)
        let receipt = try #require(log.recentEntries(limit: 10).first { $0.disposition == .trashed })
        let trashed = URL(fileURLWithPath: try #require(receipt.trashedPath))
        defer { try? FileManager.default.removeItem(at: trashed) }
        await app.recovery.putBack(TrashItem(url: trashed, bytes: receipt.bytes, canPutBack: true))
        #expect(FileManager.default.fileExists(atPath: file.path))
        #expect(app.recovery.cleanupHistory?.items.first?.state == .restored)
        #expect(model.needsRefresh)
    }
}

@Suite("Storage Explorer row updates")
struct StorageExplorerRowOrderTests {
    private let sizeOrder = [KeyPathComparator(\StorageExplorerItem.allocatedBytes, order: .reverse)]

    @Test("Live sizes keep their rows until completion or a column sort")
    func liveRowOrder() {
        let directory = URL(fileURLWithPath: "/explorer-fixture")
        var snapshot = StorageExplorerSnapshot(
            directory: directory,
            items: [
                StorageExplorerItem(url: directory.appendingPathComponent("A"), kind: .folder, allocatedBytes: 10),
                StorageExplorerItem(url: directory.appendingPathComponent("B"), kind: .folder, allocatedBytes: 0)
            ],
            allocatedBytes: 10, fileCount: 0, unreadableCount: 0, isComplete: false
        )
        var rows = StorageExplorerRowOrder()
        var didReorder = rows.update(snapshot, sortOrder: sizeOrder)
        #expect(!didReorder)
        snapshot.items[1].allocatedBytes = 20
        didReorder = rows.update(snapshot, sortOrder: sizeOrder)
        #expect(!didReorder)
        #expect(rows.items(in: snapshot, sortOrder: sizeOrder).map(\.name) == ["A", "B"])
        #expect(rows.items(in: snapshot, sortOrder: sizeOrder).map(\.allocatedBytes) == [10, 20])

        didReorder = rows.update(snapshot, sortOrder: sizeOrder, forceSort: true)
        #expect(didReorder)
        #expect(rows.items(in: snapshot, sortOrder: sizeOrder).map(\.name) == ["B", "A"])
        snapshot.items[0].allocatedBytes = 30
        didReorder = rows.update(snapshot, sortOrder: sizeOrder)
        #expect(!didReorder)
        #expect(rows.items(in: snapshot, sortOrder: sizeOrder).map(\.allocatedBytes) == [20, 30])
        snapshot.isComplete = true
        didReorder = rows.update(snapshot, sortOrder: sizeOrder)
        #expect(didReorder)
        #expect(rows.items(in: snapshot, sortOrder: sizeOrder).map(\.name) == ["A", "B"])
        didReorder = rows.update(snapshot, sortOrder: sizeOrder)
        #expect(!didReorder)
    }

    @Test("Completed folders appear sorted without a navigation animation")
    func completedNavigation() {
        let directory = URL(fileURLWithPath: "/explorer-fixture")
        var snapshot = explorerSnapshot(directory)
        snapshot.items.append(StorageExplorerItem(
            url: directory.appendingPathComponent("larger"), kind: .file, allocatedBytes: 128
        ))
        var rows = StorageExplorerRowOrder()
        var didReorder = rows.update(snapshot, sortOrder: sizeOrder)
        #expect(!didReorder)
        #expect(rows.items(in: snapshot, sortOrder: sizeOrder).map(\.allocatedBytes) == [128, 64])
        didReorder = rows.update(nil, sortOrder: sizeOrder)
        #expect(!didReorder)
        #expect(rows.items(in: nil, sortOrder: sizeOrder).isEmpty)
        didReorder = rows.update(snapshot, sortOrder: sizeOrder)
        #expect(!didReorder)
        let child = explorerSnapshot(directory.appendingPathComponent("child"))
        didReorder = rows.update(child, sortOrder: sizeOrder)
        #expect(!didReorder)
        #expect(rows.items(in: child, sortOrder: sizeOrder) == child.items)
    }
}

private func explorerSnapshot(_ directory: URL) -> StorageExplorerSnapshot {
    let item = StorageExplorerItem(url: directory.appendingPathComponent("item"), kind: .file, allocatedBytes: 64, identity: "fixture")
    return StorageExplorerSnapshot(directory: directory, items: [item], allocatedBytes: 64, fileCount: 1, unreadableCount: 0)
}

private func readyReview(_ snapshot: StorageExplorerSnapshot) -> StorageExplorerSelectionReview {
    StorageExplorerSelectionReview(snapshot: snapshot, items: snapshot.items, changedPaths: [], protectedPaths: [])
}

private actor HeldExplorerScanner: StorageExplorerScanning {
    struct Request: Sendable {
        let directory: URL
        let excludedPaths: [String]
        let excludedPatterns: [String]
    }
    private(set) var scans: [Request] = []
    private(set) var reviews: [Request] = []
    private(set) var cancelled: [Bool] = []
    private(set) var reviewCancelled: [Bool] = []
    private var scansPending: [Int: CheckedContinuation<StorageExplorerSnapshot, Error>] = [:]
    private var reviewsPending: [Int: CheckedContinuation<StorageExplorerSelectionReview, Error>] = [:]
    private var progress: [Int: @Sendable (StorageExplorerSnapshot) -> Void] = [:]

    func scan(
        directory: URL, excludedPaths: [String], excludedPatterns: [String],
        progress: (@Sendable (StorageExplorerSnapshot) -> Void)?
    ) async throws -> StorageExplorerSnapshot {
        let index = scans.count
        scans.append(Request(directory: directory, excludedPaths: excludedPaths, excludedPatterns: excludedPatterns))
        self.progress[index] = progress
        let snapshot = try await withCheckedThrowingContinuation { scansPending[index] = $0 }
        cancelled.append(Task.isCancelled)
        return snapshot
    }
    func reviewSelection(
        _ items: [StorageExplorerItem], in directory: URL, excludedPaths: [String], excludedPatterns: [String]
    ) async throws -> StorageExplorerSelectionReview {
        let index = reviews.count
        reviews.append(Request(directory: directory, excludedPaths: excludedPaths, excludedPatterns: excludedPatterns))
        let review = try await withCheckedThrowingContinuation { reviewsPending[index] = $0 }
        reviewCancelled.append(Task.isCancelled)
        return review
    }
    func finishScan(_ index: Int, _ snapshot: StorageExplorerSnapshot) { scansPending.removeValue(forKey: index)?.resume(returning: snapshot) }
    func finishReview(_ index: Int, _ review: StorageExplorerSelectionReview) { reviewsPending.removeValue(forKey: index)?.resume(returning: review) }
    func failReview(_ index: Int) { reviewsPending.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func report(_ index: Int, bytes: Int64) {
        var snapshot = explorerSnapshot(scans[index].directory)
        snapshot.allocatedBytes = bytes
        snapshot.items[0].allocatedBytes = bytes
        snapshot.isComplete = false
        progress[index]?(snapshot)
    }
}

private actor HeldExplorerRemover: StorageExplorerRemoving {
    struct Request: Sendable {
        let items: [StorageExplorerItem]
        let directory: URL
        let keepReceipt: Bool
    }
    private(set) var requests: [Request] = []
    private(set) var cancelled: [Bool] = []
    private var pending: [Int: CheckedContinuation<CleanupOutcome, Error>] = [:]
    func remove(_ items: [StorageExplorerItem], from directory: URL, keepReceipt: Bool) async throws -> CleanupOutcome {
        let index = requests.count
        requests.append(Request(items: items, directory: directory, keepReceipt: keepReceipt))
        let outcome = try await withCheckedThrowingContinuation { pending[index] = $0 }
        cancelled.append(Task.isCancelled)
        return outcome
    }
    func finish(_ index: Int, _ outcome: CleanupOutcome) { pending.removeValue(forKey: index)?.resume(returning: outcome) }
    func fail(_ index: Int) { pending.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileWriteNoPermission)) }
}
