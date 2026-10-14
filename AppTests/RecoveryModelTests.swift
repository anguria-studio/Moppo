import Foundation
import Testing
@testable import MoppoCore

@Suite("Recovery feature ownership")
@MainActor
struct RecoveryModelTests {
    @Test("A replaced Trash read cannot restore old rows or selection")
    func replacedTrash() async throws {
        let trash = HeldRecoveryTrash(holdReads: true)
        let model = RecoveryModel(operations: OperationCoordinator(), trashService: trash)
        let old = recoveryItem("Old")
        let current = recoveryItem("Current")
        model.selectedTrashItemIDs = [old.id]
        let first = Task { await model.loadTrash() }
        try await waitUntil { await trash.readLimits.count == 1 }
        let second = Task { await model.loadTrash() }
        try await waitUntil { await trash.readLimits.count == 2 }
        await trash.finishRead(1, TrashSummary(totalBytes: 64, itemCount: 1, items: [current]))
        await second.value
        await trash.finishRead(0, TrashSummary(totalBytes: 128, itemCount: 1, items: [old]))
        await first.value
        #expect(model.trashSummary?.items == [current])
        #expect(model.selectedTrashItemIDs.isEmpty)
        #expect(model.hasLoadedTrash)
        #expect(!model.isLoadingTrash)
        #expect(await trash.readLimits == [Int.max, Int.max])
    }

    @Test("An earlier History read cannot finish or replace a later refresh")
    func replacedHistory() async throws {
        let history = HeldRecoveryHistory()
        let model = RecoveryModel(operations: OperationCoordinator(), historyService: history)
        let first = Task { await model.loadCleanupHistory() }
        try await waitUntil { await history.readCount == 1 }
        let second = Task { await model.loadCleanupHistory() }
        try await waitUntil { await history.readCount == 2 }
        await history.finish(0, CleanupHistorySummary(removedCount: 12))
        await first.value
        #expect(model.isLoadingCleanupHistory)
        #expect(model.cleanupHistory == nil)
        await history.finish(1, CleanupHistorySummary(removedCount: 15))
        await second.value
        #expect(model.cleanupHistory?.removedCount == 15)
        #expect(!model.isLoadingCleanupHistory)
    }

    @Test("Put Back owns its task and refreshes other features after restoration")
    func restorationLifetime() async throws {
        let trash = HeldRecoveryTrash()
        let history = HeldRecoveryHistory(holdReads: false)
        let app = AppModel(launchAccess: .limited, hasFullDiskAccess: { false }, trashService: trash, historyReader: history)
        let item = recoveryItem("Restored")
        app.cleanup.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        app.cleanup.scannerSelection = [item.id]
        var refreshes: [RecoveryModel.Mutation] = []
        app.recovery.refreshAfterMutation = { mutation in
            #expect(!app.operations.isBusy)
            refreshes.append(mutation)
        }
        let caller = Task { await app.recovery.putBack(item) }
        try await waitUntil { await trash.restorations.count == 1 }
        app.view = .history
        caller.cancel()
        #expect(app.activity == .restoringTrashItem(name: item.name))
        #expect(app.storageExplorer.isMeasurementBlocked)
        #expect(app.isBusyWithDisk)
        await app.recovery.putBack(item)
        #expect(await trash.restorations.count == 1)
        await trash.finishRestoration()
        await caller.value
        #expect(await trash.cancelled == [false])
        #expect(app.cleanup.scanResults == nil)
        #expect(app.cleanup.scannerSelection.isEmpty)
        #expect(app.recovery.trashSummary?.itemCount == 0)
        #expect(app.recovery.cleanupHistory != nil)
        #expect(app.activity == nil)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)
        #expect(refreshes.count == 1)
        #expect(refreshes.first == .putBack)
    }

    @Test("Batch Put Back restores only requested items and continues after a failure")
    func batchRestoration() async throws {
        let trash = HeldRecoveryTrash(holdReads: true)
        let history = HeldRecoveryHistory(holdReads: false)
        let model = RecoveryModel(
            operations: OperationCoordinator(), trashService: trash, historyService: history
        )
        let first = recoveryItem("First")
        let occupied = recoveryItem("Occupied")
        let last = recoveryItem("Last")
        let unselected = recoveryItem("Unselected")
        let unknown = TrashItem(url: URL(filePath: "/moppo-fixture/.Trash/Unknown"), bytes: 64)
        let requested = [first, occupied, last, unknown]
        model.selectedTrashItemIDs = Set(requested.map(\.id))
        var failures: [String] = []
        var refreshCount = 0
        model.onEvent = { event in
            if case .failure(let title, _, _) = event { failures.append(title) }
        }
        model.refreshAfterMutation = { _ in refreshCount += 1 }

        let caller = Task { await model.putBack(requested) }
        try await waitUntil { await trash.restorations.count == 1 }
        caller.cancel()
        await model.putBack(unselected)
        #expect(await trash.restorations == [first])
        await trash.finishRestoration()
        try await waitUntil { await trash.restorations.count == 2 }
        await trash.failRestoration(.destinationOccupied(occupied.id))
        try await waitUntil { await trash.restorations.count == 3 }
        #expect(model.isBusyWithDisk)
        #expect(await trash.readLimits.isEmpty)
        await trash.finishRestoration()
        try await waitUntil { await trash.readLimits.count == 1 }
        await trash.finishRead(0, TrashSummary(
            totalBytes: 192, itemCount: 3, items: [occupied, unselected, unknown]
        ))
        await caller.value

        #expect(await trash.restorations == [first, occupied, last])
        #expect(await trash.cancelled == [false, false])
        #expect(await trash.readLimits == [Int.max])
        #expect(await history.readCount == 1)
        #expect(model.selectedTrashItemIDs == [occupied.id, unknown.id])
        #expect(failures == ["Occupied Was Not Put Back"])
        #expect(refreshCount == 1)
        #expect(!model.isBusyWithDisk)
    }

