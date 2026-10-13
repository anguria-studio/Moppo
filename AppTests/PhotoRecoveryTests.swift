import AppKit
import Foundation
import MoppoCore
import Photos
import Testing

@Suite("Photo review recovery")
@MainActor
struct PhotoRecoveryTests {
    @Test("Scrolling retains visible thumbnails and bounds the recent image cache")
    func thumbnailCache() async throws {
        let fetcher = ThumbnailRequests()
        let loader = PhotoThumbnailLoader(fetchImage: { id, _ in await fetcher.fetch(id) })
        loader.retain("visible")
        try await waitUntil { loader.image(for: "visible") != nil }
        for index in 0..<200 {
            let id = String(index)
            loader.retain(id)
            try await waitUntil { loader.image(for: id) != nil }
            loader.release(id)
        }
        #expect(loader.image(for: "visible") != nil)
        #expect(loader.image(for: "0") == nil)
        #expect(loader.image(for: "199") != nil)
        let retained = (0..<200).filter { loader.image(for: String($0)) != nil }.count
        #expect(retained == 159)
        loader.retain("199")
        #expect(await fetcher.requests["199"] == 1)
        loader.release("199")
        loader.retain("0")
        try await waitUntil { loader.image(for: "0") != nil }
        #expect(await fetcher.requests["0"] == 2)
        loader.release("0")
        loader.release("visible")
    }

    @Test("Thumbnail loading limits requests and cancels photos after their last view disappears")
    func thumbnailVisibility() async throws {
        let fetcher = ThumbnailRequests(held: true)
        let loader = PhotoThumbnailLoader(fetchImage: { id, _ in await fetcher.fetch(id) })
        for index in 0..<12 { loader.retain(String(index)) }
        loader.retain("0")
        try await waitUntil { await fetcher.requests.count == 6 }
        loader.release("0")
        #expect(await fetcher.requests.count == 6)
        await fetcher.finish("0")
        try await waitUntil { loader.image(for: "0") != nil }
        try await waitUntil { await fetcher.requests.count == 7 }

        loader.release("11")
        loader.release("1")
        try await waitUntil { await fetcher.requests.count == 8 }
        await fetcher.finish("1")
        try await waitUntil { await fetcher.returned.contains("1") }
        #expect(loader.image(for: "1") == nil)
        loader.retain("1")
        await fetcher.finishAll()
        try await waitUntil { loader.image(for: "1") != nil && loader.image(for: "10") != nil }
        #expect(await fetcher.requests["1"] == 2)
        #expect(await fetcher.requests["11"] == nil)
        for index in 0..<11 { loader.release(String(index)) }
    }

    @Test("Photo zoom preserves the view for a sharper image and resets for another photo")
    func previewZoom() {
        let view = PhotoZoomScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
        view.show(NSImage(size: NSSize(width: 120, height: 160)), assetID: "first")
        view.layoutSubtreeIfNeeded()
        #expect(view.allowsMagnification)
        #expect(view.magnification == 1)
        #expect(view.documentView?.frame.size == view.contentSize)

        view.setMagnification(2, centeredAt: NSPoint(x: 320, y: 240))
        let zoomedOrigin = view.contentView.bounds.origin
        view.show(NSImage(size: NSSize(width: 1200, height: 1600)), assetID: "first")
        view.layoutSubtreeIfNeeded()
        #expect(view.magnification == 2)
        #expect(view.contentView.bounds.origin == zoomedOrigin)

        view.frame.size = NSSize(width: 800, height: 600)
        view.layoutSubtreeIfNeeded()
        #expect(view.magnification == 2)
        #expect(view.documentView?.frame.size == view.contentSize)

        view.show(NSImage(size: NSSize(width: 1600, height: 1200)), assetID: "second")
        view.layoutSubtreeIfNeeded()
        #expect(view.magnification == 1)
        #expect(view.contentView.bounds.origin == .zero)
    }

    @Test("A failed preview stops loading and permits retry", arguments: [false, true])
    func previewRetry(allowsNetwork: Bool) async throws {
        let fetcher = PreviewFetcher()
        let loader = PhotoThumbnailLoader(fetchPreview: { _, allowsNetwork, report in
            await fetcher.fetch(allowsNetwork: allowsNetwork, report: report)
        })
        loader.allowsNetworkFetch = { allowsNetwork }
        loader.loadPreview("photo")
        try await waitUntil { !loader.isPreviewLoading("photo") }
        #expect(loader.unavailablePreviews.contains("photo"))
        #expect(loader.downloadProgress.isEmpty)
        #expect(loader.preview(for: "photo") == nil)

        await fetcher.setAvailable()
        loader.loadPreview("photo")
        #expect(loader.isPreviewLoading("photo"))
        #expect(loader.unavailablePreviews.isEmpty)
        try await waitUntil { !loader.isPreviewLoading("photo") }
        #expect(loader.preview(for: "photo") != nil)
        #expect(loader.downloadProgress.isEmpty)
        #expect(await fetcher.networkRequests == [allowsNetwork, allowsNetwork])
    }

