import Foundation

/// Semantic colour names. Core stays free of SwiftUI; the design system maps these
/// to `NSColor`/`Color`, preferring the platform's semantic colours so the app
/// follows the user's accent choice and Increase Contrast setting.
public enum ColorToken: String, Sendable, Equatable, Codable {
    case accent, green, orange, red, yellow, purple, teal, pink, brown, indigo
    case gray, warmGray, darkGray, freeSpace
}

public enum StorageSegmentID: String, Sendable, CaseIterable, Codable {
    case macOSSystem, systemData
    case documentsDesktop, downloads, photos, music, movies, developer
    case appDataCaches, packageBuildCaches, otherFilesInHome
    case applications
    /// Physical usage when category measurements exceed the used space.
    case used
    case unmeasured
    /// Slivers merged together so the capacity bar has no unreadable hairlines.
    case other
    case free

    /// Merge the retired category when reading saved measurements.
    static func storedID(_ value: String) -> Self? {
        value == "appleIntelligence" ? .macOSSystem : Self(rawValue: value)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let id = Self.storedID(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown storage category: \(value)")
        }
        self = id
    }

    public var displayName: String {
        switch self {
        case .macOSSystem:        "macOS System"
        case .systemData:         "System Data"
        case .documentsDesktop:   "Documents & Desktop"
        case .downloads:          "Downloads"
        case .photos:             "Photos & Images"
        case .music:              "Music"
        case .movies:             "Movies & TV"
        case .developer:          "Developer"
        case .appDataCaches:      "App Data & Caches"
        case .packageBuildCaches: "Package & Build Caches"
        case .otherFilesInHome:   "Other Files in Home"
        case .applications:       "Applications"
        case .used:               "Used"
        case .unmeasured:         "Unmeasured"
        case .other:              "Other"
        case .free:               "Free"
        }
    }

    public var color: ColorToken {
        switch self {
        case .macOSSystem:        .gray
        case .systemData:         .warmGray
        case .documentsDesktop:   .orange
        case .downloads:          .green
        case .photos:             .pink
        case .music:              .purple
        case .movies:             .red
        case .developer:          .yellow
        case .appDataCaches:      .teal
        case .packageBuildCaches: .purple
        // Brown, not pink: Photos & Images is pink, and the two sat side by side
        // in the legend wearing the same dot.
        case .otherFilesInHome:   .brown
        case .applications:       .accent
        case .used:               .gray
        case .unmeasured:         .darkGray
        case .other:              .gray
        case .free:               .freeSpace
        }
    }

    /// `Unmeasured` and `Free` are never folded into `Other`, however small.
    ///
    /// Hiding `Unmeasured` is what made the predecessor's numbers look plausible
    /// while being wrong: unattributed space was relabelled twice — first as "APFS
    /// Snapshots", then as "Other User Accounts" — and both were fabrications. It is
    /// the honest residual and it stays visible.
    var isMergeable: Bool {
        switch self {
        case .unmeasured, .free, .other, .used: false
        default: true
        }
    }
}

/// Lets a `[StorageSegmentID: Int64]` table encode as a JSON object.
///
/// Without this conformance the standard library writes a dictionary with a
/// non-`String` key as a flat array of alternating keys and values. It round-trips
/// correctly either way, but a stored measurement is a record the user can open and
/// read, and `{"downloads": 21548...}` is that record; `["downloads", 21548...]` is
/// a puzzle.
extension StorageSegmentID: CodingKeyRepresentable {}

public struct StorageSegment: Sendable, Equatable, Identifiable, Codable {
    public let id: StorageSegmentID
    public var bytes: Int64

    public var displayName: String { id.displayName }
    public var color: ColorToken { id.color }

    public init(id: StorageSegmentID, bytes: Int64) {
        self.id = id
        self.bytes = bytes
    }
}

/// A complete account of a volume: every byte of capacity lands in exactly one
/// segment, including free space and the unattributed remainder.
public struct StorageBreakdown: Sendable, Equatable, Codable {
    public let capacityBytes: Int64
    /// Descending by size, `Other` and `Free` last.
    public let segments: [StorageSegment]
    /// Entries an unprivileged scan could not read, summed across the run.
    public let unreadableCount: Int
    /// Keeps category measurements separate when they exceed physical usage.
    public let categorySegments: [StorageSegment]?

    public init(
        capacityBytes: Int64,
        segments: [StorageSegment],
        unreadableCount: Int,
        categorySegments: [StorageSegment]? = nil
    ) {
        self.capacityBytes = capacityBytes
        self.segments = segments
        self.unreadableCount = unreadableCount
        self.categorySegments = categorySegments
    }

