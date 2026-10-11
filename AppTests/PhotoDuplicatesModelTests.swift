import Foundation
import MoppoCore
import Testing

@Suite("Photo feature ownership")
@MainActor
struct PhotoDuplicatesModelTests {
    @Test("Photo highlight follows grid rows without changing keeper order")
    func gridNavigation() throws {
        let first = DuplicateGroup(
            id: "first", kind: .similar, keeper: PhotoAsset(id: "a"),
            removable: [PhotoAsset(id: "b"), PhotoAsset(id: "c"), PhotoAsset(id: "d")]
        )
        let second = DuplicateGroup(
            id: "second", kind: .exact, keeper: PhotoAsset(id: "e"), removable: [PhotoAsset(id: "f")]
        )
        var review = PhotoReviewState()
        let groups = [first, second]
        review.moveHighlight(.right, groups: groups, columns: 3)
        #expect(review.highlightedID == "a")
        review.moveHighlight(.right, groups: groups, columns: 3)
        #expect(review.highlightedID == "b")
        review.moveHighlight(.down, groups: groups, columns: 3)
        #expect(review.highlightedID == "d")
        review.moveHighlight(.down, groups: groups, columns: 3)
        #expect(review.highlightedID == "e")
        review.moveHighlight(.right, groups: groups, columns: 3)
        #expect(review.highlightedID == "f")
        review.moveHighlight(.down, groups: groups, columns: 3)
        #expect(review.highlightedID == "f")
        review.moveHighlight(.up, groups: groups, columns: 2)
        #expect(review.highlightedID == "d")
        let promoted = try #require(first.promoting("d"))
        review.update(groups: [promoted, second])
        #expect(review.highlightedID == "d")
        #expect(promoted.assets.map(\.id) == first.assets.map(\.id))
        #expect(promoted.reviewTitle == "4 similar photos · keeping your choice")
        review.update(groups: [second])
        #expect(review.highlightedID == nil)
        review.moveHighlight(.left, groups: [second], columns: 2)
        #expect(review.highlightedID == "f")
        review.moveHighlight(.right, groups: [], columns: 2)
        #expect(review.highlightedID == nil)
    }

    @Test("Photos access requires the photo page and completed onboarding")
    func accessContext() async {
        let service = HeldPhotoService()
        let app = AppModel(launchAccess: .welcome, hasFullDiskAccess: { true }, makePhotoService: { _ in service })
        await app.photoDuplicates.requestAccess()
        app.view = .duplicates
        app.duplicateKind = .photos
        await app.photoDuplicates.requestAccess()
        #expect(await service.accessRequests == 0)
        app.finishWelcomeGuide()
        app.duplicateKind = .files
        await app.photoDuplicates.requestAccess()
        #expect(await service.accessRequests == 0)
        app.duplicateKind = .photos
        await app.photoDuplicates.requestAccess()
        #expect(await service.accessRequests == 1)
        #expect(app.photoDuplicates.canAccessPhotos)
    }

    @Test("Stopping a photo scan holds the shared guard until the service returns")
    func cancellationAndNavigation() async throws {
        let service = HeldPhotoService()
        await service.holdScans()
        let app = makeApp(service)
        let photos = app.photoDuplicates
        await photos.requestAccess()
        photos.startScan()
        try await waitUntil { await service.pendingScans == 1 }
        app.view = .history
        #expect(photos.isScanning)
        #expect(app.isBusyWithDisk)
        #expect(app.storageExplorer.isMeasurementBlocked)
        app.cleanup.startScan()
        app.fileDuplicates.startScan(roots: [URL(fileURLWithPath: "/unused-photo-test")])
        app.uninstaller.planAppUninstall(URL(fileURLWithPath: "/unused-photo-test.app"))
        #expect(!app.cleanup.isScanning)
        #expect(!app.fileDuplicates.isScanning)
        #expect(!app.uninstaller.isPlanningAppUninstall)
        #expect(app.view == .history)

        photos.cancelScan()
        #expect(photos.isInterrupting)
        #expect(app.isBusyWithDisk)
        photos.startScan()
        #expect(await service.scanRequests == 1)
        await service.report(scan: 0, percent: 81)
        await service.finishScan(0, results: photoResults("cancelled"))
        try await waitUntil { !photos.isScanning }
        #expect(!photos.isInterrupting)
        #expect(!app.isBusyWithDisk)
        #expect(photos.results == nil)
        #expect(photos.progress == nil)

        photos.startScan()
        try await waitUntil { await service.pendingScans == 1 }
        #expect(app.view == .duplicates)
        app.view = .dashboard
        await service.report(scan: 1, percent: 32)
        try await waitUntil { photos.progress?.percent == 32 }
        await service.report(scan: 0, percent: 99)
        await service.finishScan(1, results: photoResults("current"))
        try await waitUntil { !photos.isScanning }
        #expect(photos.groups.first?.id == "current")
        #expect(photos.progress?.percent == 32)
        #expect(app.view == .dashboard)
        #expect(!app.isBusyWithDisk)
    }

