import AppKit
import Foundation
import MoppoCore
import Observation

struct StorageExplorerLocation: Identifiable, Hashable {
    let url: URL
    let name: String
    let isInternal: Bool

    var id: String { url.path }
    var symbol: String { isInternal ? "internaldrive" : "externaldrive" }
}

/// Owns Storage Explorer measurements, folder history, selection, and removal tasks.
@MainActor
@Observable
final class StorageExplorerModel {
    typealias Preferences = RemovalPreferences
    enum Event {
        case reviewing(count: Int)
        case removalStarted(count: Int, bytes: Int64)
        case removed(CleanupOutcome)
        case operationFinished
        case failure(title: String, message: String)
    }

    @ObservationIgnored private let operations: OperationCoordinator
    @ObservationIgnored private let preferences: () -> Preferences
    @ObservationIgnored private let service: any StorageExplorerScanning
    @ObservationIgnored private let removalService: any StorageExplorerRemoving
    @ObservationIgnored private var scanOperation: OperationCoordinator.Operation?
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }
    @ObservationIgnored var refreshAfterRemoval: () async -> Void = {}
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanGeneration = 0
    @ObservationIgnored private var cachedSnapshots: [String: StorageExplorerSnapshot] = [:]
    @ObservationIgnored private var cachedDirectoryIdentities: [String: String] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    /// A row to select as soon as the folder holding it has been measured.
    ///
    /// Every load clears the selection, because a new folder's rows have nothing to
    /// do with the previous folder's. A caller that wants one row picked out
    /// therefore cannot simply write `selection` and navigate: the request has to
    /// travel with the navigation and be applied when the measurement arrives. The
    /// Dashboard's growth report is the one caller — it opens the parent folder and
    /// names the folder that changed.
    @ObservationIgnored private var pendingSelection: URL?

    private static let cacheLimit = 32

    var snapshot: StorageExplorerSnapshot?
    var currentURL: URL?
    var selection = Set<StorageExplorerItem.ID>() {
        didSet { finishMapSelection() }
    }
    private(set) var isMapSelectionPending = false
    @ObservationIgnored private var mapSelectionTask: Task<Void, Never>?
    private(set) var isLoading = false
    private(set) var isRemoving = false
    var isMeasurementBlocked: Bool { operations.isBusy && scanOperation == nil }
    private(set) var isInterrupting = false
    var progress = SizeMeasurement.zero
    var error: StorageExplorerError?
    var wasCancelled = false
    private(set) var needsRefresh = false
    var locations: [StorageExplorerLocation] = []

    private var history: [URL] = []
    private var forwardHistory: [URL] = []

    init(
        operations: OperationCoordinator = OperationCoordinator(),
        service: any StorageExplorerScanning = StorageExplorerService(),
        removalService: any StorageExplorerRemoving = StorageExplorerRemovalService(),
        preferences: @escaping () -> Preferences = { Preferences() }
    ) {
        self.operations = operations
        self.preferences = preferences
        self.service = service
        self.removalService = removalService
    }

    var canGoBack: Bool { !history.isEmpty }
    var canGoForward: Bool { !forwardHistory.isEmpty }

    var selectedItems: [StorageExplorerItem] {
        let selected = selection
        return snapshot?.items.filter { selected.contains($0.id) } ?? []
    }

    var selectedBytes: Int64 {
        selectedItems.reduce(0) { $0 + $1.allocatedBytes }
    }

    var removeLabel: String {
        guard !isMapSelectionPending, !selectedItems.isEmpty else { return "Move to Trash" }
        return "Move to Trash (\(ByteFormatting.string(selectedBytes)))"
    }

    var canRemoveSelection: Bool {
        !isLoading && snapshot?.isComplete == true
            && !selectedItems.isEmpty && selectedItems.allSatisfy(\.isRemovable)
    }

    /// Highlight tiles immediately. Delay only the first activation of the header action.
    func selectMapItems(_ ids: Set<StorageExplorerItem.ID>) {
        let wasEnabled = canRemoveSelection && !isMapSelectionPending
        selection = ids
        guard !wasEnabled, canRemoveSelection else { return }
        isMapSelectionPending = true
        mapSelectionTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) }
            catch { return }
            self?.finishMapSelection()
        }
    }

    func finishMapSelection() {
        mapSelectionTask?.cancel()
        mapSelectionTask = nil
        isMapSelectionPending = false
    }

    func prepareLocations() {
        locations = Self.mountedLocations()
    }

    func chooseFolder() {
        guard !isMeasurementBlocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder"
        panel.message = "Moppo will measure the folder and its immediate contents."
        panel.prompt = "Explore"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        Task { @MainActor in
            guard await panel.presentAsSheet() == .OK, let url = panel.url else { return }
            selectLocation(url)
        }
    }

    /// Invalidate measured rows without releasing an active measurement guard.
    func invalidateCache() {
        clearCache()
        snapshot = nil
        selection.removeAll()
        pendingSelection = nil
        wasCancelled = false
        error = nil
        needsRefresh = currentURL != nil
        if let scanTask {
            isInterrupting = true
            scanTask.cancel()
        } else {
            scanGeneration += 1
        }
    }

    func refreshIfNeeded() {
        guard needsRefresh, !isLoading, !isMeasurementBlocked else { return }
        refresh()
    }

    func selectHome() {
        selectLocation(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    /// - Parameter revealing: a direct child of `url` to select once it is measured.
    func selectLocation(_ url: URL, revealing item: URL? = nil) {
        guard !isMeasurementBlocked else { return }
        history.removeAll()
        forwardHistory.removeAll()
        load(url, useCache: false, revealing: item)
    }

    func open(_ item: StorageExplorerItem) {
        guard !isMeasurementBlocked, item.opensAsDirectory, let currentURL else { return }
        history.append(currentURL)
        forwardHistory.removeAll()
        load(item.url)
    }

    func navigate(to url: URL) {
        guard !isMeasurementBlocked, url != currentURL else { return }
        if let currentURL { history.append(currentURL) }
        forwardHistory.removeAll()
        load(url)
    }

    func goBack() {
        guard !isMeasurementBlocked, let target = history.popLast() else { return }
        if let currentURL { forwardHistory.append(currentURL) }
        load(target)
    }

    func goForward() {
        guard !isMeasurementBlocked, let target = forwardHistory.popLast() else { return }
        if let currentURL { history.append(currentURL) }
        load(target)
    }

    func refresh(clearAllCachedFolders: Bool = false) {
        guard !isMeasurementBlocked, let currentURL else { return }
        if clearAllCachedFolders {
            clearCache()
        } else {
            removeCachedSnapshot(for: currentURL)
        }
        load(currentURL, useCache: false)
    }

    func cancel() {
        guard isLoading, !isInterrupting else { return }
        isInterrupting = true
        scanTask?.cancel()
    }

    /// Capture the review and receipt setting before starting an owned removal task.
    func requestRemoval() async {
        guard !Task.isCancelled, canRemoveSelection, !isMapSelectionPending,
              let directory = snapshot?.directory,
              let operation = operations.begin(.storageRemoval) else { return }
        let items = selectedItems
        let capturedPreferences = preferences()
        let generation = scanGeneration
        isRemoving = true
        onEvent(.reviewing(count: items.count))
        let task = Task { [self] in
            let attemptedRemoval = await performRemoval(
                items, from: directory, preferences: capturedPreferences, generation: generation
            )
            if attemptedRemoval { invalidateCache() }
            isRemoving = false
            onEvent(.operationFinished)
            operations.finish(operation)
            if attemptedRemoval { await refreshAfterRemoval() }
        }
        await task.value
    }

    private func performRemoval(
        _ items: [StorageExplorerItem], from directory: URL,
        preferences: Preferences, generation: Int
    ) async -> Bool {
        var presentation = OperationPresentationDuration()
        let review: StorageExplorerSelectionReview
        do {
            review = try await service.reviewSelection(
                items, in: directory,
                excludedPaths: preferences.excludedPaths, excludedPatterns: preferences.excludedPatterns
            )
        } catch is CancellationError {
            return false
        } catch {
            onEvent(.failure(
                title: "The Selection Could Not Be Checked",
                message: "Moppo could not check the selected items. Nothing was removed."
            ))
            return false
        }
        guard generation == scanGeneration else { return false }
        snapshot = review.snapshot
        store(review.snapshot)
        selection = Set(items.map(\.id)).intersection(Set(review.snapshot.items.map(\.id)))
        guard review.isReady else {
            if !review.changedPaths.isEmpty {
                onEvent(.failure(
                    title: "The Selection Changed",
                    message: "Some of those items are not what they were when you picked them. "
                        + "Review the updated list and try again."
                ))
            } else if !review.protectedPaths.isEmpty {
                onEvent(.failure(
                    title: "Some Items Are Protected",
                    message: "Moppo will not remove some of the selected items. "
                        + "Review the list and try again."
                ))
            } else {
                onEvent(.failure(
                    title: "Nothing Left to Remove",
                    message: "The selected items are no longer in this folder."
                ))
            }
            return false
        }
        let bytes = review.items.reduce(0) { $0 + $1.allocatedBytes }
        onEvent(.removalStarted(count: review.items.count, bytes: bytes))
        presentation.extend(toShow: .deletion(bytes: bytes))
        do {
            let outcome = try await removalService.remove(
                review.items, from: directory, keepReceipt: preferences.keepReceipt
            )
            try? await presentation.wait()
            onEvent(.removed(outcome))
        } catch is CancellationError {
            // Refresh the list because the service can stop after partial removal.
        } catch {
            onEvent(.failure(
                title: "The Items Could Not Be Moved",
                message: "The selected items could not move to the Trash. Nothing was removed."
            ))
        }
        return true
    }

    private func load(
        _ url: URL,
        useCache: Bool = true,
        revealing item: URL? = nil
    ) {
        guard !isMeasurementBlocked else { return }
        let previous = scanTask
        previous?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        needsRefresh = false
        selection.removeAll()
        pendingSelection = item
        progress = .zero
        error = nil
        wasCancelled = false
        isInterrupting = false
        currentURL = url
        let cached = useCache ? cachedSnapshot(for: url) : nil
        snapshot = cached
        if let cached, previous == nil {
            currentURL = cached.directory
            isLoading = false
            applyPendingSelection()
            return
        }
        guard let operation = scanOperation ?? operations.begin(.storageMeasurement) else { return }
        scanOperation = operation
        isLoading = true
        let capturedPreferences = preferences()

        scanTask = Task { [self] in
            defer {
                if scanGeneration == generation {
                    scanGeneration += 1
                    isLoading = false
                    isInterrupting = false
                    scanTask = nil
                    scanOperation = nil
                    if Task.isCancelled {
                        wasCancelled = !needsRefresh
                        snapshot = nil
                        selection.removeAll()
                    }
                    operations.finish(operation)
                }
            }
            // Retain the guard until every replaced measurement has returned.
            await previous?.value
            do {
                try Task.checkCancellation()
                if let cached = useCache ? cachedSnapshot(for: url) : nil {
                    currentURL = cached.directory
                    snapshot = cached
                    applyPendingSelection()
                    return
                }
                let measured = try await service.scan(
                    directory: url,
                    excludedPaths: capturedPreferences.excludedPaths,
                    excludedPatterns: capturedPreferences.excludedPatterns,
                    progress: { partial in
                        Task { @MainActor in
                            guard self.scanGeneration == generation, !self.isInterrupting,
                                  self.snapshot?.isComplete != true,
                                  partial.fileCount >= self.progress.fileCount,
                                  partial.allocatedBytes >= self.progress.allocatedBytes else { return }
                            self.snapshot = partial
                            self.progress = SizeMeasurement(
                                allocatedBytes: partial.allocatedBytes, fileCount: partial.fileCount,
                                unreadableCount: partial.unreadableCount
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                guard scanGeneration == generation else { return }
                snapshot = measured
                store(measured)
                currentURL = measured.directory
                applyPendingSelection()
            } catch is CancellationError {
                // Keep the guard until the service has stopped.
            } catch let explorerError as StorageExplorerError {
                guard scanGeneration == generation, !Task.isCancelled else { return }
                error = explorerError
            } catch {
                guard scanGeneration == generation, !Task.isCancelled else { return }
                self.error = .unavailable(url.path)
            }
        }
    }

    /// Selects the requested row, if the measurement found it.
    ///
    /// The request is consumed either way: a folder that was removed between the
    /// report and the click is simply not there, and the Explorer shows its parent
    /// rather than pretending otherwise.
    private func applyPendingSelection() {
        guard let pending = pendingSelection, let snapshot else { return }
        pendingSelection = nil
        let path = pending.standardizedFileURL.path
        guard let item = snapshot.items.first(
            where: { $0.url.standardizedFileURL.path == path }
        ) else { return }
        selection = [item.id]
    }

    private func cachedSnapshot(for url: URL) -> StorageExplorerSnapshot? {
        let key = Self.cacheKey(for: url)
        guard let snapshot = cachedSnapshots[key] else { return nil }
        guard let identity = FileIdentity.of(url), identity == cachedDirectoryIdentities[key],
              FileManager.default.isReadableFile(atPath: url.path),
              FileManager.default.isExecutableFile(atPath: url.path) else {
            removeCachedSnapshot(for: url)
            return nil
        }
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
        return snapshot
    }

    private func store(_ snapshot: StorageExplorerSnapshot) {
        guard snapshot.isComplete else { return }
        let key = Self.cacheKey(for: snapshot.directory)
        cachedSnapshots[key] = snapshot
        cachedDirectoryIdentities[key] = FileIdentity.of(snapshot.directory)
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)

        while cacheOrder.count > Self.cacheLimit {
            let oldest = cacheOrder.removeFirst()
            cachedSnapshots.removeValue(forKey: oldest)
            cachedDirectoryIdentities.removeValue(forKey: oldest)
        }
    }

    private func clearCache() {
        cachedSnapshots.removeAll()
        cachedDirectoryIdentities.removeAll()
        cacheOrder.removeAll()
    }

    private func removeCachedSnapshot(for url: URL) {
        let key = Self.cacheKey(for: url)
        cachedSnapshots.removeValue(forKey: key)
        cachedDirectoryIdentities.removeValue(forKey: key)
        cacheOrder.removeAll { $0 == key }
    }

    private static func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func mountedLocations() -> [StorageExplorerLocation] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return StorageExplorerLocation(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                isInternal: values.volumeIsInternal ?? false
            )
        }
        .sorted {
            if $0.isInternal != $1.isInternal { return $0.isInternal }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