    private enum CodingKeys: String, CodingKey {
        case capacityBytes, segments, unreadableCount, categorySegments
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        capacityBytes = try values.decode(Int64.self, forKey: .capacityBytes)
        unreadableCount = try values.decode(Int.self, forKey: .unreadableCount)
        categorySegments = try values.decodeIfPresent([StorageSegment].self, forKey: .categorySegments)
        var saved = try values.decode([StorageSegment].self, forKey: .segments)
        // The encoder stores Used as Unmeasured. Restore it when category measurements are present.
        if categorySegments != nil {
            saved = saved.map { $0.id == .unmeasured ? StorageSegment(id: .used, bytes: $0.bytes) : $0 }
        }
        var merged: [StorageSegment] = []
        for segment in saved {
            if let index = merged.firstIndex(where: { $0.id == segment.id }) {
                merged[index].bytes += segment.bytes
            } else {
                merged.append(segment)
            }
        }
        segments = merged.count == saved.count ? saved : Self.make(
            capacityBytes: capacityBytes,
            rawSegments: Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0.bytes) }),
            unreadableCount: unreadableCount,
            mergeThresholdPercent: 0
        ).segments
    }

    /// Stores Used as Unmeasured. Earlier builds do not know Used and cannot read it.
    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(capacityBytes, forKey: .capacityBytes)
        try values.encode(segments.map {
            $0.id == .used ? StorageSegment(id: .unmeasured, bytes: $0.bytes) : $0
        }, forKey: .segments)
        try values.encode(unreadableCount, forKey: .unreadableCount)
        try values.encodeIfPresent(categorySegments, forKey: .categorySegments)
    }

    public var usedBytes: Int64 { capacityBytes - freeBytes }
    public var freeBytes: Int64 { segments.first { $0.id == .free }?.bytes ?? 0 }

    /// Whether every byte of capacity lands in exactly one segment.
    ///
    /// The capacity card's one contract, stated as a value the code can test. The
    /// CLI harness prints the same figure as `drift`, and drift must be 0 bytes.
    /// A measurement that fails this is refused as a growth baseline: a comparison
    /// against a breakdown that does not add up subtracts two different accounts of
    /// the disk and calls the difference growth.
    public var isConsistent: Bool {
        guard capacityBytes > 0, Self.total(segments) == capacityBytes else { return false }
        guard let categorySegments else { return !segments.contains { $0.id == .used } }
        guard let categoryBytes = Self.total(categorySegments), categoryBytes > usedBytes,
              categorySegments.allSatisfy({ $0.id != .used && $0.id != .free && $0.id != .unmeasured })
        else { return false }
        return segments.allSatisfy { $0.id == .used || $0.id == .free }
    }

    private static func total(_ segments: [StorageSegment]) -> Int64? {
        guard Set(segments.map(\.id)).count == segments.count else { return nil }
        var total: Int64 = 0
        for segment in segments {
            guard segment.bytes >= 0 else { return nil }
            let sum = total.addingReportingOverflow(segment.bytes)
            guard !sum.overflow else { return nil }
            total = sum.partialValue
        }
        return total
    }

    public var allocationExcessBytes: Int64 {
        guard let categorySegments, let total = Self.total(categorySegments) else { return 0 }
        return max(0, total - usedBytes)
    }

    /// Category measurements can exceed physical usage. Their values remain unchanged.
    public var legendEntries: [StorageSegment] {
        (categorySegments ?? segments).filter { $0.bytes > 0 }
    }

    public func percent(of segment: StorageSegment) -> Double {
        guard capacityBytes > 0 else { return 0 }
        return Double(segment.bytes) / Double(capacityBytes) * 100
    }

    /// Keeps physical volume figures separate from category measurements.
    /// Category measurements remain unchanged when their sum exceeds physical usage.
    public func reconcilingVolume(
        capacityBytes newCapacityBytes: Int64,
        freeBytes requestedFreeBytes: Int64
    ) -> StorageBreakdown {
        let capacity = max(0, newCapacityBytes)
        let namedSegments = (categorySegments ?? segments).filter {
            $0.id != .free && $0.id != .unmeasured && $0.id != .used
        }
        guard let namedBytes = Self.total(namedSegments) else { return self }

        // Keep the earlier measurement when capacity changes below the category total.
        guard capacity == capacityBytes || namedBytes <= capacity else { return self }

        let freeBytes = min(max(0, requestedFreeBytes), capacity)
        let usedBytes = capacity - freeBytes
        if namedBytes > usedBytes {
            return StorageBreakdown(
                capacityBytes: capacity,
                segments: [StorageSegment(id: .used, bytes: usedBytes), StorageSegment(id: .free, bytes: freeBytes)],
                unreadableCount: unreadableCount,
                categorySegments: namedSegments
            )
        }
        let unmeasuredBytes = usedBytes - namedBytes

        var rawSegments = Dictionary(
            uniqueKeysWithValues: namedSegments.map { ($0.id, $0.bytes) }
        )
        rawSegments[.unmeasured] = unmeasuredBytes
        rawSegments[.free] = freeBytes

        // The measured categories have already been merged. A zero threshold keeps
        // them stable while the volatile figures change.
        return StorageBreakdown.make(
            capacityBytes: capacity,
            rawSegments: rawSegments,
            unreadableCount: unreadableCount,
            mergeThresholdPercent: 0
        )
    }

    /// Builds a breakdown from raw per-segment byte counts.
    ///
    /// Segments smaller than `mergeThresholdPercent` of capacity are folded into
    /// `Other` so the capacity bar never renders an illegible sliver.
    public static func make(
        capacityBytes: Int64,
        rawSegments: [StorageSegmentID: Int64],
        unreadableCount: Int,
        mergeThresholdPercent: Double = 0.5
    ) -> StorageBreakdown {
        let threshold = Int64(Double(capacityBytes) * mergeThresholdPercent / 100)

        var kept: [StorageSegment] = []
        var mergedBytes: Int64 = 0

        for (id, bytes) in rawSegments where bytes > 0 {
            if id.isMergeable && bytes < threshold {
                mergedBytes += bytes
            } else {
                kept.append(StorageSegment(id: id, bytes: bytes))
            }
        }

        kept.sort { lhs, rhs in
            // Free always renders last in the bar and legend.
            if lhs.id == .free { return false }
            if rhs.id == .free { return true }
            return lhs.bytes > rhs.bytes
        }
        if mergedBytes > 0 {
            let freeIndex = kept.firstIndex { $0.id == .free } ?? kept.endIndex
            kept.insert(StorageSegment(id: .other, bytes: mergedBytes), at: freeIndex)
        }

        return StorageBreakdown(
            capacityBytes: capacityBytes,
            segments: kept,
            unreadableCount: unreadableCount
        )
    }
}