    @Test("Another operation blocks photo scans and deletion")
    func otherOperationsBlockPhotos() async throws {
        let service = HeldPhotoService()
        let app = makeApp(service)
        let photos = app.photoDuplicates
        await photos.requestAccess()
        photos.startScan()
        try await waitUntil { !photos.isScanning }
        #expect(!photos.selection.isEmpty)
        _ = app.operations.begin(.cleanupScan)
        #expect(photos.isBusyWithDisk)
        photos.startScan()
        await photos.deleteSelected()
        #expect(!photos.isScanning)
        #expect(!photos.isDeleting)
        #expect(await service.scanRequests == 1)
        #expect(await service.deletedIDs.isEmpty)
        #expect(!photos.selection.isEmpty)
    }

    @Test("A replaced regroup cannot replace results or clear the current regroup")
    func replacedRegroup() async throws {
        let fixture = ModelFixture()
        let photos = fixture.model
        await photos.requestAccess()
        photos.startScan()
        try await waitUntil { !photos.isScanning }
        await fixture.service.holdRegroups()
        photos.similarity = .loose
        try await waitUntil { await fixture.service.pendingRegroups == 1 }
        photos.similarity = .strict
        try await waitUntil { await fixture.service.pendingRegroups == 2 }
        await fixture.service.finishRegroup(.loose, results: photoResults("old"))
        try await waitUntil { await fixture.service.returnedRegroups == 1 }
        #expect(photos.isRegrouping)
        #expect(photos.groups.first?.id == "initial")
        await fixture.service.finishRegroup(.strict, results: photoResults("new"))
        try await waitUntil { !photos.isRegrouping }
        #expect(photos.groups.first?.id == "new")
        #expect(photos.selection == ["new-copy"])
        #expect(fixture.defaults.string(forKey: "photoSimilarity") == PhotoSimilarity.strict.rawValue)
    }

    @Test("Revoked access rejects an unfinished scan and an unfinished regroup")
    func revocationDuringWork() async throws {
        let fixture = ModelFixture()
        let photos = fixture.model
        await photos.requestAccess()
        photos.startScan()
        try await waitUntil { !photos.isScanning }
        await fixture.service.holdRegroups()
        photos.similarity = .loose
        try await waitUntil { await fixture.service.pendingRegroups == 1 }
        await fixture.service.setAccess(.denied)
        await photos.requestAccess()
        #expect(!photos.isRegrouping)
        #expect(photos.results == nil)
        await fixture.service.finishRegroup(.loose, results: photoResults("revoked"))
        try await waitUntil { await fixture.service.returnedRegroups == 1 }
        #expect(photos.results == nil)
        #expect(photos.selection.isEmpty)

        await fixture.service.setAccess(.authorized)
        await photos.requestAccess()
        await fixture.service.holdScans()
        photos.startScan()
        try await waitUntil { await fixture.service.pendingScans == 1 }
        await fixture.service.setAccess(.restricted)
        await photos.requestAccess()
        #expect(photos.isInterrupting)
        #expect(photos.isBusyWithDisk)
        await fixture.service.finishScan(1, results: photoResults("revoked-scan"))
        try await waitUntil { !photos.isScanning }
        #expect(photos.results == nil)
        #expect(photos.selection.isEmpty)
        #expect(!photos.canAccessPhotos)
        #expect(!photos.isBusyWithDisk)
    }

