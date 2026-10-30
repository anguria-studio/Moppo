import Foundation

/// Stores private reports. Stored data never authorizes removal.
public struct ScanStore: Sendable {
    public let directory: URL
    public typealias StoreError = RecordStoreError

    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Moppo/cli-scans")) {
        self.directory = directory
    }

    public static func validId(_ id: String, prefix: String) -> Bool {
        PrivateRecordStore<ScanReport>.validId(id, prefix: prefix)
    }

    /// Reports in `keeping` remain in addition to the ten newest reports.
    public func save(_ report: ScanReport, now: Date = Date(), keeping: Set<String> = []) throws {
        try PrivateRecordStore<ScanReport>(directory: directory).save(report, now: now, keeping: keeping)
    }

    public func load(_ id: String, now: Date = Date()) throws -> ScanReport {
        try loadWithRevision(id, now: now).report
    }

    /// Calculates the revision from the stored bytes. This does not encode the report again.
    public func loadWithRevision(_ id: String, now: Date = Date()) throws -> (report: ScanReport, revision: String) {
        let loaded = try PrivateRecordStore<ScanReport>(directory: directory).loadWithRevision(id, now: now)
        return (loaded.record, loaded.revision)
    }
}

extension ScanReport: PrivateRecord {
    static var currentSchemaVersion: Int { schemaVersion }
    static let prefix = "scan_"
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static let retainedCount = 10
    static let maximumBytes = 64 * 1024 * 1024
    var recordId: String { scanId }
    var recordDate: Date { finishedAt }
    var isValid: Bool {
        guard finishedAt >= startedAt, expiresAt > finishedAt,
              Set(items.map(\.id)).count == items.count,
              items.allSatisfy({ ScanStore.validId($0.id, prefix: "item_") && $0.allocatedBytes >= 0 && $0.displayBytes >= 0 })
        else { return false }
        // Parents must precede children. This also rejects cycles and unknown parents.
        var preceding: Set<String> = []
        for item in items {
            if let parent = item.parentId, !preceding.contains(parent) { return false }
            preceding.insert(item.id)
        }
        return true
    }
}