    @Test("Empty Trash keeps its guard through refreshed reads and reports survivors")
    func emptyLifetime() async throws {
        let trash = HeldRecoveryTrash(holdReads: true)
        let history = HeldRecoveryHistory()
        let app = AppModel(launchAccess: .limited, hasFullDiskAccess: { false }, trashService: trash, historyReader: history)
        app.recovery.trashSummary = TrashSummary(totalBytes: 128, itemCount: 2)
        app.activeSheet = .emptyTrash
        let caller = Task { await app.recovery.emptyTrash() }
        try await waitUntil { await trash.emptyRequests == 1 }
        caller.cancel()
        #expect(app.activeSheet == nil)
        #expect(app.activity == .emptyingTrash(itemCount: 2, totalBytes: 128))
        await app.recovery.emptyTrash()
        #expect(await trash.emptyRequests == 1)
        await trash.finishEmpty(freed: 64, skipped: 1)
        try await waitUntil { await trash.readLimits.count == 1 }
        #expect(app.isBusyWithDisk)
        await trash.finishRead(0, TrashSummary(totalBytes: 64, itemCount: 1, items: [recoveryItem("Survivor")]))
        try await waitUntil { await history.readCount == 1 }
        #expect(app.isBusyWithDisk)
        await history.finish(0, CleanupHistorySummary(removedCount: 1, failedCount: 1))
        await caller.value
        #expect(app.removalCompletion?.title == "Some items remain in Trash")
        #expect(app.removalCompletion?.isSuccess == false)
        #expect(app.removalCompletion?.finderURLs == [recoveryItem("Survivor-0").url])
        #expect(app.recovery.trashSummary?.itemCount == 1)
        #expect(app.recovery.cleanupHistory?.failedCount == 1)
        #expect(await trash.cancelled == [false])
        #expect(!app.isBusyWithDisk)
    }

    @Test("Another operation blocks restoration and Trash emptying")
    func sharedGuard() async throws {
        let operations = OperationCoordinator()
        let trash = HeldRecoveryTrash()
        let model = RecoveryModel(operations: operations, trashService: trash)
        let current = try #require(operations.begin(.appUninstall))
        let unknown = TrashItem(url: URL(filePath: "/moppo-fixture/.Trash/Unknown"), bytes: 64)
        model.requestPutBack([unknown])
        #expect(operations.blockedAction == nil)
        model.requestPutBack([recoveryItem("Blocked button")])
        let feedback = try #require(operations.blockedAction)
        await model.putBack(recoveryItem("Blocked"))
        #expect(operations.blockedAction == feedback)
        #expect(operations.blockedAction?.operation == current)
        #expect(operations.blockedAction?.message == "Moppo is uninstalling applications. Wait for it to finish.")
        await model.emptyTrash()
        #expect(await trash.restorations.isEmpty)
        #expect(await trash.emptyRequests == 0)
        #expect(!model.isMutating)
        operations.finish(current)
        #expect(operations.blockedAction == nil)
        await Task.yield()
        #expect(await trash.restorations.isEmpty)
    }

    @Test("Failed restoration preserves stale feature results and permits retry")
    func restorationFailure() async throws {
        let trash = HeldRecoveryTrash()
        let app = AppModel(
            launchAccess: .limited, hasFullDiskAccess: { false },
            trashService: trash, historyReader: HeldRecoveryHistory(holdReads: false)
        )
        app.cleanup.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        let item = recoveryItem("Occupied")
        let first = Task { await app.recovery.putBack(item) }
        try await waitUntil { await trash.restorations.count == 1 }
        await trash.failRestoration(.destinationOccupied(item.id))
        await first.value
        #expect(app.notice?.title == "Occupied Was Not Put Back")
        #expect(app.cleanup.scanResults != nil)
        #expect(!app.isBusyWithDisk)
        app.notice = nil
        let retry = Task { await app.recovery.putBack(item) }
        try await waitUntil { await trash.restorations.count == 2 }
        await trash.finishRestoration()
        await retry.value
        #expect(app.cleanup.scanResults == nil)
        #expect(app.notice == nil)
    }

