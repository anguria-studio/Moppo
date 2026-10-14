import Foundation
import Testing
@testable import MoppoCore

@Suite("Dashboard feature ownership")
@MainActor
struct DashboardModelTests {

    @Test("Free-space states respect both limits at their exact boundaries")
    func spaceStates() {
        let gb = ByteFormatting.bytesPerGB
        #expect(DashboardSpaceState(freeBytes: 20 * gb, warnBelowGB: 20) == .healthy)
        #expect(DashboardSpaceState(freeBytes: 20 * gb - 1, warnBelowGB: 20) == .low)
        #expect(DashboardSpaceState(freeBytes: 5 * gb, warnBelowGB: 20) == .low)
        #expect(DashboardSpaceState(freeBytes: 5 * gb - 1, warnBelowGB: 20) == .critical)
        #expect(DashboardSpaceState(freeBytes: 0, warnBelowGB: 0) == .critical)
        #expect(DashboardSpaceState(freeBytes: 30 * gb, warnBelowGB: 40) == .low)
        #expect(DashboardSpaceState(freeBytes: 30 * gb, warnBelowGB: 20) == .healthy)
    }

    @Test("Critical space remains visible after dismissal and during a Trash notice")
    func criticalWarningPriority() async throws {
        let service = HeldDashboardMeasurements(holdVolume: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence())
        #expect(!model.showsSpaceWarning(warnBelowGB: 20))
        let lowRead = Task { await model.refreshVolumeInfo(notifyLowSpace: false) }
        try await waitUntil { await service.volumeCount == 1 }
        await service.finishVolume(0, dashboardVolume(free: 10 * ByteFormatting.bytesPerGB))
        await lowRead.value
        #expect(model.showsSpaceWarning(warnBelowGB: 20))
        model.recordTrashRemoval(.init(removedBytes: 100, removedCount: 1, trashedCount: 1))
        #expect(!model.showsSpaceWarning(warnBelowGB: 20))
        let notice = try #require(model.trashNotice)
        model.dismissTrashNotice(notice.id)
        #expect(model.showsSpaceWarning(warnBelowGB: 20))
        model.dismissLowSpaceWarning()
        #expect(!model.showsSpaceWarning(warnBelowGB: 20))
        let criticalRead = Task { await model.refreshVolumeInfo(notifyLowSpace: false) }
        try await waitUntil { await service.volumeCount == 2 }
        await service.finishVolume(1, dashboardVolume(free: 3 * ByteFormatting.bytesPerGB))
        await criticalRead.value
        #expect(model.showsSpaceWarning(warnBelowGB: 20))
        model.recordTrashRemoval(.init(removedBytes: 100, removedCount: 1, trashedCount: 1))
        #expect(model.showsSpaceWarning(warnBelowGB: 20))
    }

    @Test("Trash notices exclude permanent deletions and reject an old dismissal")
    func trashNotices() throws {
        let model = DashboardModel(service: HeldDashboardMeasurements(), persistence: HeldDashboardPersistence())
        model.recordTrashRemoval(.init(removedBytes: 500, removedCount: 1, deletedCount: 1))
        #expect(model.trashNotice == nil)
        model.recordTrashRemoval(.init(removedBytes: 200, removedCount: 2, trashedCount: 2))
        let first = try #require(model.trashNotice)
        #expect(first.bytes == 200)
        #expect(first.count == 2)
        model.recordTrashRemoval(.init(removedBytes: 300, removedCount: 2, trashedCount: 1, deletedCount: 1))
        let second = try #require(model.trashNotice)
        #expect(second.bytes == nil)
        #expect(second.count == 1)
        model.dismissTrashNotice(first.id)
        #expect(model.trashNotice?.id == second.id)
        model.dismissTrashNotice(second.id)
        #expect(model.trashNotice == nil)
    }

