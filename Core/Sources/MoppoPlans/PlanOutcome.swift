import Foundation

/// Private outcome records contain identifiers and counts, without file paths.
public struct PlanOutcome: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case started, completed, partial, cancelled, failed, blocked }
    public enum ItemStatus: String, Codable, Sendable { case trashed, deleted, partial, failed, skipped, cancelled, unknown }
    public struct Item: Codable, Sendable {
        public let itemId: String
        public let status: ItemStatus
        public let reason: String?
        public let removedCount: Int
        public let trashedCount: Int
        public let deletedCount: Int
        public let removedBytes: Int64
        public let privateBytes: Int64
        public let unmeasuredCount: Int
    }

    public static let schemaVersion = 1
    public let schemaVersion: Int
    public let outcomeId: String
    public let runId: String
    public let planId: String
    public let planRevision: String
    public let createdAt: Date
    public let expiresAt: Date
    public let status: Status
    public let reason: String?
    public let items: [Item]

    init(handoff: PlanHandoff, runId: String = "run_" + UUID().uuidString.lowercased(),
         status: Status, reason: String? = nil, items: [Item] = [], now: Date = Date()) {
        schemaVersion = Self.schemaVersion
        outcomeId = "outcome_" + UUID().uuidString.lowercased()
        self.runId = runId
        planId = handoff.planId
        planRevision = handoff.revision
        createdAt = now
        expiresAt = now.addingTimeInterval(Self.lifetime)
        self.status = status
        self.reason = reason
        self.items = items
    }
}

extension PlanOutcome: PrivateRecord {
    static var currentSchemaVersion: Int { schemaVersion }
    static let prefix = "outcome_"
    static let lifetime: TimeInterval = 7 * 24 * 60 * 60
    static let retainedCount = 100
    static let maximumBytes = 512 * 1024
    var recordId: String { outcomeId }
    var recordDate: Date { createdAt }
    var isValid: Bool {
        ScanStore.validId(planId, prefix: "plan_") && ScanStore.validId(runId, prefix: "run_")
            && RecordDigest.isValid(planRevision) && expiresAt > createdAt && items.count <= 500
            && Set(items.map(\.itemId)).count == items.count
            && items.allSatisfy {
                ScanStore.validId($0.itemId, prefix: "item_") && $0.removedCount >= 0
                    && $0.trashedCount >= 0 && $0.deletedCount >= 0 && $0.removedBytes >= 0
                    && $0.privateBytes >= 0 && $0.unmeasuredCount >= 0
            }
    }
}

public struct PlanOutcomeStore: Sendable {
    public let directory: URL
    public init(directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Moppo/plan-outcomes")) {
        self.directory = directory
    }

    func save(_ outcome: PlanOutcome) throws {
        do { try PrivateRecordStore<PlanOutcome>(directory: directory).save(outcome) }
        catch { throw RecordStoreError.writeFailed }
    }

    public func recordReview(_ handoff: PlanHandoff, status: PlanOutcome.Status, reason: String? = nil) throws -> PlanOutcome {
        guard [.cancelled, .failed, .blocked].contains(status) else { throw RecordStoreError.invalidReport }
        let outcome = PlanOutcome(handoff: handoff, status: status, reason: reason)
        try save(outcome)
        return outcome
    }

    /// A started record without a final record has an unknown outcome after interruption.
    public func outcomes(planId: String) throws -> [PlanOutcome] {
        guard ScanStore.validId(planId, prefix: "plan_") else { throw RecordStoreError.invalidId }
        let records = try PrivateRecordStore<PlanOutcome>(directory: directory).records().filter { $0.planId == planId }
        return Dictionary(grouping: records, by: \.runId).values.compactMap { records in
            records.first(where: { $0.status != .started }) ?? records.first
        }.sorted { $0.createdAt > $1.createdAt }
    }
}
