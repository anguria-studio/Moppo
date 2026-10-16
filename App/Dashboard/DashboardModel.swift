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
    @ObservationIgnored private let settings: SettingsStore?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var dashboardTask: Task<Void, Never>?
    @ObservationIgnored private var measurementTask: Task<Void, Never>?
    @ObservationIgnored private var volumeTask: Task<Void, Never>?
    @ObservationIgnored private var volumeID: UUID?
    @ObservationIgnored private var cloudTask: Task<Void, Never>?
    @ObservationIgnored private var cloudID: UUID?
    @ObservationIgnored private var cloudPlanBytes: Int64?
    @ObservationIgnored private var historyClearTask: Task<Void, Never>?
    @ObservationIgnored private var historyRevision = UUID()
    @ObservationIgnored private var queuedCleanupID: UUID?
    @ObservationIgnored private var latestCleanupID: UUID?
    @ObservationIgnored private var hasRemovalToMeasure = false
    @ObservationIgnored private var storageHistory: [StorageSnapshot] = []
    @ObservationIgnored var canLoad: () -> Bool = { true }
    @ObservationIgnored var canMeasure: (Bool) -> Bool = { _ in true }
    @ObservationIgnored var hasICloudAccess: () -> Bool = { true }
    @ObservationIgnored var beforeMeasurement: () async -> Bool = { true }
    @ObservationIgnored var onVolumeChanged: (VolumeInfo) async -> Void = { _ in }

    init(
        service: any DashboardMeasuring = DashboardMeasurementService(),
        persistence: any DashboardPersisting = DashboardPersistence(),
        defaults: UserDefaults = .standard,
        settings: SettingsStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.persistence = persistence
        self.defaults = defaults
        self.settings = settings
        self.now = now
        let savedState = defaults.string(forKey: "cleanupMeasurementState")
            .flatMap(CleanupMeasurementState.init(rawValue:)) ?? .none
        cleanupMeasurementState = savedState == .measuring ? .interrupted : savedState
        preferredGrowthBaseline = defaults.string(forKey: "growthBaseline")
            .flatMap(GrowthBaseline.init(rawValue:))
            .flatMap { $0 == .previousMeasurement ? nil : $0 }
    }

    private(set) var volume: VolumeInfo?
    private(set) var breakdown: StorageBreakdown?
    private(set) var snapshots: [SnapshotInfo] = []
    private(set) var isLoadingBreakdown = false
    private(set) var isLowSpaceWarningDismissed = false
    struct TrashNotice: Identifiable {
        let id = UUID()
        let count: Int
        let bytes: Int64?
    }
    private(set) var trashNotice: TrashNotice?
    private(set) var hasCompletedInitialDashboardLoad = false
    var isDashboardLoading: Bool { !hasCompletedInitialDashboardLoad || isLoadingBreakdown }
    var snapshotsExpanded = false
    var boot: SnapshotInfo? { snapshots.first(where: \.isBootSnapshot) }
    var removableSnapshots: [SnapshotInfo] { snapshots.filter { !$0.isBootSnapshot } }
    private(set) var measuredAt: Date?
    enum ICloudState: Equatable {
        case idle, requiresAccess, loading, unavailable
        case available(ICloudStorage)
    }
    private(set) var iCloudState: ICloudState = .idle
    var iCloudStorage: ICloudStorage? {
        if case .available(let storage) = iCloudState { return storage }
        return nil
    }
    var showsICloudOnDashboard: Bool { settings?.showICloudOnDashboard ?? true }
    var hasPendingICloudSetup: Bool { settings?.hasPendingICloudSetup ?? false }
    var shouldResumeICloudSetup: Bool {
        hasPendingICloudSetup && showsICloudOnDashboard
            && (iCloudState == .requiresAccess || iCloudState == .unavailable)
    }
    var iCloudPlanBytes: Int64?
    private(set) var growth: GrowthComparison?
    enum CleanupMeasurementState: String, CaseIterable {
        case none, measuring, requiresAccess, failed, interrupted, cleared
    }
    private(set) var cleanupMeasurementState: CleanupMeasurementState {
        didSet { defaults.set(cleanupMeasurementState.rawValue, forKey: "cleanupMeasurementState") }
    }
    var cleanupBaselineDate: Date? { storageHistory.first { $0.trigger == .removal }?.measuredAt }
    var hasLaterCleanupMeasurement: Bool {
        guard let cleanupBaselineDate, let latest = storageHistory.first else { return false }
        return latest.measuredAt > cleanupBaselineDate
    }
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

    func spaceState(warnBelowGB: Int) -> DashboardSpaceState? {
        volume.map { DashboardSpaceState(freeBytes: $0.freeBytes, warnBelowGB: warnBelowGB) }
    }

    func showsSpaceWarning(warnBelowGB: Int) -> Bool {
        switch spaceState(warnBelowGB: warnBelowGB) {
        case .critical: true
        case .low: !isLowSpaceWarningDismissed && trashNotice == nil
        case .healthy, nil: false
        }
    }

    func recordTrashRemoval(_ outcome: CleanupOutcome) {
        guard outcome.trashedCount > 0 else { return }
        trashNotice = TrashNotice(
            count: outcome.trashedCount,
            bytes: outcome.deletedCount == 0 ? outcome.removedBytes : nil
        )
    }

    func dismissTrashNotice(_ id: UUID) {
        guard trashNotice?.id == id else { return }
        trashNotice = nil
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

    /// Record successful removals before their shared refresh starts.
    func recordCleanup() {
        hasRemovalToMeasure = true
        latestCleanupID = UUID()
        cleanupMeasurementState = .measuring
    }

    func refreshAfterRemoval() async {
        let trigger: SnapshotTrigger = hasRemovalToMeasure ? .removal : .scheduled
        hasRemovalToMeasure = false
        await measureStorage(trigger: trigger)
    }

    /// Queue cleanup measurements only within the active refresh.
    func measureStorage(trigger: SnapshotTrigger = .manual) async {
        let cleanupID: UUID? = trigger == .removal ? UUID() : nil
        if let cleanupID {
            latestCleanupID = cleanupID
            cleanupMeasurementState = .measuring
        }
        let automatic = trigger == .launch || trigger == .scheduled || trigger == .removal
        guard canMeasure(automatic) else {
            finishCleanup(cleanupID, state: .requiresAccess)
            return
        }
        guard await beforeMeasurement(), !Task.isCancelled else {
            finishCleanup(cleanupID, state: .interrupted)
            return
        }
        if let cleanupID, latestCleanupID != cleanupID { return }
        guard canMeasure(automatic) else {
            finishCleanup(cleanupID, state: .requiresAccess)
            return
        }
        if let measurementTask {
            if let cleanupID { queuedCleanupID = cleanupID }
            await measurementTask.value
            return
        }
        isLoadingBreakdown = true
        let task = Task { [self] in
            defer { isLoadingBreakdown = false; measurementTask = nil }
            var next = trigger
            var nextCleanupID = cleanupID
            while true {
                let saved = await performMeasurement(trigger: next, cleanupID: nextCleanupID)
                finishCleanup(nextCleanupID, state: saved ? .none : (Task.isCancelled ? .interrupted : .failed))
                guard let queued = queuedCleanupID else { break }
                queuedCleanupID = nil
                guard !Task.isCancelled else {
                    finishCleanup(queued, state: .interrupted)
                    break
                }
                guard canMeasure(true) else {
                    finishCleanup(queued, state: .requiresAccess)
                    break
                }
                next = .removal
                nextCleanupID = queued
            }
        }
        measurementTask = task
        await task.value
    }

    private func finishCleanup(_ id: UUID?, state: CleanupMeasurementState) {
        guard let id, latestCleanupID == id else { return }
        cleanupMeasurementState = state
    }

    /// Release active filesystem workers before Cleanup starts.
    func pauseMeasurementForScan() async {
        let measurement = measurementTask
        let cloud = cloudTask
        measurement?.cancel()
        cloud?.cancel()
        await measurement?.value
        await cloud?.value
    }

    private func performMeasurement(trigger: SnapshotTrigger, cleanupID: UUID?) async -> Bool {
        let revision = historyRevision
        let presentation = OperationPresentationDuration()
        startCloudLoad()
        await refreshVolumeInfo()
        guard !Task.isCancelled else { return false }
        guard let measured = try? await service.measure() else {
            try? await presentation.wait()
            return false
        }
        guard !Task.isCancelled else { return false }
        await refreshVolumeInfo()
        guard !Task.isCancelled else { return false }
        breakdown = volume.map {
            measured.breakdown.reconcilingVolume(capacityBytes: $0.capacityBytes, freeBytes: $0.freeBytes)
        } ?? measured.breakdown
        measuredAt = now()
        isLowSpaceWarningDismissed = false
        if let volume, let breakdown, let measuredAt {
            await persistence.saveCache(BreakdownCache(volume: volume, breakdown: breakdown, measuredAt: measuredAt))
        }
        await historyClearTask?.value
        var saved = false
        if revision == historyRevision, cleanupID == nil || cleanupID == latestCleanupID {
            if let history = try? await persistence.record(measured, trigger: trigger), revision == historyRevision {
                saved = true
                historyRevision = UUID()
                storageHistory = history
                recomputeGrowth()
            }
        }
        try? await presentation.wait()
        return saved
    }

    func loadICloud() async {
        guard let task = startCloudLoad() else { return }
        await task.value
    }

    func beginICloudSetup() {
        guard showsICloudOnDashboard else { return }
        settings?.hasPendingICloudSetup = true
    }

    func finishICloudSetup() {
        settings?.hasPendingICloudSetup = false
    }

    @discardableResult
    private func startCloudLoad() -> Task<Void, Never>? {
        let planBytes: Int64? = if let settings { settings.iCloudPlan.bytes } else { iCloudPlanBytes }
        let isVisible = canLoad() && showsICloudOnDashboard
        let hasAccess = hasICloudAccess()
        if isVisible, hasAccess, let cloudTask, !cloudTask.isCancelled, cloudPlanBytes == planBytes {
            return cloudTask
        }
        cloudTask?.cancel()
        cloudTask = nil
        cloudID = nil
        guard isVisible else {
            iCloudState = .idle
            return nil
        }
        guard hasAccess else {
            iCloudState = .requiresAccess
            return nil
        }
        let id = UUID()
        cloudID = id
        cloudPlanBytes = planBytes
        let previous = iCloudState == .loading ? .idle : iCloudState
        if iCloudStorage == nil { iCloudState = .loading }
        let task = Task { [self] in
            defer {
                if cloudID == id {
                    if iCloudState == .loading { iCloudState = previous }
                    cloudTask = nil
                    cloudID = nil
                }
            }
            let storage = try? await service.iCloudStorage(planBytes: planBytes)
            guard cloudID == id, !Task.isCancelled else { return }
            guard showsICloudOnDashboard else { iCloudState = .idle; return }
            guard hasICloudAccess() else { iCloudState = .requiresAccess; return }
            iCloudState = storage.map(ICloudState.available) ?? .unavailable
            if storage != nil { finishICloudSetup() }
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
        latestCleanupID = nil
        queuedCleanupID = nil
        hasRemovalToMeasure = false
        cleanupMeasurementState = .cleared
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

/// Uses the warning preference and a fixed critical limit of 5 GB.
enum DashboardSpaceState: Equatable {
    case healthy, low, critical

    init(freeBytes: Int64, warnBelowGB: Int) {
        if freeBytes < 5 * ByteFormatting.bytesPerGB {
            self = .critical
        } else if freeBytes < Int64(warnBelowGB) * ByteFormatting.bytesPerGB {
            self = .low
        } else {
            self = .healthy
        }
    }

    var color: ColorToken {
        switch self {
        case .healthy: .green
        case .low: .orange
        case .critical: .red
        }
    }
}