    @Test("Closing a preview ignores late progress and permits another request")
    func previewCancellation() async throws {
        let fetcher = HeldPreview()
        let loader = PhotoThumbnailLoader(fetchPreview: { _, _, report in
            await fetcher.fetch(report: report)
        })
        loader.loadPreview("photo")
        try await waitUntil { await fetcher.isWaiting }
        loader.cancelPreview("photo")
        #expect(!loader.isPreviewLoading("photo"))
        await fetcher.finish()
        try await waitUntil { await fetcher.didReturn }
        await Task.yield()
        #expect(loader.preview(for: "photo") == nil)
        #expect(loader.downloadProgress.isEmpty)
        #expect(loader.unavailablePreviews.isEmpty)

        loader.loadPreview("photo")
        try await waitUntil { !loader.isPreviewLoading("photo") }
        #expect(loader.preview(for: "photo") != nil)
    }

    @Test("Clearing photo access discards late thumbnails and previews")
    func resetIgnoresLateImages() async throws {
        let fetcher = HeldPreview()
        let loader = PhotoThumbnailLoader(
            fetchImage: { _, _ in await fetcher.fetch(report: { _ in }) },
            fetchPreview: { _, _, report in await fetcher.fetch(report: report) }
        )
        loader.load("grid")
        loader.loadPreview("photo")
        try await waitUntil { await fetcher.waitingCount == 2 }
        loader.reset()
        await fetcher.finish()
        try await waitUntil { await fetcher.didReturn }
        await Task.yield()
        #expect(loader.image(for: "grid") == nil)
        #expect(loader.preview(for: "photo") == nil)
        #expect(loader.downloadProgress.isEmpty)
        #expect(!loader.isPreviewLoading("photo"))
    }

    @Test("Revoked access clears photo review and requires a new scan", arguments: [
        PhotoLibraryAccess.denied, .limited, .restricted, .notDetermined, .unavailable
    ])
    func revokedReview(access: PhotoLibraryAccess) async throws {
        let fixture = PhotoFixture()
        let model = fixture.model()
        await model.photoDuplicates.requestAccess()
        model.photoDuplicates.startScan()
        try await waitUntil { !model.photoDuplicates.isScanning }
        let group = try #require(model.photoDuplicates.groups.first)
        model.photoDuplicates.preview = .init(groupID: group.id, asset: group.keeper)
        model.photoDuplicates.setSelected(true, assetID: try #require(group.removable.first).id)

        await fixture.library.configure(access: access)
        model.photoDuplicates.refreshAccess(access)
        #expect(!model.photoDuplicates.canAccessPhotos)
        #expect(model.photoDuplicates.results == nil)
        #expect(model.photoDuplicates.selection.isEmpty)
        #expect(model.photoDuplicates.preview == nil)
        #expect(!model.isBusyWithDisk)

        await fixture.library.configure()
        model.photoDuplicates.refreshAccess(.authorized)
        #expect(model.photoDuplicates.canAccessPhotos)
        #expect(model.photoDuplicates.results == nil)
        model.photoDuplicates.startScan()
        try await waitUntil { !model.photoDuplicates.isScanning }
        #expect(model.photoDuplicates.groups.count == 1)
    }

    @Test("Revoked access before deletion clears review without reporting success")
    func revokedDeletion() async throws {
        let fixture = PhotoFixture()
        let model = fixture.model()
        await model.photoDuplicates.requestAccess()
        model.photoDuplicates.startScan()
        try await waitUntil { !model.photoDuplicates.isScanning }
        model.photoDuplicates.selectAll()
        await fixture.library.configure(access: .denied)
        await model.photoDuplicates.deleteSelected()
        #expect(await fixture.library.deletions == 0)
        #expect(model.photoDuplicates.results == nil)
        #expect(model.removalCompletion == nil)
        #expect(!model.photoDuplicates.canAccessPhotos)
        #expect(!model.isBusyWithDisk)
    }

    @Test("Missing photos clear review and permit another scan")
    func missingPhotos() async throws {
        let fixture = PhotoFixture()
        let model = fixture.model()
        await model.photoDuplicates.requestAccess()
        model.photoDuplicates.startScan()
        try await waitUntil { !model.photoDuplicates.isScanning }
        model.photoDuplicates.selectAll()
        await fixture.library.configure(missing: true)
        await model.photoDuplicates.deleteSelected()
        #expect(model.photoDuplicates.results == nil)
        #expect(model.photoDuplicates.selection.isEmpty)
        #expect(model.photoDuplicates.unavailableReason != nil)
        #expect(model.removalCompletion == nil)
        #expect(!model.isBusyWithDisk)
        await fixture.library.configure()
        model.photoDuplicates.startScan()
        try await waitUntil { !model.photoDuplicates.isScanning }
        #expect(model.photoDuplicates.groups.count == 1)
        #expect(model.photoDuplicates.unavailableReason == nil)
    }

    @Test("Deleted photos stay absent when the extracted model regroups the retained scan")
    func deletionThenRegroup() async throws {
        let fixture = PhotoFixture()
        let service = PhotoDuplicateService(library: fixture.library, visionRevision: 2, cacheDirectory: fixture.cache)
        let suite = "PhotoRecoveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = PhotoDuplicatesModel(
            operations: OperationCoordinator(), defaults: defaults, makeService: { _ in service }
        )
        await model.requestAccess()
        model.startScan()
        try await waitUntil { !model.isScanning }
        #expect(model.groups.count == 1)
        await model.deleteSelected()
        #expect(model.groups.isEmpty)
        model.similarity = .veryLoose
        try await waitUntil { !model.isRegrouping }
        #expect(model.groups.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(model.results?.examinedCount == 1)
    }
}