    @Test("Photo deletion owns its task and publishes the completion before releasing the guard")
    func deletionLifetime() async throws {
        let service = HeldPhotoService()
        let app = makeApp(service)
        let photos = app.photoDuplicates
        await photos.requestAccess()
        photos.startScan()
        try await waitUntil { !photos.isScanning }
        await service.holdDeletion()
        let deletion = Task { await photos.deleteSelected() }
        try await waitUntil { await service.isDeletionPending }
        #expect(photos.isDeleting)
        #expect(app.isBusyWithDisk)
        #expect(app.storageExplorer.isMeasurementBlocked)
        #expect(app.removalCompletion == nil)
        await photos.deleteSelected()
        photos.startScan()
        #expect(await service.scanRequests == 1)
        #expect(await service.deletedIDs == ["initial-copy"])

        deletion.cancel()
        await service.finishDeletion()
        await deletion.value
        #expect(!photos.isDeleting)
        #expect(!app.isBusyWithDisk)
        #expect(photos.groups.isEmpty)
        #expect(photos.selection.isEmpty)
        #expect(app.removalCompletion?.title == "Moved to Recently Deleted")
        #expect(app.removalCompletion?.destination == .duplicates)
    }

    @Test("Declined deletion keeps the selection and releases the operation")
    func declinedDeletion() async throws {
        let service = HeldPhotoService()
        await service.declineDeletion()
        let app = makeApp(service)
        let photos = app.photoDuplicates
        await photos.requestAccess()
        photos.startScan()
        try await waitUntil { !photos.isScanning }
        let selected = photos.selection
        await photos.deleteSelected()
        #expect(photos.selection == selected)
        #expect(photos.groups.count == 1)
        #expect(!app.isBusyWithDisk)
        #expect(app.removalCompletion == nil)
        #expect(app.notice == nil)
    }

