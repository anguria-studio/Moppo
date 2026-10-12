import AppKit
import Observation
import MoppoCore

protocol FileDuplicatesScanning: Sendable {
    func scan(
        roots: [URL],
        options: FileDuplicateService.Options,
        excludedPaths: [String],
        excludedPatterns: [String],
        onProgress: (@Sendable (FileDuplicateService.Progress) -> Void)?
    ) async throws -> FileDuplicateResults
}

protocol FileDuplicatesRemoving: Sendable {
    func remove(
        selectedIDs: Set<DuplicateFile.ID>,
        from groups: [FileDuplicateGroup],
        privilegedFallback: Bool,
        keepReceipt: Bool
    ) async throws -> FileDuplicateRemovalOutcome
}

extension FileDuplicateService: FileDuplicatesScanning {}
extension FileDuplicateRemovalService: FileDuplicatesRemoving {}

/// Owns file scans, filters, keeper selection, and removal tasks.
@MainActor
@Observable
final class FileDuplicatesModel {
    typealias Preferences = RemovalPreferences

    enum Event {
        case scanStarted
        case removalStarted(count: Int, bytes: Int64)
        case removed(CleanupOutcome, extraFailures: Int)
        case operationFinished
        case failure(title: String, message: String)
    }

    @ObservationIgnored private let operations: OperationCoordinator
    @ObservationIgnored private let service: any FileDuplicatesScanning
    @ObservationIgnored private let removalService: any FileDuplicatesRemoving
    @ObservationIgnored private let preferences: () -> Preferences
    @ObservationIgnored private var folderTask: Task<Void, Never>?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID: UUID?
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }
    @ObservationIgnored var refreshAfterRemoval: () async -> Void = {}
    @ObservationIgnored var confirmRemoval: (RemovalConfirmation) async -> Bool = { _ in false }

    init(
        operations: OperationCoordinator,
        service: any FileDuplicatesScanning = FileDuplicateService(),
        removalService: any FileDuplicatesRemoving = FileDuplicateRemovalService(),
        preferences: @escaping () -> Preferences = { Preferences() }
    ) {
        self.operations = operations
        self.service = service
        self.removalService = removalService
        self.preferences = preferences
    }

    private(set) var results: FileDuplicateResults?
    private(set) var progress: FileDuplicateService.Progress?
    private(set) var isScanning = false
    private(set) var isInterrupting = false
    private(set) var isRemoving = false
    private(set) var selection: Set<DuplicateFile.ID> = []

    var minimumBytes: Int64 = 1_000_000 {
        didSet { selection.formIntersection(removableIDs) }
    }

    var isBusyWithDisk: Bool { operations.isBusy }

    var groups: [FileDuplicateGroup] {
        (results?.groups ?? []).filter { $0.keeper.logicalBytes >= minimumBytes }
    }

    private var removableIDs: Set<DuplicateFile.ID> {
        Set(groups.flatMap(\.removable).map(\.id))
    }

    var selectionBytes: Int64 {
        groups.flatMap(\.removable)
            .filter { selection.contains($0.id) }
            .reduce(0) { $0 + $1.allocatedBytes }
    }

    var removeLabel: String {
        guard !selection.isEmpty else { return "Move to Trash" }
        return "Move to Trash (\(ByteFormatting.string(selectionBytes)))"
    }

    func chooseFolders() {
        guard !isBusyWithDisk, folderTask == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Folders to Scan"
        panel.message = "Moppo compares the contents of files in these folders."
        panel.prompt = "Scan"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        folderTask = Task { [self] in
            defer { folderTask = nil }
            guard await panel.presentAsSheet() == .OK else { return }
            startScan(roots: panel.urls)
        }
    }

    func startScan(roots: [URL]? = nil) {
        guard !isBusyWithDisk else { return }
        let roots = roots ?? results?.roots ?? []
        guard !roots.isEmpty else {
            chooseFolders()
            return
        }
        guard let operation = operations.begin(.fileScan) else { return }
        let preferences = preferences()
        let scanID = UUID()
        self.scanID = scanID
        isScanning = true
        isInterrupting = false
        progress = .init(stage: .enumerating)
        selection.removeAll()
        onEvent(.scanStarted)

        scanTask = Task { [self] in
            let presentation = OperationPresentationDuration()
            defer {
                if self.scanID == scanID {
                    isScanning = false
                    isInterrupting = false
                    if Task.isCancelled { progress = nil }
                    scanTask = nil
                    self.scanID = nil
                }
                operations.finish(operation)
            }
            do {
                let results = try await service.scan(
                    roots: roots,
                    // Keep all sizes so the filter can change without another scan.
                    options: .init(minimumLogicalBytes: 0),
                    excludedPaths: preferences.excludedPaths,
                    excludedPatterns: preferences.excludedPatterns,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.scanID == scanID, !self.isInterrupting else { return }
                            guard (progress.fractionCompleted ?? -1)
                                >= (self.progress?.fractionCompleted ?? -1) else { return }
                            self.progress = progress
                        }
                    }
                )
                try Task.checkCancellation()
                guard self.scanID == scanID else { return }
                self.results = results
            } catch is CancellationError {
                // Keep the previous results when the user stops the scan.
            } catch {
                guard self.scanID == scanID, !Task.isCancelled else { return }
                onEvent(.failure(
                    title: "The Duplicate Scan Did Not Finish",
                    message: "Moppo could not finish comparing those folders. Try scanning again."
                ))
            }
            try? await presentation.wait()
        }
    }

    /// Keep the shared guard until the scan service finishes cancellation.
    func cancelScan() {
        guard isScanning, !isInterrupting else { return }
        isInterrupting = true
        scanTask?.cancel()
    }

    /// Other disk changes require a new scan before these files can be selected.
    func invalidateResults() {
        cancelScan()
        results = nil
        progress = nil
        selection.removeAll()
    }

    func selectAll() {
        guard !isBusyWithDisk else { return }
        selection = removableIDs
    }

    func deselectAll() {
        guard !isBusyWithDisk else { return }
        selection.removeAll()
    }

    func toggle(_ fileID: DuplicateFile.ID) {
        guard !isBusyWithDisk, removableIDs.contains(fileID) else { return }
        if selection.contains(fileID) { selection.remove(fileID) }
        else { selection.insert(fileID) }
    }

    func isGroupSelected(_ groupID: FileDuplicateGroup.ID) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        return !group.removable.isEmpty && group.removable.allSatisfy { selection.contains($0.id) }
    }

    func toggleGroup(_ groupID: FileDuplicateGroup.ID) {
        guard !isBusyWithDisk, let group = groups.first(where: { $0.id == groupID }) else { return }
        let ids = group.removable.map(\.id)
        if isGroupSelected(groupID) { selection.subtract(ids) }
        else { selection.formUnion(ids) }
    }

    func keepInstead(groupID: FileDuplicateGroup.ID, fileID: DuplicateFile.ID) {
        guard !isBusyWithDisk, groups.contains(where: { $0.id == groupID }),
              var results,
              let index = results.groups.firstIndex(where: { $0.id == groupID }),
              let promoted = results.groups[index].promoting(fileID)
        else { return }
        let groupWasSelected = results.groups[index].removable.contains { selection.contains($0.id) }
        let previousKeeper = results.groups[index].keeper.id
        results.groups[index] = promoted
        self.results = results
        selection.remove(fileID)
        if groupWasSelected { selection.insert(previousKeeper) }
    }

    func removeSelected() async {
        guard !Task.isCancelled else { return }
        let selected = selection.intersection(removableIDs)
        guard !selected.isEmpty, let operation = operations.begin(.fileRemoval) else { return }
        let groups = groups
        let bytes = selectionBytes
        let settings = preferences()
        isRemoving = true
        let task = Task { [self] in
            let confirmed = await settings.confirmRemoval(
                .trash(itemCount: selected.count, totalBytes: bytes), using: confirmRemoval
            )
            if confirmed {
                onEvent(.removalStarted(count: selected.count, bytes: bytes))
                await performRemoval(selected, groups: groups, bytes: bytes, keepReceipt: settings.keepReceipt)
            }
            // Publish completion before the progress surface and shared guard close.
            onEvent(.operationFinished)
            isRemoving = false
            operations.finish(operation)
            if confirmed { await refreshAfterRemoval() }
        }
        await task.value
    }

    private func performRemoval(
        _ selected: Set<DuplicateFile.ID>, groups: [FileDuplicateGroup], bytes: Int64, keepReceipt: Bool
    ) async {
        var presentation = OperationPresentationDuration()
        presentation.extend(toShow: .deletion(bytes: bytes))
        do {
            let result = try await removalService.remove(
                selectedIDs: selected, from: groups, privilegedFallback: true, keepReceipt: keepReceipt
            )
            let outcome = result.cleanup
            let removed = selected.subtracting(outcome.failed)
            let noLongerVerified = removed.union(result.staleFileIDs)
            if var results {
                results.groups = results.groups.compactMap { group in
                    guard !result.staleGroupIDs.contains(group.id) else { return nil }
                    return group.removingFiles(withIDs: noLongerVerified)
                }
                self.results = results
            }
            selection.formIntersection(removableIDs)
            try? await presentation.wait()
            onEvent(.removed(
                outcome, extraFailures: max(0, selected.count - outcome.removedCount - outcome.failed.count)
            ))
        } catch is CancellationError {
            // The service stopped before it completed a removal.
        } catch {
            onEvent(.failure(
                title: "The Duplicates Could Not Be Moved",
                message: "The selected copies could not move to the Trash. Nothing was removed."
            ))
        }
    }
}