private actor PreviewFetcher {
    var available = false
    var networkRequests: [Bool] = []
    func setAvailable() { available = true }
    func fetch(allowsNetwork: Bool, report: @Sendable (Double) -> Void) -> NSImage? {
        networkRequests.append(allowsNetwork)
        report(0.5)
        return available ? NSImage(size: NSSize(width: 10, height: 10)) : nil
    }
}

private actor HeldPreview {
    var continuations: [CheckedContinuation<Void, Never>] = []
    var reports: [@Sendable (Double) -> Void] = []
    var didReturn = false
    var waitingCount: Int { continuations.count }
    var isWaiting: Bool { !continuations.isEmpty }

    func fetch(report: @escaping @Sendable (Double) -> Void) async -> NSImage? {
        if !didReturn {
            reports.append(report)
            await withCheckedContinuation { continuations.append($0) }
        }
        didReturn = true
        return NSImage(size: NSSize(width: 10, height: 10))
    }

    func finish() {
        reports.forEach { $0(0.9) }
        continuations.forEach { $0.resume() }
        continuations.removeAll()
    }
}

private final class PhotoFixture {
    let library = TestPhotoLibrary()
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: cache) }

    @MainActor
    func model() -> AppModel {
        let service = PhotoDuplicateService(library: library, visionRevision: 2, cacheDirectory: cache)
        let model = AppModel(makePhotoService: { _ in service })
        model.view = .duplicates
        model.duplicateKind = .photos
        return model
    }
}

private actor TestPhotoLibrary: PhotoLibraryProviding {
    var access: PhotoLibraryAccess = .authorized
    var missing = false
    var deletions = 0
    func configure(access: PhotoLibraryAccess = .authorized, missing: Bool = false) {
        self.access = access
        self.missing = missing
    }
    func authorize() async -> PhotoLibraryAccess { access }
    func fetchAssets() async throws -> [PhotoAsset] {
        [PhotoAsset(id: "a", burstIdentifier: "burst", representsBurst: true),
         PhotoAsset(id: "b", burstIdentifier: "burst")]
    }
    func fingerprint(assetID: String) async -> PhotoFingerprint? { nil }
    func delete(assetIDs: [String]) async throws {
        if missing { throw PhotoDeletionUnavailable.missingAssets }
        deletions += 1
    }
}

private actor ThumbnailRequests {
    var requests: [String: Int] = [:]
    var returned: Set<String> = []
    private var held: Bool
    private var pending: [String: CheckedContinuation<Void, Never>] = [:]

    init(held: Bool = false) { self.held = held }

    func fetch(_ id: String) async -> NSImage {
        requests[id, default: 0] += 1
        if held { await withCheckedContinuation { pending[id] = $0 } }
        returned.insert(id)
        return NSImage(size: NSSize(width: 10, height: 10))
    }

    func finish(_ id: String) { pending.removeValue(forKey: id)?.resume() }

    func finishAll() {
        held = false
        let waiting = pending.values
        pending.removeAll()
        waiting.forEach { $0.resume() }
    }
}
