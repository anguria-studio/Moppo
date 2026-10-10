import Foundation
import Observation
import MoppoCore

/// Owns storage measurements, cached figures, cloud state, and growth comparisons.
@MainActor
@Observable
final class DashboardModel {
    @ObservationIgnored private let service: any DashboardMeasuring
    @ObservationIgnored private let persistence: any DashboardPersisting
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var dashboardTask: Task<Void, Never>?
    @ObservationIgnored private var measurementTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeID: UUID?
    @ObservationIgnored private var cloudTask: Task<Void, Never>?
    @ObservationIgnored private var cloudID: UUID?
    @ObservationIgnored private var historyClearTask: Task<Void, Never>?
    @ObservationIgnored private var historyRevision = UUID()
    @ObservationIgnored private var needsPostCleanupMeasurement = false
    @ObservationIgnored private var storageHistory: [StorageSnapshot] = []
    @ObservationIgnored var canLoad: () -> Bool = { true }
    @ObservationIgnored var canMeasure: (Bool) -> Bool = { _ in true }
    @ObservationIgnored var hasLimitedAccess: () -> Bool = { false }
    @ObservationIgnored var onVolumeChanged: (VolumeInfo) async -> Void = { _ in }

    init(
        service: any DashboardMeasuring = DashboardMeasurementService(),
        persistence: any DashboardPersisting = DashboardPersistence(),
        defaults: UserDefaults = .standard,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.persistence = persistence
        self.defaults = defaults
        self.now = now
        preferredGrowthBaseline = defaults.string(forKey: "growthBaseline")
            .flatMap(GrowthBaseline.init(rawValue:))
            .flatMap { $0 == .previousMeasurement ? nil : $0 }
    }

    private(set) var volume: VolumeInfo?
    private(set) var breakdown: StorageBreakdown?
    private(set) var snapshots: [SnapshotInfo] = []
    private(set) var isLoadingBreakdown = false
    private(set) var isLowSpaceWarningDismissed = false
    private(set) var hasCompletedInitialDashboardLoad = false
    var isDashboardLoading: Bool { !hasCompletedInitialDashboardLoad || isLoadingBreakdown }
    var snapshotsExpanded = false
    var boot: SnapshotInfo? { snapshots.first(where: \.isBootSnapshot) }
    var removableSnapshots: [SnapshotInfo] { snapshots.filter { !$0.isBootSnapshot } }
    private(set) var measuredAt: Date?
    var breakdownIsStale: Bool {
        guard !hasLimitedAccess(), let measuredAt else { return true }
        return now().timeIntervalSince(measuredAt) > BreakdownCache.freshnessWindow
    }
    private(set) var iCloudStorage: ICloudStorage?
    var iCloudPlanBytes: Int64?
    private(set) var growth: GrowthComparison?
    private(set) var hasCleanupGrowthBaseline = false
    private var preferredGrowthBaseline: GrowthBaseline?

    var growthBaseline: GrowthBaseline {
        get {
            preferredGrowthBaseline == .sevenDays || !hasCleanupGrowthBaseline ? .sevenDays : .lastCleanup
        }
        set {
            guard newValue != .previousMeasurement else { return }
            preferredGrowthBaseline = newValue
            defaults.set(newValue.rawValue, forKey: "growthBaseline")
            recomputeGrowth()
        }
    }

    func dismissLowSpaceWarning() {
        isLowSpaceWarningDismissed = true
    }

    /// Keep launch loading active until the complete refresh finishes.
    func loadDashboard() async {
        guard canLoad() else { return }
        if let dashboardTask { await dashboardTask.value; return }
        hasCompletedInitialDashboardLoad = false
        let task = Task { [self] in
            defer {
                hasCompletedInitialDashboardLoad = true
                dashboardTask = nil
            }
            let cached = await persistence.loadCache()
            if breakdown == nil, !isLoadingBreakdown, let cached {
                if volume == nil { volume = cached.volume }
                breakdown = cached.breakdown
                measuredAt = cached.measuredAt
            }
            snapshots = (try? await service.snapshots()) ?? []
            let revision = historyRevision
            await historyClearTask?.value
            let history = await persistence.loadHistory()
            if revision == historyRevision {
                storageHistory = history
                recomputeGrowth()
            }
            if canMeasure(true) {
                await measureStorage(trigger: .launch)
            } else {
                await refreshVolumeInfo(notifyLowSpace: false)
            }
        }
        dashboardTask = task
        await task.value
    }

