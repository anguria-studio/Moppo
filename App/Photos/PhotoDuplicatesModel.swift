import Foundation
import Observation
import MoppoCore

/// Allows photo operations to use a test library without PhotoKit access.
protocol PhotoDuplicatesServicing: Sendable {
    func requestAccess() async -> PhotoLibraryAccess
    func sweep(
        minimumAssets: Int,
        similarity: PhotoSimilarity,
        onProgress: (@Sendable (PhotoDuplicateService.Progress) -> Void)?
    ) async throws -> PhotoDuplicateResults
    func regroup(
        similarity: PhotoSimilarity,
        onProgress: (@Sendable (PhotoDuplicateService.Progress) -> Void)?
    ) async throws -> PhotoDuplicateResults?
    func delete(assetIDs: [String]) async throws
}

extension PhotoDuplicateService: PhotoDuplicatesServicing {}

/// Owns photo access, scans, grouping, selection, previews, and deletion.
@MainActor
@Observable
final class PhotoDuplicatesModel {
    struct Preview: Identifiable {
        let groupID: String
        let asset: PhotoAsset
        var id: String { asset.id }
    }

    enum Event {
        case scanStarted
        case deletionStarted
        case deleted(count: Int)
        case failure(title: String, message: String)
    }

    @ObservationIgnored private let operations: OperationCoordinator
    @ObservationIgnored private let makeService: (Bool) -> any PhotoDuplicatesServicing
    @ObservationIgnored private let allowsNetworkFetch: () -> Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var service: any PhotoDuplicatesServicing
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID: UUID?
    @ObservationIgnored private var regroupTask: Task<Void, Never>?
    @ObservationIgnored private var regroupID: UUID?
    @ObservationIgnored private var accessTask: Task<Void, Never>?
    @ObservationIgnored private var accessRevision = UUID()
    @ObservationIgnored private var deletionTask: Task<Void, Never>?

