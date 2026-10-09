import Foundation
import Observation
import MoppoCore

/// Owns History, Trash results, recovery selection, and operation tasks.
@MainActor
@Observable
final class RecoveryModel {
    enum Event {
        case showTrash
        case emptyingTrash(count: Int, bytes: Int64)
        case emptiedTrash(freedBytes: Int64, skipped: Int)
        case restoringTrashItem(name: String)
        case restored
        case operationFinished
        case failure(title: String, message: String)
    }
    enum Mutation { case emptyTrash, putBack }

    @ObservationIgnored private let operations: OperationCoordinator
    @ObservationIgnored private let trashService: any TrashServicing
    @ObservationIgnored private let historyService: any CleanupHistoryReading
    @ObservationIgnored private var trashTask: Task<Void, Never>?
    @ObservationIgnored private var trashLoadID: UUID?
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var historyLoadID: UUID?
    @ObservationIgnored private var mutationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingTrashReveal: CleanupHistoryItem?
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }
    @ObservationIgnored var refreshAfterMutation: (Mutation) async -> Void = { _ in }

    init(
        operations: OperationCoordinator,
        trashService: any TrashServicing = TrashService(),
        historyService: any CleanupHistoryReading = CleanupHistoryReader()
    ) {
        self.operations = operations
        self.trashService = trashService
        self.historyService = historyService
    }

    var trashSummary: TrashSummary?
    var selectedTrashItemID: TrashItem.ID?
    private(set) var hasLoadedTrash = false
    private(set) var isLoadingTrash = false
    private(set) var cleanupHistory: CleanupHistorySummary?
    private(set) var isLoadingCleanupHistory = false
    private(set) var isMutating = false
    var isBusyWithDisk: Bool { operations.isBusy }

    func loadCleanupHistory() async {
        guard !Task.isCancelled else { return }
        historyTask?.cancel()
        let id = UUID()
        historyLoadID = id
        isLoadingCleanupHistory = true
        let task = Task { [self] in
            defer {
                if historyLoadID == id {
                    isLoadingCleanupHistory = false
                    historyTask = nil
                    historyLoadID = nil
                }
            }
            let summary = await historyService.summary()
            guard historyLoadID == id, !Task.isCancelled else { return }
            cleanupHistory = summary
        }
        historyTask = task
        await task.value
    }

    func showInTrash(_ item: CleanupHistoryItem) {
        guard item.state == .availableInTrash, item.trashedURL != nil else { return }
        trashTask?.cancel()
        trashLoadID = nil
        trashTask = nil
        isLoadingTrash = false
        hasLoadedTrash = false
        pendingTrashReveal = item
        selectedTrashItemID = nil
        trashSummary = nil
        onEvent(.showTrash)
    }

    /// Read every item so sorting, search, and History links use the complete Trash.
    func loadTrash() async {
        guard !Task.isCancelled else { return }
        trashTask?.cancel()
        let id = UUID()
        trashLoadID = id
        isLoadingTrash = true
        let task = Task { [self] in
            defer {
                if trashLoadID == id {
                    isLoadingTrash = false
                    trashTask = nil
                    trashLoadID = nil
                }
            }
            let summary = try? await trashService.summary(limit: Int.max)
            guard trashLoadID == id, !Task.isCancelled else { return }
            trashSummary = summary
            hasLoadedTrash = true
            if let request = pendingTrashReveal, let url = request.trashedURL, let summary {
                pendingTrashReveal = nil
                if let item = summary.items.first(where: {
                    $0.url.standardizedFileURL == url.standardizedFileURL
                }), let identity = request.trashedIdentity, FileIdentity.of(item.url) == identity {
                    selectedTrashItemID = item.id
                } else {
                    onEvent(.failure(title: "Item Not Found", message: "This item is no longer available in the Trash."))
                }
            }
            if let selectedTrashItemID,
               summary?.items.contains(where: { $0.id == selectedTrashItemID }) != true {
                self.selectedTrashItemID = nil
            }
        }
        trashTask = task
        await task.value
    }

    func emptyTrash() async {
        guard !Task.isCancelled, let operation = operations.begin(.emptyTrash) else { return }
        let count = trashSummary?.itemCount ?? 0
        let bytes = trashSummary?.totalBytes ?? 0
        isMutating = true
        onEvent(.emptyingTrash(count: count, bytes: bytes))
        let task = Task { [self] in
            var presentation = OperationPresentationDuration()
            presentation.extend(toShow: .deletion(bytes: bytes))
            do {
                let result = try await trashService.empty(privilegedFallback: true)
                try? await presentation.wait()
                onEvent(.emptiedTrash(freedBytes: result.freedBytes, skipped: result.skipped))
            } catch {
                onEvent(.failure(
                    title: "The Trash Could Not Be Read",
                    message: "Grant Moppo Full Disk Access in System Settings, Privacy & Security, then try again."
                ))
            }
            await refreshListsAfterMutation()
            finish(operation)
            await refreshAfterMutation(.emptyTrash)
        }
        mutationTask = task
        await task.value
    }

    /// Own restoration independently of the requesting view task.
    func putBack(_ item: TrashItem) async {
        guard !Task.isCancelled, let operation = operations.begin(.trashRestoration) else { return }
        isMutating = true
        onEvent(.restoringTrashItem(name: item.name))
        let task = Task { [self] in
            var restored = false
            do {
                try await trashService.putBack(item)
                restored = true
                onEvent(.restored)
            } catch TrashError.destinationOccupied {
                onEvent(.failure(
                    title: "\(item.name) Was Not Put Back",
                    message: "Something is already at the place it came from. "
                        + "Move that aside, or drag this out of the Trash yourself."
                ))
            } catch {
                onEvent(.failure(title: "\(item.name) Was Not Put Back", message: "It is still in the Trash."))
            }
            await refreshListsAfterMutation()
            finish(operation)
            if restored { await refreshAfterMutation(.putBack) }
        }
        mutationTask = task
        await task.value
    }

    private func refreshListsAfterMutation() async {
        await loadTrash()
        await loadCleanupHistory()
        while let trashTask { await trashTask.value }
        while let historyTask { await historyTask.value }
    }

    private func finish(_ operation: OperationCoordinator.Operation) {
        isMutating = false
        mutationTask = nil
        onEvent(.operationFinished)
        operations.finish(operation)
    }
}