    @Test("Cleanup and duplicate removal feed the dashboard Trash notice")
    func trashNoticeEvents() {
        let app = AppModel(
            hasFullDiskAccess: { true }, dashboardService: HeldDashboardMeasurements(),
            dashboardPersistence: HeldDashboardPersistence()
        )
        app.view = .scanner
        app.cleanup.onEvent(.removed(.init(removedBytes: 200, removedCount: 1, trashedCount: 1)))
        #expect(app.dashboard.trashNotice?.bytes == 200)
        app.fileDuplicates.onEvent(.removed(
            .init(removedBytes: 300, removedCount: 1, trashedCount: 1), extraFailures: 0
        ))
        #expect(app.dashboard.trashNotice?.bytes == 300)
        app.recovery.onEvent(.emptiedTrash(freedBytes: 500, skippedURLs: []))
        #expect(app.dashboard.trashNotice == nil)
    }
    @Test("Limited access loads cached figures without starting background measurements")
    func limitedLaunch() async throws {
        let service = HeldDashboardMeasurements()
        let measurement = dashboardMeasurement()
        let cache = BreakdownCache(volume: measurement.volume, breakdown: measurement.breakdown, measuredAt: .now)
        let persistence = HeldDashboardPersistence(cache: cache)
        let app = AppModel(
            launchAccess: .limited, hasFullDiskAccess: { false },
            dashboardService: service, dashboardPersistence: persistence
        )
        await app.dashboard.loadDashboard()
        #expect(app.dashboard.hasCompletedInitialDashboardLoad)
        #expect(!app.dashboard.isDashboardLoading)
        #expect(app.dashboard.breakdown == measurement.breakdown)
        #expect(app.dashboard.snapshots.count == 2)
        #expect(app.dashboard.boot?.uuid == "boot")
        #expect(app.dashboard.removableSnapshots.map(\.uuid) == ["data"])
        #expect(await service.measurementCount == 0)
        #expect(await service.cloudPlans.isEmpty)
        #expect(await persistence.records.isEmpty)
    }

    @Test("Launch refresh owns its task across navigation and caller cancellation")
    func launchLifetime() async throws {
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let app = AppModel(hasFullDiskAccess: { true }, dashboardService: service, dashboardPersistence: persistence)
        let caller = Task { await app.dashboard.loadDashboard() }
        try await waitUntil { await service.measurementCount == 1 }
        app.view = .history
        caller.cancel()
        let second = Task { await app.dashboard.loadDashboard() }
        #expect(app.dashboard.isDashboardLoading)
        #expect(!app.dashboard.hasCompletedInitialDashboardLoad)
        await service.finishMeasurement(0, dashboardMeasurement())
        await caller.value
        await second.value
        #expect(await persistence.cacheLoads == 1)
        #expect(await service.measurementCount == 1)
        #expect(await service.cancelled == [false])
        #expect(await persistence.records == [.launch])
        #expect(app.dashboard.measuredAt != nil)
        #expect(!app.dashboard.isDashboardLoading)
        #expect(app.view == .history)
    }

    @Test("Launch shows cached figures and waits for Cleanup workers", arguments: [false, true])
    func launchWaitsForCleanup(stopScan: Bool) async throws {
        let scanner = HeldCleanupScanner()
        let service = HeldDashboardMeasurements()
        let measurement = dashboardMeasurement()
        let cache = BreakdownCache(volume: measurement.volume, breakdown: measurement.breakdown, measuredAt: .now)
        let persistence = HeldDashboardPersistence(cache: cache)
        let app = AppModel(
            hasFullDiskAccess: { true }, dashboardService: service,
            dashboardPersistence: persistence, cleanupScanner: scanner
        )
        app.startInitialCleanupScan()
        try await waitUntil { await scanner.requestCount == 1 }
        let launch = Task { await app.loadDashboard() }
        try await waitUntil { app.dashboard.breakdown == cache.breakdown }
        try await waitUntil { await persistence.historyLoads == 1 }
        #expect(await persistence.historyLoads == 1)
        #expect(await service.measurementCount == 0)
        app.view = .dashboard
        if stopScan { app.cleanup.cancelScan() }
        await Task.yield()
        #expect(app.isBusyWithDisk)
        #expect(await service.measurementCount == 0)
        await scanner.finish(0, results: ScanResults(categories: [], startedAt: .now, finishedAt: .now))
        if !stopScan {
            try await waitUntil { await service.measurementCount == 1 }
            await service.finishMeasurement(0, measurement)
        }
        await launch.value
        #expect(!app.cleanup.isScanning)
        #expect(!app.isBusyWithDisk)
        #expect(await service.measurementCount == (stopScan ? 0 : 1))
        #expect(app.view == .dashboard)
        #expect(app.dashboard.hasCompletedInitialDashboardLoad)
        #expect(await persistence.records == (stopScan ? [] : [.launch]))
    }