    @ObservationIgnored var canRequestAccess: () -> Bool = { true }
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }

    init(
        operations: OperationCoordinator,
        defaults: UserDefaults = .standard,
        allowsNetworkFetch: @escaping () -> Bool = { true },
        makeService: @escaping (Bool) -> any PhotoDuplicatesServicing = { allowsNetwork in
            PhotoDuplicateService(
                library: PhotoKitLibrary(allowsNetworkFetch: allowsNetwork),
                visionRevision: UInt32(PhotoKitLibrary.featurePrintRevision)
            )
        }
    ) {
        self.operations = operations
        self.defaults = defaults
        self.allowsNetworkFetch = allowsNetworkFetch
        self.makeService = makeService
        self.service = makeService(allowsNetworkFetch())
        self.similarity = defaults.string(forKey: "photoSimilarity")
            .flatMap(PhotoSimilarity.init(rawValue:)) ?? .default
        thumbnails.allowsNetworkFetch = allowsNetworkFetch
    }

    var preview: Preview?
    let thumbnails = PhotoThumbnailLoader()
    private(set) var results: PhotoDuplicateResults?
    private(set) var progress: PhotoDuplicateService.Progress?
    private(set) var isScanning = false
    private(set) var isInterrupting = false
    private(set) var isDeleting = false
    private(set) var isRegrouping = false
    private(set) var selection: Set<String> = []
    private(set) var unavailableReason: String?
    private(set) var libraryAccess: PhotoLibraryAccess?
    private(set) var isRequestingAccess = false

    var isBusyWithDisk: Bool { operations.isBusy }
    var canAccessPhotos: Bool { libraryAccess?.canSweep == true && !isRequestingAccess }

    /// AppModel supplies the access context without exposing navigation to this model.
    func requestAccess() async {
        guard canRequestAccess(), !isRequestingAccess, !Task.isCancelled else { return }
        isRequestingAccess = true
        let revision = accessRevision
        let task = Task { [self] in
            defer {
                isRequestingAccess = false
                accessTask = nil
            }
            let access = await service.requestAccess()
            // A scan or deletion can report newer access while this request waits.
            guard accessRevision == revision else { return }
            applyAccess(access)
        }
        accessTask = task
        await task.value
    }

    private func applyAccess(_ access: PhotoLibraryAccess) {
        accessRevision = UUID()
        libraryAccess = access
        if !access.canSweep {
            cancelScan()
            cancelRegroup()
            results = nil
            progress = nil
            unavailableReason = nil
            selection.removeAll()
            preview = nil
            thumbnails.reset()
        }
    }

    /// Regroup the retained scan when the saved similarity setting changes.
    var similarity: PhotoSimilarity {
        didSet {
            guard similarity != oldValue else { return }
            defaults.set(similarity.rawValue, forKey: "photoSimilarity")
            regroup()
        }
    }

    /// Keep groups in date order, with undated groups last.
    var groups: [DuplicateGroup] {
        guard let results else { return [] }
        return results.groups.sorted {
            switch ($0.assets.first?.creationDate, $1.assets.first?.creationDate) {
            case let (left?, right?): left == right ? $0.id < $1.id : left > right
            case (nil, _?):           false
            case (_?, nil):           true
            case (nil, nil):          $0.id < $1.id
            }
        }
    }

    /// Photo removal reports counts because PhotoKit does not provide a measured size.
    var removeLabel: String {
        let count = selection.count
        guard count > 0 else { return "Delete Photos" }
        return "Delete \(count) \(count == 1 ? "Photo" : "Photos")"
    }

    func startScan() {
        guard canAccessPhotos, let operation = operations.begin(.photoScan) else { return }
        cancelRegroup()
        let service = makeService(allowsNetworkFetch())
        let similarity = similarity
        let scanID = UUID()
        self.scanID = scanID
        isScanning = true
        isInterrupting = false
        progress = nil
        unavailableReason = nil
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
                let results = try await service.sweep(
                    minimumAssets: 0,
                    similarity: similarity,
                    onProgress: { [weak self] progress in
                        Task { @MainActor in
                            guard let self, self.scanID == scanID, !self.isInterrupting else { return }
                            self.progress = progress
                        }
                    }
                )
                try Task.checkCancellation()
                guard self.scanID == scanID else { return }
                self.service = service
                self.results = results
                selection = Self.defaultSelection(for: results)
            } catch let unavailable as PhotoSweepUnavailable {
                guard self.scanID == scanID, !Task.isCancelled else { return }
                if case .access(let access) = unavailable {
                    applyAccess(access)
                } else {
                    unavailableReason = Self.describe(unavailable)
                }
            } catch is CancellationError {
                // Keep the last complete result after a stopped scan.
            } catch {
                guard self.scanID == scanID, !Task.isCancelled else { return }
                onEvent(.failure(
                    title: "The Photo Sweep Did Not Finish",
                    message: "Moppo could not finish comparing the library. Nothing was deleted. Try again."
                ))
            }
            try? await presentation.wait()
        }
    }

    private func regroup() {
        guard canAccessPhotos, results != nil, !isScanning, !isDeleting else { return }
        cancelRegroup()
        let regroupID = UUID()
        self.regroupID = regroupID
        let similarity = similarity
        isRegrouping = true

        regroupTask = Task { [self] in
            defer {
                if self.regroupID == regroupID {
                    isRegrouping = false
                    regroupTask = nil
                    self.regroupID = nil
                }
            }
            do {
                guard let results = try await service.regroup(similarity: similarity, onProgress: nil) else { return }
                guard self.regroupID == regroupID, !Task.isCancelled,
                      similarity == self.similarity else { return }
                self.results = results
                // New groups can have different keepers, so discard the previous selection.
                selection = Self.defaultSelection(for: results)
            } catch is CancellationError {
                // A later setting or scan replaces this request.
            } catch {
                guard self.regroupID == regroupID, !Task.isCancelled else { return }
                onEvent(.failure(
                    title: "The Photos Could Not Be Regrouped",
                    message: "Moppo could not apply that setting to the sweep it has. Scan again to use it."
                ))
            }
        }
    }

    private func cancelRegroup() {
        regroupTask?.cancel()
        regroupTask = nil
        regroupID = nil
        isRegrouping = false
    }

    /// Keep the operation reserved until the service finishes cancellation.
    func cancelScan() {
        guard isScanning, !isInterrupting else { return }
        isInterrupting = true
        scanTask?.cancel()
    }

    private static func describe(_ unavailable: PhotoSweepUnavailable) -> String {
        switch unavailable {
        case .access(let access):
            access.unavailableReason ?? "The photo library is unavailable."
        case .librarySyncing(let count):
            "Only \(count) photos have arrived from iCloud so far. Let Photos finish syncing before you scan again."
        }
    }

    func selectAll() {
        selection = Set(groups.flatMap(\.removable).map(\.id))
    }

    /// Select burst and identical copies automatically. Similar copies require a user selection.
    private static func defaultSelection(for results: PhotoDuplicateResults) -> Set<String> {
        Set(results.groups.filter { $0.kind != .similar }.flatMap(\.removable).map(\.id))
    }

    func deselectAll() { selection.removeAll() }

    func keepInstead(groupID: String, assetID: String) {
        guard var results,
              let index = results.groups.firstIndex(where: { $0.id == groupID }),
              let promoted = results.groups[index].promoting(assetID)
        else { return }
        let previousKeeper = results.groups[index].keeper.id
        results.groups[index] = promoted
        self.results = results
        selection.remove(assetID)
        // Select the previous keeper only when other copies remain selected.
        if promoted.removable.contains(where: { selection.contains($0.id) }) {
            selection.insert(previousKeeper)
        }
    }

    func setSelected(_ isSelected: Bool, assetID: String) {
        guard groups.contains(where: { $0.removable.contains(where: { $0.id == assetID }) }) else { return }
        if isSelected { selection.insert(assetID) }
        else { selection.remove(assetID) }
    }

    func toggle(_ assetID: String) {
        setSelected(!selection.contains(assetID), assetID: assetID)
    }

    func isGroupSelected(_ groupID: String) -> Bool {
        guard let group = groups.first(where: { $0.id == groupID }) else { return false }
        return !group.removable.isEmpty && group.removable.allSatisfy { selection.contains($0.id) }
    }

    func toggleGroup(_ groupID: String) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        let ids = group.removable.map(\.id)
        if isGroupSelected(groupID) { selection.subtract(ids) }
        else { selection.formUnion(ids) }
    }

    func deleteSelected() async {
        guard canAccessPhotos, !isRegrouping, !Task.isCancelled else { return }
        let removableIDs = Set(groups.flatMap(\.removable).map(\.id))
        let ids = Array(selection.intersection(removableIDs))
        guard !ids.isEmpty, let operation = operations.begin(.photoDeletion) else { return }
        isDeleting = true
        preview = nil
        onEvent(.deletionStarted)
        let task = Task { [self] in
            defer {
                isDeleting = false
                deletionTask = nil
                operations.finish(operation)
            }
            await performDeletion(ids)
        }
        deletionTask = task
        await task.value
    }

    private func performDeletion(_ ids: [String]) async {
        let presentation = OperationPresentationDuration()
        do {
            try await service.delete(assetIDs: ids)
            let gone = Set(ids)
            if var results {
                results.groups = results.groups.compactMap { group in
                    let remaining = group.removable.filter { !gone.contains($0.id) }
                    guard !remaining.isEmpty else { return nil }
                    return DuplicateGroup(id: group.id, kind: group.kind, keeper: group.keeper, removable: remaining)
                }
                self.results = results
            }
            selection.removeAll()
            try? await presentation.wait()
            onEvent(.deleted(count: ids.count))
        } catch is CancellationError {
            // Keep the selection when the user declines the Photos request.
        } catch PhotoSweepUnavailable.access(let access) {
            applyAccess(access)
        } catch PhotoDeletionUnavailable.missingAssets {
            results = nil
            selection.removeAll()
            unavailableReason = "Some photos are no longer available. Scan again before you delete photos."
        } catch {
            onEvent(.failure(
                title: "Those Photos Were Not Deleted",
                message: "Photos refused the deletion. Nothing was removed from the library."
            ))
        }
    }
}