    /// Merge concurrent requests and retain a measurement after disk removal.
    func measureStorage(trigger: SnapshotTrigger = .manual) async {
        let automatic = trigger == .launch || trigger == .scheduled || trigger == .removal
        guard canMeasure(automatic) else { return }
        if let measurementTask {
            if trigger == .removal { needsPostCleanupMeasurement = true }
            await measurementTask.value
            return
        }
        isLoadingBreakdown = true
        let task = Task { [self] in
            defer { isLoadingBreakdown = false; measurementTask = nil }
            var next = trigger
            while true {
                await performMeasurement(trigger: next)
                guard needsPostCleanupMeasurement else { break }
                needsPostCleanupMeasurement = false
                guard canMeasure(true) else { break }
                next = .removal
            }
        }
        measurementTask = task
        await task.value
    }

    private func performMeasurement(trigger: SnapshotTrigger) async {
        let revision = historyRevision
        let presentation = OperationPresentationDuration()
        startCloudLoad()
        await refreshVolumeInfo()
        guard let measured = try? await service.measure() else {
            try? await presentation.wait()
            return
        }
        breakdown = measured.breakdown
        await refreshVolumeInfo()
        measuredAt = now()
        isLowSpaceWarningDismissed = false
        if let volume, let breakdown, let measuredAt {
            await persistence.saveCache(BreakdownCache(volume: volume, breakdown: breakdown, measuredAt: measuredAt))
        }
        await historyClearTask?.value
        if revision == historyRevision {
            let history = await persistence.record(measured, trigger: trigger)
            if revision == historyRevision {
                historyRevision = UUID()
                storageHistory = history
                recomputeGrowth()
            }
        }
        try? await presentation.wait()
    }

    func loadICloud() async {
        guard let task = startCloudLoad() else { return }
        await task.value
    }

    @discardableResult
    private func startCloudLoad() -> Task<Void, Never>? {
        guard canMeasure(true) else { return nil }
        cloudTask?.cancel()
        let id = UUID()
        cloudID = id
        let planBytes = iCloudPlanBytes
        let task = Task { [self] in
            defer {
                if cloudID == id { cloudTask = nil; cloudID = nil }
            }
            let storage = try? await service.iCloudStorage(planBytes: planBytes)
            guard cloudID == id, !Task.isCancelled else { return }
            iCloudStorage = storage
        }
        cloudTask = task
        return task
    }

    /// A later volume request supersedes an earlier periodic read.
    func refreshVolumeInfo(notifyLowSpace: Bool = true) async {
        volumeTask?.cancel()
        let id = UUID()
        volumeID = id
        let task = Task { [self] in
            defer {
                if volumeID == id { volumeTask = nil; volumeID = nil }
            }
            let current = try? await service.volumeInfo()
            guard volumeID == id, !Task.isCancelled else { return }
            volume = current ?? volume
            if let volume, let breakdown {
                self.breakdown = breakdown.reconcilingVolume(
                    capacityBytes: volume.capacityBytes, freeBytes: volume.freeBytes
                )
            }
            if notifyLowSpace, let volume { await onVolumeChanged(volume) }
        }
        volumeTask = task
        await task.value
    }

    func rebuildSizeIndex() async {
        await persistence.clearCache()
        await measureStorage()
    }

    /// Reject earlier reads and measurements after the user clears history.
    func clearMeasurementHistory() {
        historyRevision = UUID()
        storageHistory = []
        recomputeGrowth()
        let persistence = persistence
        historyClearTask = Task { await persistence.clearHistory() }
    }

    private func recomputeGrowth() {
        hasCleanupGrowthBaseline = storageHistory.contains { $0.trigger == .removal }
        growth = StorageGrowth.comparison(growthBaseline, in: storageHistory)
    }
}