    @Test("A read started before restoration cannot restore removed Trash rows")
    func restorationDuringRead() async throws {
        let trash = HeldRecoveryTrash(holdReads: true)
        let model = RecoveryModel(
            operations: OperationCoordinator(), trashService: trash,
            historyService: HeldRecoveryHistory(holdReads: false)
        )
        let item = recoveryItem("Restored")
        model.selectedTrashItemIDs = [item.id]
        let initial = Task { await model.loadTrash() }
        try await waitUntil { await trash.readLimits.count == 1 }
        let restore = Task { await model.putBack(item) }
        try await waitUntil { await trash.restorations.count == 1 }
        await trash.finishRestoration()
        try await waitUntil { await trash.readLimits.count == 2 }
        await trash.finishRead(1, TrashSummary())
        await restore.value
        await trash.finishRead(0, TrashSummary(totalBytes: 64, itemCount: 1, items: [item]))
        await initial.value
        #expect(model.trashSummary?.items.isEmpty == true)
        #expect(model.selectedTrashItemIDs.isEmpty)
        #expect(!model.isBusyWithDisk)
    }

    @Test("An unreadable Trash finishes loading and permits another read")
    func readFailure() async throws {
        let trash = HeldRecoveryTrash(holdReads: true)
        let model = RecoveryModel(operations: OperationCoordinator(), trashService: trash)
        let first = Task { await model.loadTrash() }
        try await waitUntil { await trash.readLimits.count == 1 }
        await trash.failRead(0)
        await first.value
        #expect(model.hasLoadedTrash)
        #expect(!model.isLoadingTrash)
        #expect(model.trashSummary == nil)
        let retry = Task { await model.loadTrash() }
        try await waitUntil { await trash.readLimits.count == 2 }
        await trash.finishRead(1, TrashSummary())
        await retry.value
        #expect(model.trashSummary?.itemCount == 0)
    }
}

private func recoveryItem(_ name: String) -> TrashItem {
    TrashItem(url: URL(fileURLWithPath: "/moppo-fixture/.Trash/\(name)"), bytes: 64, canPutBack: true)
}

private actor HeldRecoveryTrash: TrashServicing {
    let holdReads: Bool
    private(set) var readLimits: [Int] = []
    private(set) var restorations: [TrashItem] = []
    private(set) var emptyRequests = 0
    private(set) var cancelled: [Bool] = []
    private var reads: [Int: CheckedContinuation<TrashSummary, Error>] = [:]
    private var restore: CheckedContinuation<Void, Error>?
    private var empty: CheckedContinuation<EmptyTrashOutcome, Error>?
    init(holdReads: Bool = false) { self.holdReads = holdReads }
    func summary(limit: Int) async throws -> TrashSummary {
        let index = readLimits.count
        readLimits.append(limit)
        if holdReads { return try await withCheckedThrowingContinuation { reads[index] = $0 } }
        return TrashSummary()
    }
    func empty() async throws -> EmptyTrashOutcome {
        emptyRequests += 1
        let result = try await withCheckedThrowingContinuation { empty = $0 }
        cancelled.append(Task.isCancelled)
        return result
    }
    func putBack(_ item: TrashItem) async throws {
        restorations.append(item)
        try await withCheckedThrowingContinuation { restore = $0 }
        cancelled.append(Task.isCancelled)
    }
    func finishRead(_ index: Int, _ summary: TrashSummary) { reads.removeValue(forKey: index)?.resume(returning: summary) }
    func failRead(_ index: Int) { reads.removeValue(forKey: index)?.resume(throwing: TrashError.unreadable("fixture")) }
    func finishRestoration() { restore?.resume(); restore = nil }
    func failRestoration(_ error: TrashError) { restore?.resume(throwing: error); restore = nil }
    func finishEmpty(freed: Int64, skipped: Int) { empty?.resume(returning: EmptyTrashOutcome(freedBytes: freed, skippedURLs: (0..<skipped).map { recoveryItem("Survivor-\($0)").url })); empty = nil }
}

private actor HeldRecoveryHistory: CleanupHistoryReading {
    let holdReads: Bool
    private(set) var readCount = 0
    private var reads: [Int: CheckedContinuation<CleanupHistorySummary, Never>] = [:]
    init(holdReads: Bool = true) { self.holdReads = holdReads }
    func summary() async -> CleanupHistorySummary {
        let index = readCount
        readCount += 1
        if holdReads { return await withCheckedContinuation { reads[index] = $0 } }
        return CleanupHistorySummary()
    }
    func finish(_ index: Int, _ summary: CleanupHistorySummary) { reads.removeValue(forKey: index)?.resume(returning: summary) }
}