    @Test("Manual and scheduled scans defer refreshes and discard stopped requests", arguments: [false, true], [false, true])
    func scanRefreshWaitsForCleanup(automatic: Bool, stopScan: Bool) async throws {
        let scanner = HeldCleanupScanner()
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let app = AppModel(
            hasFullDiskAccess: { true }, dashboardService: service,
            dashboardPersistence: persistence, cleanupScanner: scanner
        )
        app.cleanup.startScan(automatic: automatic)
        try await waitUntil { await scanner.requestCount == 1 }
        let refresh = Task { await app.dashboard.measureStorage() }
        await Task.yield()
        #expect(await service.measurementCount == 0)
        app.view = .history
        if stopScan { app.cleanup.cancelScan() }
        await scanner.finish(0, results: ScanResults(categories: [], startedAt: .now, finishedAt: .now))
        if !stopScan {
            try await waitUntil { await service.measurementCount == 1 }
            await service.finishMeasurement(0, dashboardMeasurement())
        }
        await refresh.value
        try await waitUntil { !app.cleanup.isScanning && !app.dashboard.isLoadingBreakdown }
        #expect(await service.measurementCount == (stopScan ? 0 : 1))
        #expect(app.view == .history)
        #expect(await persistence.records.count == (stopScan ? 0 : 1))
    }

    @Test("Cleanup drains an active Dashboard measurement and retains a pending removal baseline", arguments: [SnapshotTrigger.manual, .removal])
    func scanDrainsDashboard(trigger: SnapshotTrigger) async throws {
        let scanner = HeldCleanupScanner()
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let app = AppModel(
            hasFullDiskAccess: { true }, dashboardService: service,
            dashboardPersistence: persistence, cleanupScanner: scanner
        )
        let refresh = Task { await app.dashboard.measureStorage(trigger: trigger) }
        try await waitUntil { await service.measurementCount == 1 }
        app.cleanup.startScan()
        await Task.yield()
        #expect(await scanner.requestCount == 0)
        await service.finishMeasurement(0, dashboardMeasurement())
        await refresh.value
        try await waitUntil { await scanner.requestCount == 1 }
        #expect(await service.cancelled == [true])
        #expect(await persistence.records.isEmpty)
        await scanner.finish(0, results: ScanResults(categories: [], startedAt: .now, finishedAt: .now))
        try await waitUntil { await service.measurementCount == 2 }
        await service.finishMeasurement(1, dashboardMeasurement())
        try await waitUntil { !app.dashboard.isLoadingBreakdown }
        #expect(await persistence.records == [trigger == .removal ? .removal : .scan])
    }

    @Test("Concurrent removal refreshes produce one additional cleanup baseline")
    func removalBaseline() async throws {
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let model = DashboardModel(service: service, persistence: persistence)
        let first = Task { await model.measureStorage() }
        try await waitUntil { await service.measurementCount == 1 }
        let removal = Task { await model.measureStorage(trigger: .removal) }
        let repeated = Task { await model.measureStorage(trigger: .removal) }
        await Task.yield()
        await service.finishMeasurement(0, dashboardMeasurement())
        try await waitUntil { await service.measurementCount == 2 }
        #expect(model.isLoadingBreakdown)
        await service.finishMeasurement(1, dashboardMeasurement(free: 300))
        await first.value
        await removal.value
        await repeated.value
        #expect(await service.measurementCount == 2)
        #expect(await persistence.records == [.manual, .removal])
        #expect(model.hasCleanupGrowthBaseline)
        #expect(!model.isLoadingBreakdown)
    }

