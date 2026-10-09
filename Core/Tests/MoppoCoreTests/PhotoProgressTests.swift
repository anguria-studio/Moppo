import Foundation
import Testing
@testable import MoppoCore

@Suite("Photo scan progress")
struct PhotoProgressTests {
    @Test("A large date group reports intermediate comparison progress")
    func progressWithinOneGroup() {
        let fixture = PhotoProgressFixture(count: 1_000)
        let progress = PhotoProgressLog()
        let graph = fixture.build(progress: progress)

        #expect(graph.edgeCount == 0)
        #expect(graph.fingerprinted.count == fixture.assets.count)
        #expect(progress.values.contains { $0 > 0 && $0 < 1 })
        #expect(progress.values.last == 1)
        #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 < $1 })
        #expect(progress.values.count <= 101)
    }

    @Test("Progress remains ordered across unequal date groups")
    func multipleGroups() {
        let fixture = PhotoProgressFixture(count: 1_000, splitAfter: 100)
        let progress = PhotoProgressLog()
        _ = fixture.build(progress: progress)

        #expect(progress.values.contains { $0 > 0.1 && $0 < 0.9 })
        #expect(progress.values.last == 1)
        #expect(zip(progress.values, progress.values.dropFirst()).allSatisfy { $0 < $1 })
        #expect(progress.values.count <= 101)
    }

    @Test("Cancellation during a date group does not report complete comparison")
    func cancellationWithinGroup() {
        let fixture = PhotoProgressFixture(count: 1_000)
        let progress = PhotoProgressLog(cancelAt: 0.1)
        _ = fixture.build(progress: progress)

        #expect(progress.wasCancelled)
        #expect(!progress.values.isEmpty)
        #expect(progress.values.allSatisfy { $0 < 1 })
    }

    @Test("An empty comparison completes without invalid progress", arguments: [0, 1])
    func noPairs(count: Int) {
        let fixture = PhotoProgressFixture(count: count)
        let progress = PhotoProgressLog()
        _ = fixture.build(progress: progress)

        #expect(progress.values.last == 1)
        #expect(progress.values.allSatisfy { $0.isFinite && (0...1).contains($0) })
    }

    @Test("Cached and uncached scans report comparison separately from burst grouping", arguments: [false, true])
    func scanStages(cached: Bool) async throws {
        let fixture = PhotoProgressFixture(count: 300)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        if cached {
            FingerprintCache(visionRevision: 2, elementCount: 4, prints: fixture.prints).save(in: directory)
        }
        let progress = ScanProgressLog()
        let library = ProgressLibrary(fixture: fixture, progress: progress)
        let service = PhotoDuplicateService(library: library, visionRevision: 2, cacheDirectory: directory)
        _ = try await service.sweep(similarity: .identicalOnly, onProgress: { progress.record($0) })

        let events = progress.values
        let comparisons = events.filter { $0.stage == .comparing }
        #expect(Set(comparisons.map(\.percent)).count > 2)
        #expect(comparisons.first?.total == fixture.assets.count)
        #expect(comparisons.first?.fromCache == (cached ? fixture.assets.count : 0))
        #expect(events.filter { $0.stage == .grouping }.allSatisfy { $0.percent < 10 })
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.percent <= $1.percent })
        #expect(events.filter { $0.percent == 100 }.map(\.stage) == [.done])
        #expect(events.last?.stage == .done)
        #expect(await library.fingerprintRequests == (cached ? 0 : fixture.assets.count))
        #expect(await library.progressAtFinalAccess.last?.stage == .finishing)
        #expect(await library.progressAtFinalAccess.allSatisfy { $0.percent < 100 })
    }

    @Test("A failed final access check does not report a completed scan")
    func accessFailureBeforeCompletion() async throws {
        let fixture = PhotoProgressFixture(count: 100)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let progress = ScanProgressLog()
        let library = ProgressLibrary(fixture: fixture, progress: progress, finalAccess: .denied)
        let service = PhotoDuplicateService(library: library, visionRevision: 2, cacheDirectory: directory)

        await #expect(throws: PhotoSweepUnavailable.access(.denied)) {
            try await service.sweep(onProgress: { progress.record($0) })
        }
        #expect(progress.values.last?.stage == .finishing)
        #expect(progress.values.allSatisfy { $0.percent < 100 && $0.stage != .done })
    }
}

private struct PhotoProgressFixture {
    let assets: [PhotoAsset]
    let prints: [String: PhotoFingerprint]

    init(count: Int, splitAfter: Int? = nil) {
        assets = (0..<count).map { index in
            let seconds = splitAfter.map { index < $0 ? 100.0 : 86_500.0 } ?? 100.0
            return PhotoAsset(id: "fixture-\(index)", creationDate: Date(timeIntervalSince1970: seconds))
        }
        prints = Dictionary(uniqueKeysWithValues: assets.enumerated().map { index, asset in
            (asset.id, PhotoFingerprint(vector: [Float(index), 0, 0, 0]))
        })
    }

    func build(progress: PhotoProgressLog) -> PhotoNeighbourGraph {
        PhotoNeighbourGraph.build(
            assets: assets, fingerprints: prints, bucketInterval: 86_400, ceiling: PhotoSimilarity.ceiling,
            isCancelled: { progress.wasCancelled }, onProgress: { progress.record($0) }
        )
    }
}

private final class PhotoProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    private var cancelled = false
    private let cancelAt: Double?

    init(cancelAt: Double? = nil) { self.cancelAt = cancelAt }

    var values: [Double] { lock.withLock { recorded } }
    var wasCancelled: Bool { lock.withLock { cancelled } }

    func record(_ value: Double) {
        lock.withLock {
            recorded.append(value)
            if let cancelAt, value >= cancelAt { cancelled = true }
        }
    }
}

private final class ScanProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [PhotoDuplicateService.Progress] = []
    var values: [PhotoDuplicateService.Progress] { lock.withLock { recorded } }
    func record(_ value: PhotoDuplicateService.Progress) { lock.withLock { recorded.append(value) } }
}

private actor ProgressLibrary: PhotoLibraryProviding {
    let fixture: PhotoProgressFixture
    let progress: ScanProgressLog
    let finalAccess: PhotoLibraryAccess
    private var accessRequests = 0
    private(set) var fingerprintRequests = 0
    private(set) var progressAtFinalAccess: [PhotoDuplicateService.Progress] = []

    init(fixture: PhotoProgressFixture, progress: ScanProgressLog, finalAccess: PhotoLibraryAccess = .authorized) {
        self.fixture = fixture
        self.progress = progress
        self.finalAccess = finalAccess
    }

    func authorize() -> PhotoLibraryAccess {
        accessRequests += 1
        if accessRequests == 3 {
            progressAtFinalAccess = progress.values
            return finalAccess
        }
        return .authorized
    }

    func fetchAssets() -> [PhotoAsset] { fixture.assets }
    func fingerprint(assetID: String) -> PhotoFingerprint? {
        fingerprintRequests += 1
        return fixture.prints[assetID]
    }
    func delete(assetIDs: [String]) {}
}
