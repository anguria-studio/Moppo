import Foundation
import Testing
@testable import MoppoCore

@Suite("Photo access and content recovery")
struct PhotoRecoveryTests {
    private actor Library: PhotoLibraryProviding {
        var access: PhotoLibraryAccess = .authorized
        var revokeDuringFetch = false
        var revokeDuringFingerprint = false
        var offline = false
        var failFetch = false
        var reads = 0
        var deletions = 0

        func configure(
            access: PhotoLibraryAccess = .authorized, revokeDuringFetch: Bool = false,
            revokeDuringFingerprint: Bool = false, offline: Bool = false, failFetch: Bool = false
        ) {
            self.access = access
            self.revokeDuringFetch = revokeDuringFetch
            self.revokeDuringFingerprint = revokeDuringFingerprint
            self.offline = offline
            self.failFetch = failFetch
        }

        func authorize() async -> PhotoLibraryAccess { access }
        func fetchAssets() async throws -> [PhotoAsset] {
            reads += 1
            if failFetch { throw CocoaError(.fileReadUnknown) }
            if revokeDuringFetch { access = .denied }
            return ["a", "b"].map {
                PhotoAsset(id: $0, creationDate: Date(timeIntervalSince1970: 100), pixelWidth: 100, pixelHeight: 100)
            }
        }
        func fingerprint(assetID: String) async -> PhotoFingerprint? {
            if revokeDuringFingerprint { access = .denied }
            return offline ? nil : PhotoFingerprint(vector: [0, 0])
        }
        func delete(assetIDs: [String]) async throws { deletions += 1 }
    }

    private func service(_ library: Library, cache: URL) -> PhotoDuplicateService {
        PhotoDuplicateService(library: library, visionRevision: 2, cacheDirectory: cache)
    }

    @Test("Denied access prevents reads and deletion, then permits a new scan", arguments: [
        PhotoLibraryAccess.denied, .restricted, .limited
    ])
    func deniedAccessRecovery(access: PhotoLibraryAccess) async throws {
        let library = Library()
        await library.configure(access: access)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = service(library, cache: cache)
        await #expect(throws: PhotoSweepUnavailable.access(access)) { try await service.sweep() }
        await #expect(throws: PhotoSweepUnavailable.access(access)) { try await service.delete(assetIDs: ["a"]) }
        #expect(await library.reads == 0)
        #expect(await library.deletions == 0)
        #expect(await service.isSweeping == false)

        await library.configure()
        #expect(try await service.sweep().groups.count == 1)
    }

    @Test("Access revoked during a scan prevents results and permits retry", arguments: [false, true])
    func revokedDuringScan(duringFingerprint: Bool) async throws {
        let library = Library()
        await library.configure(revokeDuringFetch: !duringFingerprint, revokeDuringFingerprint: duringFingerprint)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = service(library, cache: cache)
        await #expect(throws: PhotoSweepUnavailable.access(.denied)) { try await service.sweep() }
        #expect(await service.isSweeping == false)
        #expect(try await service.regroup(similarity: .standard) == nil)

        await library.configure()
        #expect(try await service.sweep().groups.count == 1)
    }

    @Test("Unavailable thumbnails remain unexamined and can be read on retry")
    func offlineRecovery() async throws {
        let library = Library()
        await library.configure(offline: true)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = service(library, cache: cache)
        let offline = try await service.sweep()
        #expect(offline.skippedCount == 2)
        #expect(offline.groups.isEmpty)
        #expect(await service.isSweeping == false)

        await library.configure()
        let online = try await service.sweep()
        #expect(online.skippedCount == 0)
        #expect(online.groups.count == 1)
    }

    @Test("A failed library read releases the scan and permits retry")
    func readFailureRecovery() async throws {
        let library = Library()
        await library.configure(failFetch: true)
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = service(library, cache: cache)
        await #expect(throws: CocoaError.self) { try await service.sweep() }
        #expect(await service.isSweeping == false)
        await library.configure()
        #expect(try await service.sweep().groups.count == 1)
    }
}