    @Test("Selection actions reject keepers and unknown assets")
    func selectionOwnership() async throws {
        let fixture = ModelFixture()
        let photos = fixture.model
        await photos.requestAccess()
        photos.startScan()
        try await waitUntil { !photos.isScanning }
        photos.deselectAll()
        photos.setSelected(true, assetID: "initial-keeper")
        photos.toggle("unknown")
        #expect(photos.selection.isEmpty)
        photos.toggleGroup("initial")
        #expect(photos.isGroupSelected("initial"))
        #expect(photos.selection == ["initial-copy"])
        var review = PhotoReviewState(highlightedID: "initial-copy")
        let order = photos.groups.first?.assets.map(\.id)
        photos.preview = .init(groupID: "initial", asset: try #require(photos.groups.first?.removable.first))
        photos.keepInstead(groupID: "initial", assetID: "initial-copy")
        review.update(groups: photos.groups)
        #expect(review.highlightedID == "initial-copy")
        #expect(photos.preview?.id == "initial-copy")
        #expect(photos.groups.first?.assets.map(\.id) == order)
        #expect(photos.groups.first?.keeper.id == "initial-copy")
        #expect(!photos.selection.contains("initial-copy"))
        photos.selectAll()
        #expect(photos.selection == ["initial-keeper"])
    }

    @Test("A delayed access request cannot replace revocation reported by a scan")
    func staleAccess() async throws {
        let fixture = ModelFixture()
        let photos = fixture.model
        await photos.requestAccess()
        await fixture.service.holdScans()
        photos.startScan()
        try await waitUntil { await fixture.service.pendingScans == 1 }
        await fixture.service.holdAccess()
        let access = Task { await photos.requestAccess() }
        try await waitUntil { await fixture.service.isAccessPending }
        await fixture.service.failScan(0, error: PhotoSweepUnavailable.access(.denied))
        try await waitUntil { !photos.isScanning }
        #expect(photos.libraryAccess == .denied)
        await fixture.service.finishAccess(.authorized)
        await access.value
        #expect(!photos.isRequestingAccess)
        #expect(photos.libraryAccess == .denied)
        #expect(!photos.canAccessPhotos)
        #expect(photos.results == nil)
    }

    @Test("New scans and image requests use the current download preference")
    func downloadPreference() async throws {
        let service = HeldPhotoService()
        var allowsNetwork = false
        var servicePreferences: [Bool] = []
        let photos = PhotoDuplicatesModel(
            operations: OperationCoordinator(),
            allowsNetworkFetch: { allowsNetwork },
            makeService: {
                servicePreferences.append($0)
                return service
            }
        )
        #expect(servicePreferences == [false])
        #expect(!photos.thumbnails.allowsNetworkFetch())
        await photos.requestAccess()
        allowsNetwork = true
        photos.startScan()
        try await waitUntil { !photos.isScanning }
        #expect(servicePreferences == [false, true])
        #expect(photos.thumbnails.allowsNetworkFetch())
    }

    private func makeApp(_ service: HeldPhotoService) -> AppModel {
        let app = AppModel(makePhotoService: { _ in service })
        app.view = .duplicates
        app.duplicateKind = .photos
        return app
    }
}

@MainActor
private final class ModelFixture {
    let service = HeldPhotoService()
    let defaults: UserDefaults
    let model: PhotoDuplicatesModel
    private let suite = "PhotoDuplicatesModelTests.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(PhotoSimilarity.standard.rawValue, forKey: "photoSimilarity")
        let service = service
        model = PhotoDuplicatesModel(operations: OperationCoordinator(), defaults: defaults, makeService: { _ in service })
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

private func photoResults(_ id: String) -> PhotoDuplicateResults {
    PhotoDuplicateResults(
        groups: [DuplicateGroup(
            id: id, kind: .burst, keeper: PhotoAsset(id: "\(id)-keeper"),
            removable: [PhotoAsset(id: "\(id)-copy")]
        )],
        examinedCount: 2, skippedCount: 0, startedAt: Date(), finishedAt: Date()
    )
}

private actor HeldPhotoService: PhotoDuplicatesServicing {
    private var access = PhotoLibraryAccess.authorized
    private(set) var accessRequests = 0
    private(set) var scanRequests = 0
    private(set) var returnedRegroups = 0
    private(set) var deletedIDs: [String] = []
    private var holdsScans = false
    private var holdsRegroups = false
    private var holdsDeletion = false
    private var declinesDeletion = false
    private var holdsAccess = false
    private var accessRequest: CheckedContinuation<PhotoLibraryAccess, Never>?
    private var scans: [Int: CheckedContinuation<PhotoDuplicateResults, any Error>] = [:]
    private var reports: [Int: @Sendable (PhotoDuplicateService.Progress) -> Void] = [:]
    private var regroups: [PhotoSimilarity: CheckedContinuation<PhotoDuplicateResults, Never>] = [:]
    private var deletion: CheckedContinuation<Void, Never>?
    var pendingScans: Int { scans.count }
    var pendingRegroups: Int { regroups.count }
    var isDeletionPending: Bool { deletion != nil }
    var isAccessPending: Bool { accessRequest != nil }

    func holdScans() { holdsScans = true }
    func holdRegroups() { holdsRegroups = true }
    func holdDeletion() { holdsDeletion = true }
    func declineDeletion() { declinesDeletion = true }
    func holdAccess() { holdsAccess = true }
    func setAccess(_ access: PhotoLibraryAccess) { self.access = access }

    func requestAccess() async -> PhotoLibraryAccess {
        accessRequests += 1
        if holdsAccess { return await withCheckedContinuation { accessRequest = $0 } }
        return access
    }

    func finishAccess(_ access: PhotoLibraryAccess) {
        accessRequest?.resume(returning: access)
        accessRequest = nil
    }

    func sweep(
        minimumAssets: Int, similarity: PhotoSimilarity,
        onProgress: (@Sendable (PhotoDuplicateService.Progress) -> Void)?
    ) async throws -> PhotoDuplicateResults {
        let index = scanRequests
        scanRequests += 1
        reports[index] = onProgress
        if holdsScans {
            return try await withCheckedThrowingContinuation { scans[index] = $0 }
        }
        return photoResults("initial")
    }

    func report(scan: Int, percent: Int) {
        reports[scan]?(.init(stage: .fingerprinting, percent: percent))
    }

    func finishScan(_ index: Int, results: PhotoDuplicateResults) {
        scans.removeValue(forKey: index)?.resume(returning: results)
    }

    func failScan(_ index: Int, error: any Error) {
        scans.removeValue(forKey: index)?.resume(throwing: error)
    }

    func regroup(
        similarity: PhotoSimilarity,
        onProgress: (@Sendable (PhotoDuplicateService.Progress) -> Void)?
    ) async throws -> PhotoDuplicateResults? {
        guard holdsRegroups else { return photoResults("regrouped") }
        let result = await withCheckedContinuation { regroups[similarity] = $0 }
        returnedRegroups += 1
        return result
    }

    func finishRegroup(_ similarity: PhotoSimilarity, results: PhotoDuplicateResults) {
        regroups.removeValue(forKey: similarity)?.resume(returning: results)
    }

    func delete(assetIDs: [String]) async throws {
        if declinesDeletion { throw CancellationError() }
        deletedIDs = assetIDs
        if holdsDeletion { await withCheckedContinuation { deletion = $0 } }
    }

    func finishDeletion() {
        deletion?.resume()
        deletion = nil
    }
}
