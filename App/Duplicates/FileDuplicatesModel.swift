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
    @ObservationIgnored private let settings: SettingsStore?
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
        settings: SettingsStore? = nil,
        preferences: @escaping () -> Preferences = { Preferences() }
    ) {
        self.operations = operations
        self.service = service
        self.removalService = removalService
        self.preferences = preferences
        self.settings = settings
        self.keeperRule = settings?.duplicateKeeperRule ?? .oldest
    }

    private(set) var results: FileDuplicateResults?
    private(set) var progress: FileDuplicateService.Progress?
    private(set) var isScanning = false
    private(set) var isInterrupting = false
    private(set) var isRemoving = false
    private(set) var selection: Set<DuplicateFile.ID> = []
    private(set) var keeperRule: DuplicateKeeperRule

    var keeperRuleLabel: String {
        switch keeperRule {
        case .oldest: "Oldest copy"
        case .newest: "Newest copy"
        case .shortestPath: "Shortest path"
        case .inFolder: "Copies in a folder"
        }
    }

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
        if case let .inFolder(folder) = keeperRule,
           !KeeperFolderSelection.contains(folder, in: roots) {
            setKeeperRule(.oldest)
        }
        guard let operation = operations.begin(.fileScan, cancel: { [weak self] in self?.cancelScan() }) else { return }
        let preferences = preferences()
        let keeperRule = keeperRule
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
                    options: .init(minimumLogicalBytes: 0, keeperRule: keeperRule),
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
        guard !operations.explainBlockedAction() else { return }
        selection = removableIDs
    }

    func deselectAll() {
        guard !operations.explainBlockedAction() else { return }
        selection.removeAll()
    }

    func toggle(_ fileID: DuplicateFile.ID) {
        guard removableIDs.contains(fileID), !operations.explainBlockedAction() else { return }
        if selection.contains(fileID) { selection.remove(fileID) }
        else { selection.insert(fileID) }
    }

    func isGroupSelected(_ groupID: FileDuplicateGroup.ID) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        return !group.removable.isEmpty && group.removable.allSatisfy { selection.contains($0.id) }
    }

    func toggleGroup(_ groupID: FileDuplicateGroup.ID) {
        guard let group = groups.first(where: { $0.id == groupID }),
              !operations.explainBlockedAction() else { return }
        let ids = group.removable.map(\.id)
        if isGroupSelected(groupID) { selection.subtract(ids) }
        else { selection.formUnion(ids) }
    }

    func keepInstead(groupID: FileDuplicateGroup.ID, fileID: DuplicateFile.ID) {
        guard groups.contains(where: { $0.id == groupID }),
              var results,
              let index = results.groups.firstIndex(where: { $0.id == groupID }),
              let promoted = results.groups[index].promoting(fileID),
              !operations.explainBlockedAction()
        else { return }
        replaceGroup(at: index, with: promoted, in: &results)
        self.results = results
    }

    func setKeeperRule(_ rule: DuplicateKeeperRule) {
        guard !operations.explainBlockedAction() else { return }
        if case let .inFolder(folder) = rule {
            guard KeeperFolderSelection.contains(folder, in: results?.roots ?? []) else { return }
        }
        keeperRule = rule
        settings?.duplicateKeeperRule = rule
        guard var results else { return }
        for index in results.groups.indices where results.groups[index].keeperReason != .chosenByUser {
            replaceGroup(at: index, with: results.groups[index].applying(rule), selectAllCopies: true, in: &results)
        }
        self.results = results
    }

    private func replaceGroup(
        at index: Int, with group: FileDuplicateGroup, selectAllCopies: Bool = false,
        in results: inout FileDuplicateResults
    ) {
        let previous = results.groups[index]
        let wasSelected = previous.files.contains { selection.contains($0.id) }
        selection.remove(group.keeper.id)
        if wasSelected {
            selection.formUnion(selectAllCopies ? group.removable.map(\.id) : [previous.keeper.id])
        }
        results.groups[index] = group
    }

    func chooseKeeperFolder() {
        guard !isBusyWithDisk, folderTask == nil, let roots = results?.roots else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Copies to Keep"
        panel.message = "Choose a folder inside the scanned folders. Moppo keeps copies in this folder first."
        panel.prompt = "Keep Copies Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.directoryURL = roots.first
        let delegate = KeeperFolderSelection(roots: roots)
        panel.delegate = delegate
        folderTask = Task { [self] in
            defer { folderTask = nil }
            guard await panel.presentAsSheet() == .OK, let folder = panel.url,
                  KeeperFolderSelection.contains(folder, in: delegate.roots) else { return }
            setKeeperRule(.inFolder(folder.standardizedFileURL))
        }
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
                selectedIDs: selected, from: groups, keepReceipt: keepReceipt
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

@MainActor
private final class KeeperFolderSelection: NSObject, NSOpenSavePanelDelegate {
    let roots: [URL]

    init(roots: [URL]) { self.roots = roots }

    static func contains(_ folder: URL, in roots: [URL]) -> Bool {
        guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
        let path = folder.standardizedFileURL.path
        return roots.contains {
            let root = $0.standardizedFileURL.path
            return path == root || path.hasPrefix(root == "/" ? root : root + "/")
        }
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        if Self.contains(url, in: roots) { return true }
        let path = url.standardizedFileURL.path
        return roots.contains { $0.standardizedFileURL.path.hasPrefix(path == "/" ? path : path + "/") }
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard Self.contains(url, in: roots) else {
            throw NSError(domain: "Moppo.DuplicateKeeperFolder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Choose a folder inside the scanned folders."
            ])
        }
    }
}
