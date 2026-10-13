import Foundation

/// The sealed snapshot macOS is running from.
public struct BootSnapshotIdentity: Sendable, Equatable {
    public let uuid: String
    public let name: String
    /// The sealed System volume, such as `disk3s1`.
    public let systemVolumeDisk: String
}

/// A snapshot shown as information in the Dashboard.
public struct SnapshotInfo: Sendable, Equatable, Identifiable {
    public var uuid: String
    public var name: String
    public var purgeable: Bool
    public var limitingContainerShrink: Bool
    /// True for the sealed volume macOS booted from. Rendered as the Dashboard's
    /// permanent "this is macOS itself, not reclaimable space" row.
    public var isBootSnapshot: Bool
    /// The volume it was enumerated from, verbatim. Never rewritten.
    public var volumeDisk: String

    public var id: String { uuid }

    /// Creates snapshot information for views and previews.
    public init(
        uuid: String,
        name: String,
        purgeable: Bool,
        limitingContainerShrink: Bool,
        isBootSnapshot: Bool,
        volumeDisk: String
    ) {
        self.uuid = uuid
        self.name = name
        self.purgeable = purgeable
        self.limitingContainerShrink = limitingContainerShrink
        self.isBootSnapshot = isBootSnapshot
        self.volumeDisk = volumeDisk
    }
}

/// Lists snapshots for the Dashboard.
public struct SnapshotService: Sendable {

    private let runner: ProcessRunner
    private let diskInfo: DiskInfoService

    public init(runner: ProcessRunner = ProcessRunner(), diskInfo: DiskInfoService? = nil) {
        self.runner = runner
        self.diskInfo = diskInfo ?? DiskInfoService(runner: runner)
    }

    // MARK: - Listing

    /// Lists Data volume snapshots and identifies the boot snapshot.
    public func listAll() async throws -> [SnapshotInfo] {
        let boot = try? await diskInfo.bootSnapshot()
        let data = try await runner.run(
            SystemExecutable.diskutil,
            ["apfs", "listSnapshots", "-plist", DiskInfoService.dataVolumeMountPoint]
        )
        let volumeDisk = try await dataVolumeIdentifier()
        var results = Self.parse(data, volumeDisk: volumeDisk, bootUUID: boot?.uuid)

        if let boot {
            results.append(SnapshotInfo(
                uuid: boot.uuid,
                name: boot.name,
                purgeable: false,
                limitingContainerShrink: true,
                isBootSnapshot: true,
                volumeDisk: boot.systemVolumeDisk
            ))
        }
        return results
    }

    // MARK: - Internals

    private func dataVolumeIdentifier() async throws -> String {
        let data = try await runner.run(
            SystemExecutable.diskutil, ["info", "-plist", DiskInfoService.dataVolumeMountPoint]
        )
        return try DiskInfoService.decodeInfo(data).deviceIdentifier ?? ""
    }

    // MARK: - Parsing

    private struct SnapshotList: Decodable {
        var snapshots: [Entry]
        enum CodingKeys: String, CodingKey { case snapshots = "Snapshots" }

        struct Entry: Decodable {
            var uuid: String
            var name: String
            var purgeable: Bool?
            var limitingContainerShrink: Bool?
            enum CodingKeys: String, CodingKey {
                case uuid = "SnapshotUUID"
                case name = "SnapshotName"
                case purgeable = "Purgeable"
                case limitingContainerShrink = "LimitingContainerShrink"
            }
        }
    }

    static func parse(_ data: Data, volumeDisk: String, bootUUID: String?) -> [SnapshotInfo] {
        guard let list = try? PropertyListDecoder().decode(SnapshotList.self, from: data) else {
            return []
        }
        return list.snapshots.map { entry in
            SnapshotInfo(
                uuid: entry.uuid,
                name: entry.name,
                purgeable: entry.purgeable ?? false,
                limitingContainerShrink: entry.limitingContainerShrink ?? false,
                // Defence in depth: if the boot snapshot were ever returned by a
                // Data-volume listing, it is still flagged and never deletable.
                isBootSnapshot: bootUUID != nil && entry.uuid == bootUUID,
                volumeDisk: volumeDisk
            )
        }
    }
}