    @Test("Older cloud requests cannot replace the selected plan")
    func cloudReplacement() async throws {
        let service = HeldDashboardMeasurements(holdCloud: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence())
        model.iCloudPlanBytes = 100
        let first = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 1 }
        model.iCloudPlanBytes = 200
        let second = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 2 }
        let latest = ICloudStorage(totalBytes: 200, freeBytes: 40, documentsBytes: 80)
        await service.finishCloud(1, latest)
        await second.value
        await service.finishCloud(0, ICloudStorage(totalBytes: 100, freeBytes: 10, documentsBytes: 20))
        await first.value
        #expect(model.iCloudStorage == latest)
        #expect(await service.cloudPlans == [100, 200])
    }

    @Test("Late volume reads cannot restore older totals or send stale notifications")
    func volumeReplacement() async throws {
        let service = HeldDashboardMeasurements(holdVolume: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence())
        var notified: [Int64] = []
        model.onVolumeChanged = { notified.append($0.freeBytes) }
        let first = Task { await model.refreshVolumeInfo() }
        try await waitUntil { await service.volumeCount == 1 }
        let second = Task { await model.refreshVolumeInfo() }
        try await waitUntil { await service.volumeCount == 2 }
        await service.finishVolume(1, dashboardVolume(free: 300))
        await second.value
        await service.finishVolume(0, dashboardVolume(free: 10))
        await first.value
        #expect(model.volume?.freeBytes == 300)
        #expect(notified == [300])
    }

    @Test("A completed measurement uses the final volume read for displayed and cached totals")
    func measurementUsesFinalVolume() async throws {
        let service = HeldDashboardMeasurements(holdVolume: true)
        let persistence = HeldDashboardPersistence()
        let model = DashboardModel(service: service, persistence: persistence)
        let refresh = Task { await model.measureStorage() }
        try await waitUntil { await service.volumeCount == 1 }
        await service.finishVolume(0, dashboardVolume(free: 200))
        try await waitUntil { await service.measurementCount == 1 }
        await service.finishMeasurement(0, dashboardMeasurement(free: 200))
        try await waitUntil { await service.volumeCount == 2 }
        await service.finishVolume(1, dashboardVolume(free: 100))
        await refresh.value
        #expect(model.breakdown?.freeBytes == 100)
        #expect(model.breakdown?.usedBytes == 900)
        #expect(await persistence.cache?.breakdown == model.breakdown)
    }

    @Test("An older history read cannot remove a newly recorded cleanup baseline")
    func historyLoadAfterMeasurement() async throws {
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence(holdHistory: true)
        let model = DashboardModel(service: service, persistence: persistence)
        let launch = Task { await model.loadDashboard() }
        try await waitUntil { await persistence.historyLoads == 1 }
        let removal = Task { await model.measureStorage(trigger: .removal) }
        try await waitUntil { await service.measurementCount == 1 }
        await service.finishMeasurement(0, dashboardMeasurement())
        await removal.value
        #expect(model.hasCleanupGrowthBaseline)
        model.canMeasure = { _ in false }
        await persistence.finishHistory([])
        await launch.value
        #expect(model.hasCleanupGrowthBaseline)
        #expect(await persistence.records == [.removal])
    }

    @Test("Clearing history rejects a stored history read already in progress")
    func clearDuringHistoryLoad() async throws {
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence(holdHistory: true)
        let model = DashboardModel(service: service, persistence: persistence)
        model.canMeasure = { _ in false }
        let caller = Task { await model.loadDashboard() }
        try await waitUntil { await persistence.historyLoads == 1 }
        model.clearMeasurementHistory()
        try await waitUntil { await persistence.clearCount == 1 }
        let previous = try #require(SnapshotCapture.snapshot(from: dashboardMeasurement(), trigger: .removal))
        await persistence.finishHistory([previous])
        await caller.value
        #expect(model.growth == .insufficientHistory)
        #expect(!model.hasCleanupGrowthBaseline)
        #expect(model.growthBaseline == .sevenDays)
    }

    @Test("A measurement started before history was cleared cannot recreate its history")
    func clearDuringMeasurement() async throws {
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let model = DashboardModel(service: service, persistence: persistence)
        let caller = Task { await model.measureStorage(trigger: .removal) }
        try await waitUntil { await service.measurementCount == 1 }
        model.clearMeasurementHistory()
        await service.finishMeasurement(0, dashboardMeasurement())
        await caller.value
        #expect(await persistence.records.isEmpty)
        #expect(await persistence.clearCount == 1)
        #expect(model.breakdown != nil)
        #expect(model.growth == .insufficientHistory)
        let next = Task { await model.measureStorage() }
        try await waitUntil { await service.measurementCount == 2 }
        await service.finishMeasurement(1, dashboardMeasurement())
        await next.value
        #expect(await persistence.records == [.manual])
    }

    @Test("Clearing history rejects a late snapshot result and preserves the selected baseline")
    func clearDuringRecord() async throws {
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence(holdRecord: true)
        let suite = "DashboardTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(service: service, persistence: persistence, defaults: defaults)
        model.growthBaseline = .sevenDays
        let caller = Task { await model.measureStorage(trigger: .removal) }
        try await waitUntil { await service.measurementCount == 1 }
        await service.finishMeasurement(0, dashboardMeasurement())
        try await waitUntil { await persistence.records.count == 1 }
        model.clearMeasurementHistory()
        try await waitUntil { await persistence.clearCount == 1 }
        let previous = try #require(SnapshotCapture.snapshot(from: dashboardMeasurement(), trigger: .removal))
        await persistence.finishRecord([previous])
        await caller.value
        #expect(model.growth == .insufficientHistory)
        #expect(!model.hasCleanupGrowthBaseline)
        #expect(defaults.string(forKey: "growthBaseline") == GrowthBaseline.sevenDays.rawValue)
        model.growthBaseline = .previousMeasurement
        #expect(model.growthBaseline == .sevenDays)
    }

    @Test("Dismissal lasts through navigation and volume reads until the next dashboard measurement")
    func lowSpaceWarningDismissal() async throws {
        let service = HeldDashboardMeasurements()
        let app = AppModel(
            hasFullDiskAccess: { true }, dashboardService: service,
            dashboardPersistence: HeldDashboardPersistence()
        )
        await app.dashboard.refreshVolumeInfo(notifyLowSpace: false)
        #expect(!app.dashboard.isLowSpaceWarningDismissed)
        app.dashboard.dismissLowSpaceWarning()
        app.view = .history
        app.view = .dashboard
        await app.dashboard.refreshVolumeInfo(notifyLowSpace: false)
        #expect(app.dashboard.isLowSpaceWarningDismissed)

        let caller = Task { await app.dashboard.measureStorage() }
        try await waitUntil { await service.measurementCount == 1 }
        #expect(app.dashboard.isLowSpaceWarningDismissed)
        await service.finishMeasurement(0, dashboardMeasurement())
        await caller.value
        #expect(!app.dashboard.isLowSpaceWarningDismissed)
        #expect(app.dashboard.volume == dashboardVolume())
        app.dashboard.dismissLowSpaceWarning()
        #expect(app.dashboard.isLowSpaceWarningDismissed)
    }

    @Test("A failed measurement keeps cached figures and permits a retry")
    func measurementFailure() async throws {
        let service = HeldDashboardMeasurements()
        let measurement = dashboardMeasurement()
        let cache = BreakdownCache(volume: measurement.volume, breakdown: measurement.breakdown, measuredAt: .distantPast)
        let persistence = HeldDashboardPersistence(cache: cache)
        let model = DashboardModel(service: service, persistence: persistence)
        model.canMeasure = { _ in false }
        await model.loadDashboard()
        model.dismissLowSpaceWarning()
        model.canMeasure = { _ in true }
        let caller = Task { await model.measureStorage() }
        try await waitUntil { await service.measurementCount == 1 }
        await service.failMeasurement(0)
        await caller.value
        #expect(model.breakdown == cache.breakdown)
        #expect(model.measuredAt == cache.measuredAt)
        #expect(!model.isLoadingBreakdown)
        #expect(model.isLowSpaceWarningDismissed)
        #expect(await persistence.records.isEmpty)
        let retry = Task { await model.rebuildSizeIndex() }
        try await waitUntil { await service.measurementCount == 2 }
        await service.finishMeasurement(1, measurement)
        await retry.value
        #expect(await persistence.cacheClears == 1)
        #expect(!model.isLowSpaceWarningDismissed)
        #expect(await persistence.records == [.manual])
    }
}

