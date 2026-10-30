import Foundation

/// A proposal contains identifiers only. It never grants removal permission.
public struct CleanupPlan: Codable, Sendable {
    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let planId: String
    public let scanId: String
    public let scanRevision: String
    public let itemIds: [String]
    public let createdAt: Date
    public let expiresAt: Date

    init(scan: ScanReport, revision: String, itemIds: [String], now: Date) {
        schemaVersion = Self.schemaVersion
        planId = "plan_" + UUID().uuidString.lowercased()
        scanId = scan.scanId
        scanRevision = revision
        self.itemIds = itemIds.sorted()
        createdAt = now
        expiresAt = min(scan.expiresAt, now.addingTimeInterval(Self.lifetime))
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, planId, scanId, scanRevision, itemIds, createdAt, expiresAt
    }

    public init(from decoder: any Decoder) throws {
        struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        let keys = try decoder.container(keyedBy: Key.self).allKeys.map(\.stringValue)
        guard Set(keys) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw RecordStoreError.invalidReport
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        planId = try values.decode(String.self, forKey: .planId)
        scanId = try values.decode(String.self, forKey: .scanId)
        scanRevision = try values.decode(String.self, forKey: .scanRevision)
        itemIds = try values.decode([String].self, forKey: .itemIds)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        expiresAt = try values.decode(Date.self, forKey: .expiresAt)
    }
}

extension CleanupPlan: PrivateRecord {
    static var currentSchemaVersion: Int { schemaVersion }
    static let prefix = "plan_"
    static let lifetime: TimeInterval = 24 * 60 * 60
    static let retainedCount = 20
    static let maximumBytes = 64 * 1024
    var recordId: String { planId }
    var recordDate: Date { createdAt }
    var isValid: Bool {
        schemaVersion == Self.schemaVersion && ScanStore.validId(scanId, prefix: "scan_")
            && RecordDigest.isValid(scanRevision) && !itemIds.isEmpty && itemIds.count <= 500
            && Set(itemIds).count == itemIds.count
            && itemIds.allSatisfy { ScanStore.validId($0, prefix: "item_") }
            && expiresAt > createdAt
    }
}

public struct PlanStore: Sendable {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Moppo/cleanup-plans")) {
        self.directory = directory
    }

    func save(_ plan: CleanupPlan, now: Date) throws {
        do { try PrivateRecordStore<CleanupPlan>(directory: directory).save(plan, now: now) }
        catch { throw RecordStoreError.writeFailed }
    }

    public func load(_ id: String, now: Date = Date()) throws -> CleanupPlan {
        try PrivateRecordStore<CleanupPlan>(directory: directory).load(id, now: now)
    }

    /// Scans that unexpired plans use. Scan pruning keeps these reports.
    public func referencedScanIds(now: Date = Date()) -> Set<String> {
        guard let plans = try? PrivateRecordStore<CleanupPlan>(directory: directory).records(now: now) else { return [] }
        return Set(plans.map(\.scanId))
    }

    public func invalidate(_ id: String, revision: String, now: Date = Date()) throws {
        try PrivateRecordStore<CleanupPlan>(directory: directory).invalidate(id, revision: revision, now: now)
    }
}
