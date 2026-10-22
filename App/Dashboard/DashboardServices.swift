import Foundation
import MoppoCore

protocol DashboardMeasuring: Sendable {
    func volumeInfo() async throws -> VolumeInfo
    func snapshots() async throws -> [SnapshotInfo]
    func measure() async throws -> StorageMeasurement
    func iCloudStorage(planBytes: Int64?) async throws -> ICloudStorage
}

struct DashboardMeasurementService: DashboardMeasuring {
    func volumeInfo() async throws -> VolumeInfo { try await DiskInfoService().volumeInfo() }
    func snapshots() async throws -> [SnapshotInfo] { try await SnapshotService().listAll() }
    func measure() async throws -> StorageMeasurement { try await StorageBreakdownService().measure() }
    func iCloudStorage(planBytes: Int64?) async throws -> ICloudStorage {
        try await ICloudStorageService().storage(planBytes: planBytes)
    }
}

protocol DashboardPersisting: Sendable {
    func loadCache() async -> BreakdownCache?
    func saveCache(_ cache: BreakdownCache) async
    func clearCache() async
    func loadHistory() async -> [StorageSnapshot]
    func record(_ measurement: StorageMeasurement, trigger: SnapshotTrigger) async throws -> [StorageSnapshot]
    func clearHistory() async
}

/// Serialize history writes and removal so an earlier write cannot restore cleared files.
actor DashboardPersistence: DashboardPersisting {
    private let snapshots: StorageSnapshotStore

    init(snapshots: StorageSnapshotStore = StorageSnapshotStore()) {
        self.snapshots = snapshots
    }

    func loadCache() -> BreakdownCache? { BreakdownCache.load() }
    func saveCache(_ cache: BreakdownCache) { cache.save() }
    func clearCache() { BreakdownCache.clear() }
    func loadHistory() -> [StorageSnapshot] { snapshots.load() }
    func record(_ measurement: StorageMeasurement, trigger: SnapshotTrigger) throws -> [StorageSnapshot] {
        let snapshot = try DashboardDiagnostics.phase("snapshot_validation") {
            guard let snapshot = SnapshotCapture.snapshot(from: measurement, trigger: trigger) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return snapshot
        }
        try DashboardDiagnostics.phase("history_write") { try snapshots.save(snapshot) }
        return try DashboardDiagnostics.phase("history_readback") {
            let result = snapshots.loadWithDiagnostics()
            DashboardDiagnostics.current?.record("history_readback_result", details: [
                "snapshot_count": "\(result.snapshots.count)", "unreadable_count": "\(result.unreadableCount)"
            ])
            guard result.snapshots.contains(where: { $0.id == snapshot.id }) else {
                throw CocoaError(.fileReadUnknown)
            }
            return result.snapshots
        }
    }
    func clearHistory() { try? snapshots.clear() }
}