private func dashboardVolume(free: Int64 = 200) -> VolumeInfo {
    VolumeInfo(name: "Fixture", capacityBytes: 1000, freeBytes: free, filesystem: "apfs", isEncrypted: true)
}

private func dashboardMeasurement(free: Int64 = 200) -> StorageMeasurement {
    let raw: [StorageSegmentID: Int64] = [.documentsDesktop: 1000 - free, .free: free]
    return StorageMeasurement(
        home: URL(fileURLWithPath: "/moppo-fixture"), volume: dashboardVolume(free: free),
        breakdown: .make(capacityBytes: 1000, rawSegments: raw, unreadableCount: 0), rawSegments: raw,
        homeTree: [:], rootMeasurements: [:], nodeDepth: 4
    )
}

private actor HeldDashboardMeasurements: DashboardMeasuring {
    let holdCloud: Bool
    let holdVolume: Bool
    private(set) var measurementCount = 0
    private(set) var cloudPlans: [Int64?] = []
    private(set) var volumeCount = 0
    private(set) var cancelled: [Bool] = []
    private var measurements: [Int: CheckedContinuation<StorageMeasurement, Error>] = [:]
    private var clouds: [Int: CheckedContinuation<ICloudStorage, Never>] = [:]
    private var volumes: [Int: CheckedContinuation<VolumeInfo, Never>] = [:]
    init(holdCloud: Bool = false, holdVolume: Bool = false) {
        self.holdCloud = holdCloud
        self.holdVolume = holdVolume
    }
    func volumeInfo() async throws -> VolumeInfo {
        let index = volumeCount
        volumeCount += 1
        if holdVolume { return await withCheckedContinuation { volumes[index] = $0 } }
        return dashboardVolume()
    }
    func snapshots() async throws -> [SnapshotInfo] {
        ["boot", "data"].map {
            SnapshotInfo(uuid: $0, name: $0, purgeable: $0 != "boot", limitingContainerShrink: false,
                         isBootSnapshot: $0 == "boot", volumeDisk: "disk-fixture")
        }
    }
    func measure() async throws -> StorageMeasurement {
        let index = measurementCount
        measurementCount += 1
        let value = try await withCheckedThrowingContinuation { measurements[index] = $0 }
        cancelled.append(Task.isCancelled)
        return value
    }
    func iCloudStorage(planBytes: Int64?) async throws -> ICloudStorage {
        let index = cloudPlans.count
        cloudPlans.append(planBytes)
        if holdCloud { return await withCheckedContinuation { clouds[index] = $0 } }
        return ICloudStorage(totalBytes: planBytes ?? 100, freeBytes: 20, documentsBytes: 40)
    }
    func finishMeasurement(_ index: Int, _ value: StorageMeasurement) { measurements.removeValue(forKey: index)?.resume(returning: value) }
    func failMeasurement(_ index: Int) { measurements.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func finishCloud(_ index: Int, _ value: ICloudStorage) { clouds.removeValue(forKey: index)?.resume(returning: value) }
    func finishVolume(_ index: Int, _ value: VolumeInfo) { volumes.removeValue(forKey: index)?.resume(returning: value) }
}

private actor HeldDashboardPersistence: DashboardPersisting {
    let holdHistory: Bool
    let holdRecord: Bool
    private(set) var cache: BreakdownCache?
    private(set) var cacheLoads = 0
    private(set) var cacheClears = 0
    private(set) var historyLoads = 0
    private(set) var records: [SnapshotTrigger] = []
    private(set) var clearCount = 0
    private var history: [StorageSnapshot] = []
    private var historyReply: CheckedContinuation<[StorageSnapshot], Never>?
    private var recordReply: CheckedContinuation<[StorageSnapshot], Never>?
    init(cache: BreakdownCache? = nil, holdHistory: Bool = false, holdRecord: Bool = false) {
        self.cache = cache
        self.holdHistory = holdHistory
        self.holdRecord = holdRecord
    }
    func loadCache() -> BreakdownCache? { cacheLoads += 1; return cache }
    func saveCache(_ cache: BreakdownCache) { self.cache = cache }
    func clearCache() { cache = nil; cacheClears += 1 }
    func loadHistory() async -> [StorageSnapshot] {
        historyLoads += 1
        if holdHistory { return await withCheckedContinuation { historyReply = $0 } }
        return history
    }
    func record(_ measurement: StorageMeasurement, trigger: SnapshotTrigger) async -> [StorageSnapshot] {
        records.append(trigger)
        if holdRecord { return await withCheckedContinuation { recordReply = $0 } }
        if let snapshot = SnapshotCapture.snapshot(from: measurement, trigger: trigger) { history.insert(snapshot, at: 0) }
        return history
    }
    func clearHistory() { clearCount += 1; history = [] }
    func finishHistory(_ history: [StorageSnapshot]) { historyReply?.resume(returning: history); historyReply = nil }
    func finishRecord(_ history: [StorageSnapshot]) { recordReply?.resume(returning: history); recordReply = nil }
}
