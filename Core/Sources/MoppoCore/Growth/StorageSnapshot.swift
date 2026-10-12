import Foundation

/// The rules a measurement was made under.
///
/// Two measurements are only subtractable if they were made the same way. The
/// predecessor compared whatever it had, which is how a rule change — a new root, a
/// different symlink policy — presented itself to the user as overnight growth. Here
/// the rules travel with the figures, and a comparison across a change is refused
/// rather than approximated.
public struct MeasurementContract: Codable, Sendable, Equatable {

    /// Raise this when any measurement rule changes: allocated size, hard-link
    /// deduplication, the symlink policy, the root tables, the node depth, or the
    /// node threshold. Snapshots written before the change then read as what they
    /// are — a different measurement — instead of being subtracted from a new one.
    public static let currentVersion = 3

    public let version: Int
    public let homePath: String
    public let volumeName: String
    public let capacityBytes: Int64
    /// How many levels below `$HOME` the walk recorded.
    public let nodeDepth: Int
    /// The smallest directory the snapshot keeps.
    public let minimumNodeBytes: Int64

    public init(
        version: Int = MeasurementContract.currentVersion,
        homePath: String,
        volumeName: String,
        capacityBytes: Int64,
        nodeDepth: Int,
        minimumNodeBytes: Int64
    ) {
        self.version = version
        self.homePath = homePath
        self.volumeName = volumeName
        self.capacityBytes = capacityBytes
        self.nodeDepth = nodeDepth
        self.minimumNodeBytes = minimumNodeBytes
    }

    /// Why two contracts cannot be compared, or `nil` when they can.
    ///
    /// Written for the Dashboard, so it is one short sentence in plain words.
    func incompatibility(with other: MeasurementContract) -> String? {
        if version != other.version
            || nodeDepth != other.nodeDepth
            || minimumNodeBytes != other.minimumNodeBytes {
            return "The measurement rules changed."
        }
        if homePath != other.homePath {
            return "The home folder changed."
        }
        if volumeName != other.volumeName || capacityBytes != other.capacityBytes {
            return "The volume changed."
        }
        return nil
    }
}

/// What caused a measurement to be stored.
///
/// `removal` is the load-bearing one: it marks the measurement taken straight after
/// a clean-up, which is the baseline the "since the last clean-up" report needs. The
/// retention rules below never thin it away.
public enum SnapshotTrigger: String, Codable, Sendable, CaseIterable {
    case launch
    case manual
    case scan
    case removal
    case scheduled
    case cli
}

/// One directory, as a stored measurement records it.
///
/// A node is a place whose bytes belong to exactly one capacity segment. `$HOME` is
/// therefore not a node: it holds Documents, Downloads, caches and application data
/// at once, and no single segment owns it. Its children are.
public struct SnapshotNode: Codable, Sendable, Equatable {
    /// Absolute and standardized, with no trailing slash — the same form
    /// `AllocatedSizeMeasurer` builds its attribution keys in.
    public let path: String
    /// `device:inode` at measurement time, from ``FileIdentity``.
    ///
    /// This is what makes a moved folder readable as a move instead of as growth in
    /// one place and a matching loss in another. `nil` when the directory could not
    /// be stat-ed; such a node simply never takes part in move detection.
    public let identity: String?
    public let allocatedBytes: Int64
    public let fileCount: Int
    /// Levels below `$HOME`. Machine-wide roots such as `/Applications` are 0.
    public let depth: Int
    /// The capacity segment these bytes are counted in.
    public let segment: StorageSegmentID

    public init(
        path: String,
        identity: String?,
        allocatedBytes: Int64,
        fileCount: Int,
        depth: Int,
        segment: StorageSegmentID
    ) {
        self.path = path
        self.identity = identity
        self.allocatedBytes = allocatedBytes
        self.fileCount = fileCount
        self.depth = depth
        self.segment = segment
    }
}

/// A dated measurement of the disk, kept so the next one has something to be
/// compared with.
///
/// It carries both the raw per-segment table and the breakdown built from it.
/// ``StorageBreakdown/make(capacityBytes:rawSegments:unreadableCount:mergeThresholdPercent:)``
/// folds any segment below half a percent of capacity into `Other`, so a segment can
/// cross that line between two measurements and produce a difference that is a
/// rendering artefact rather than a change on disk. The report subtracts
/// ``rawSegments``; the card displays ``breakdown``.
public struct StorageSnapshot: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let measuredAt: Date
    public let trigger: SnapshotTrigger
    public let contract: MeasurementContract
    public let volume: VolumeInfo
    /// Per-segment bytes before small segments were merged into `Other`.
    public let rawSegments: [StorageSegmentID: Int64]
    /// The same measurement as the capacity card shows it.
    public let breakdown: StorageBreakdown
    /// Every directory at or above the contract's threshold, largest first.
    public let nodes: [SnapshotNode]

    public var usedBytes: Int64 { volume.usedBytes }

    public init(
        id: UUID,
        measuredAt: Date,
        trigger: SnapshotTrigger,
        contract: MeasurementContract,
        volume: VolumeInfo,
        rawSegments: [StorageSegmentID: Int64],
        breakdown: StorageBreakdown,
        nodes: [SnapshotNode]
    ) {
        self.id = id
        self.measuredAt = measuredAt
        self.trigger = trigger
        self.contract = contract
        self.volume = volume
        self.rawSegments = rawSegments
        self.breakdown = breakdown
        self.nodes = nodes
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        measuredAt = try values.decode(Date.self, forKey: .measuredAt)
        trigger = try values.decode(SnapshotTrigger.self, forKey: .trigger)
        contract = try values.decode(MeasurementContract.self, forKey: .contract)
        volume = try values.decode(VolumeInfo.self, forKey: .volume)
        breakdown = try values.decode(StorageBreakdown.self, forKey: .breakdown)
        nodes = try values.decode([SnapshotNode].self, forKey: .nodes)
        let saved = try values.decode([String: Int64].self, forKey: .rawSegments)
        var merged: [StorageSegmentID: Int64] = [:]
        for (name, bytes) in saved {
            guard let segment = StorageSegmentID.storedID(name) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .rawSegments, in: values, debugDescription: "Unknown storage category: \(name)"
                )
            }
            merged[segment, default: 0] += bytes
        }
        rawSegments = merged
    }
}
