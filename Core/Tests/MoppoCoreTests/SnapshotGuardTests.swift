import Foundation
import Testing
@testable import MoppoCore

/// Fixtures are real `diskutil -plist` output recorded from the development machine,
/// so parsing is tested against the actual format rather than an idealised one.
enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        return try Data(contentsOf: url)
    }
}

@Suite("diskutil plist parsing")
struct DiskUtilParsingTests {

    @Test("root volume info decodes container capacity, not volume capacity")
    func rootVolumeInfo() throws {
        let info = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-root.plist"))
        let volume = DiskInfoService.volumeInfo(from: info)

        #expect(volume.name == "Macintosh HD")
        #expect(volume.filesystem == "apfs")
        #expect(volume.isEncrypted)
        // The Dashboard hero compares against container capacity — 228.27 GB.
        #expect(volume.capacityBytes == 245_107_195_904)
        #expect(volume.freeBytes > 0)
        #expect(volume.usedBytes == volume.capacityBytes - volume.freeBytes)
    }

    @Test("the eyebrow string matches the design")
    func eyebrow() throws {
        let info = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-root.plist"))
        #expect(DiskInfoService.volumeInfo(from: info).eyebrow == "Macintosh HD · APFS · Encrypted")
    }

    @Test("the Data volume reports its own usage, distinct from the container")
    func dataVolumeUsage() throws {
        let root = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-root.plist"))
        let data = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-data.plist"))

        // The System volume is small; the Data volume holds nearly everything. The
        // difference is what "macOS System" is derived from.
        #expect(data.capacityInUse! > root.capacityInUse!)
    }
}

@Suite("Snapshot information")
struct SnapshotGuardTests {

    private func bootIdentity() throws -> BootSnapshotIdentity {
        let info = try DiskInfoService.decodeInfo(Fixture.data("diskutil-info-root.plist"))
        return try #require(DiskInfoService.bootSnapshot(from: info))
    }

    @Test("the boot snapshot is identified from the root volume")
    func identifiesBootSnapshot() throws {
        let boot = try bootIdentity()
        #expect(boot.uuid == "D5D09086-4626-4187-B4B0-286AA2C52889")
        #expect(boot.name.hasPrefix("com.apple.os.update-"))
        // disk3s1s1 (the snapshot volume) reduces to disk3s1 (the sealed System
        // volume). Recorded to refuse deletes — never to target one.
        #expect(boot.systemVolumeDisk == "disk3s1")
    }

    @Test("an empty Data volume yields no snapshot rows")
    func emptyDataVolume() throws {
        let parsed = SnapshotService.parse(
            try Fixture.data("snapshots-data-empty.plist"),
            volumeDisk: "disk3s5",
            bootUUID: try bootIdentity().uuid
        )
        #expect(parsed.isEmpty)
    }

    @Test("the boot snapshot is identified in the snapshot listing")
    func identifiesBootSnapshotInListing() throws {
        let boot = try bootIdentity()
        // Exactly what `diskutil apfs listSnapshots /` returns — the trap the old
        // code walked into.
        let listed = SnapshotService.parse(
            try Fixture.data("snapshots-root-boot.plist"),
            volumeDisk: boot.systemVolumeDisk,
            bootUUID: boot.uuid
        )
        let entry = try #require(listed.first)
        #expect(entry.isBootSnapshot)

        #expect(entry.volumeDisk == boot.systemVolumeDisk)
    }
}
