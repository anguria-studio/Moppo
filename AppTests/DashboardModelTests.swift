import Foundation
import SwiftUI
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

    @Test("Cleanup drains an active Dashboard measurement without postponing its cleanup baseline", arguments: [SnapshotTrigger.manual, .removal])
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
        #expect(await persistence.records == [.scan])
        if trigger == .removal {
            #expect(app.dashboard.cleanupMeasurementState == .interrupted)
            #expect(!app.dashboard.hasCleanupGrowthBaseline)
        }
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

    @Test("Blocked cleanup measurements survive restart, and a manual refresh clears the notice without creating a cleanup baseline")
    func blockedCleanupMeasurement() async throws {
        let suite = "DashboardCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let model = DashboardModel(service: service, persistence: persistence, defaults: defaults)
        #expect(model.cleanupMeasurementState == .none)
        model.canMeasure = { !$0 }
        model.recordCleanup()
        await model.refreshAfterRemoval()
        #expect(model.cleanupMeasurementState == .requiresAccess)
        #expect(await service.measurementCount == 0)
        let reopened = DashboardModel(service: service, persistence: persistence, defaults: defaults)
        #expect(reopened.cleanupMeasurementState == .requiresAccess)
        let refresh = Task { await reopened.measureStorage() }
        try await waitUntil { await service.measurementCount == 1 }
        await service.finishMeasurement(0, dashboardMeasurement())
        await refresh.value
        #expect(await persistence.records == [.manual])
        #expect(!reopened.hasCleanupGrowthBaseline)
        #expect(reopened.cleanupMeasurementState == .none)
    }

    @Test("Launch removes a cleanup failure notice when no history exists", arguments: [
        DashboardModel.CleanupMeasurementState.failed, .interrupted, .requiresAccess
    ])
    func launchWithoutHistory(state: DashboardModel.CleanupMeasurementState) async throws {
        let suite = "DashboardCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(state.rawValue, forKey: "cleanupMeasurementState")
        let model = DashboardModel(service: HeldDashboardMeasurements(), persistence: HeldDashboardPersistence(),
                                   defaults: defaults)
        model.canMeasure = { !$0 }
        await model.loadDashboard()
        // Without access, the access notice keeps its Full Disk Access action.
        #expect(model.cleanupMeasurementState == (state == .requiresAccess ? .requiresAccess : .none))
    }

    @Test("A failed cleanup measurement keeps the earlier baseline and its date", arguments: [false, true])
    func failedCleanupKeepsBaseline(saveFailure: Bool) async throws {
        let folder = try TemporaryFolder()
        var logs: [ScanDiagnostics] = []
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        // The test changes the comparison choice, so it uses its own settings.
        let suite = "DashboardCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(service: service, persistence: persistence, defaults: defaults, beginDiagnostics: { _ in
            let log = try? ScanDiagnostics(directory: folder.url)
            if let log { logs.append(log) }
            return log
        })
        let first = Task { await model.measureStorage(trigger: .removal) }
        try await waitUntil { await service.measurementCount == 1 }
        #expect(model.cleanupMeasurementState == .measuring)
        await service.finishMeasurement(0, dashboardMeasurement())
        await first.value
        let originalDate = try #require(model.cleanupBaselineDate)
        #expect(model.cleanupMeasurementState == .none)
        // A cleanup without an earlier measurement has nothing to compare yet.
        #expect(model.growth == .insufficientHistory)
        #expect(model.growthBaselineOptions.isEmpty)
        let second = Task { await model.measureStorage(trigger: .removal) }
        model.recordTrashRemoval(.init(removedBytes: 300, removedCount: 1, trashedCount: 1))
        try await waitUntil { await service.measurementCount == 2 }
        if saveFailure {
            await persistence.rejectNextRecord()
            await service.finishMeasurement(1, dashboardMeasurement())
        } else {
            await service.failMeasurement(1)
        }
        await second.value
        #expect(model.cleanupMeasurementState == .failed)
        #expect(model.hasCleanupGrowthBaseline)
        #expect(model.cleanupBaselineDate == originalDate)
        #expect(model.trashNotice?.bytes == 300)
        let records = try diagnosticRecords(logs[1])
        let failure = try #require(records.first {
            $0.event == "span_end" && $0.details["outcome"] == "failed"
        })
        #expect(failure.details["operation"] == (saveFailure ? "history_record" : "storage_measurement"))
        #expect(failure.details["error_kind"] == "cocoa")
        #expect(failure.details["error_code"] != nil)
        #expect(records.last?.details["active_operations"] == "0")
        let refresh = Task { await model.measureStorage() }
        try await waitUntil { await service.measurementCount == 3 }
        await service.finishMeasurement(2, dashboardMeasurement(free: 300))
        await refresh.value
        #expect(await persistence.records == (saveFailure ? [.removal, .removal, .manual] : [.removal, .manual]))
        #expect(model.cleanupMeasurementState == .failed)
        #expect(model.cleanupBaselineDate == originalDate)
        // Both options start at the cleanup measurement, so only the cleanup option remains.
        #expect(model.growthBaselineOptions == [.lastCleanup])
        model.growthBaseline = .sevenDays
        #expect(model.growthBaseline == .lastCleanup)
    }

    @Test("A cleanup compares with the measurement before it, and the menu offers different starts")
    func cleanupComparesWithEarlierMeasurement() async throws {
        let suite = "DashboardCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = HeldDashboardMeasurements()
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence(), defaults: defaults)
        var dates: [Date] = []
        for (index, free) in [Int64(200), 250].enumerated() {
            let refresh = Task { await model.measureStorage() }
            try await waitUntil { await service.measurementCount == index + 1 }
            await service.finishMeasurement(index, dashboardMeasurement(free: free))
            await refresh.value
            dates.append(try #require(model.latestStorageMeasurement?.measuredAt))
        }
        model.recordCleanup()
        let after = Task { await model.refreshAfterRemoval() }
        try await waitUntil { await service.measurementCount == 3 }
        await service.finishMeasurement(2, dashboardMeasurement(free: 300))
        await after.value
        #expect(model.growthBaseline == .lastCleanup)
        #expect(model.growthBaselineOptions == [.lastCleanup, .sevenDays])
        #expect(model.cleanupBaselineDate == dates[1])
        #expect(model.sevenDayStart == dates[0])
        guard case .report(let report) = model.growth else {
            Issue.record("The cleanup measurement has no comparison")
            return
        }
        #expect(report.usedDeltaBytes == -50)
    }

    @Test("Queued cleanup measurements retain a reason when access changes or history is cleared", arguments: [false, true])
    func queuedCleanupCannotBePostponed(clear: Bool) async throws {
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let model = DashboardModel(service: service, persistence: persistence)
        let first = Task { await model.measureStorage() }
        try await waitUntil { await service.measurementCount == 1 }
        let removal = Task { await model.measureStorage(trigger: .removal) }
        try await waitUntil { model.cleanupMeasurementState == .measuring }
        // Let the request join the active measurement before changing its access.
        await Task.yield()
        if clear { model.clearMeasurementHistory() }
        else { model.canMeasure = { !$0 } }
        await service.finishMeasurement(0, dashboardMeasurement())
        await first.value
        await removal.value
        #expect(model.cleanupMeasurementState == (clear ? .cleared : .requiresAccess))
        #expect(!model.hasCleanupGrowthBaseline)
        let refresh = Task { await model.measureStorage() }
        try await waitUntil { await service.measurementCount == 2 }
        await service.finishMeasurement(1, dashboardMeasurement())
        await refresh.value
        #expect(await persistence.records.allSatisfy { $0 != .removal })
        #expect(!model.hasCleanupGrowthBaseline)
    }

    @Test("Restart reports an interrupted cleanup measurement without restoring its pending work")
    func cleanupRestart() async throws {
        let suite = "DashboardCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(service: HeldDashboardMeasurements(), persistence: HeldDashboardPersistence(), defaults: defaults)
        model.recordCleanup()
        let reopened = DashboardModel(service: HeldDashboardMeasurements(), persistence: HeldDashboardPersistence(), defaults: defaults)
        #expect(reopened.cleanupMeasurementState == .interrupted)
        reopened.clearMeasurementHistory()
        let cleared = DashboardModel(service: HeldDashboardMeasurements(), persistence: HeldDashboardPersistence(), defaults: defaults)
        #expect(cleared.cleanupMeasurementState == .cleared)
        #expect(!cleared.hasCleanupGrowthBaseline)
    }

    enum CleanupSource: CaseIterable { case cleanup, uninstaller, explorer, duplicates, emptyTrash }

    @Test("Each removal entry point creates a baseline only after successful removal", arguments: CleanupSource.allCases, [false, true])
    func cleanupEntryPoints(source: CleanupSource, removed: Bool) async throws {
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let app = AppModel(hasFullDiskAccess: { true }, dashboardService: service, dashboardPersistence: persistence)
        let outcome = CleanupOutcome(removedBytes: removed ? 100 : 0, removedCount: removed ? 1 : 0, trashedCount: removed ? 1 : 0)
        let refresh = Task {
            switch source {
            case .cleanup:
                app.view = .scanner
                app.cleanup.onEvent(.removed(outcome))
                await app.cleanup.refreshAfterRemoval()
            case .uninstaller:
                app.uninstaller.onEvent(.removed(outcome))
                await app.uninstaller.refreshAfterRemoval()
            case .explorer:
                app.storageExplorer.onEvent(.removed(outcome))
                await app.storageExplorer.refreshAfterRemoval()
            case .duplicates:
                app.fileDuplicates.onEvent(.removed(outcome, extraFailures: 0))
                await app.fileDuplicates.refreshAfterRemoval()
            case .emptyTrash:
                app.recovery.onEvent(.emptiedTrash(freedBytes: removed ? 100 : 0, skippedURLs: []))
                await app.recovery.refreshAfterMutation(.emptyTrash)
            }
        }
        try await waitUntil { await service.measurementCount == 1 }
        await service.finishMeasurement(0, dashboardMeasurement())
        await refresh.value
        #expect(await persistence.records == [removed ? .removal : .scheduled])
        #expect(app.dashboard.hasCleanupGrowthBaseline == removed)
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

    @Test("Missing cloud access has setup guidance without starting a measurement")
    func cloudRequiresAccess() async {
        let service = HeldDashboardMeasurements()
        let app = AppModel(launchAccess: .limited, hasFullDiskAccess: { false }, dashboardService: service)
        await app.dashboard.loadICloud()
        #expect(app.dashboard.iCloudState == .requiresAccess)
        #expect(await service.cloudPlans.isEmpty)
        #expect(app.launchAccess == .limited)
    }

    @Test("Cloud refreshes retain measured storage until the replacement arrives")
    func cloudRefreshKeepsMeasuredCard() async throws {
        let service = HeldDashboardMeasurements(holdCloud: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence())
        let initial = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 1 }
        let measured = ICloudStorage(totalBytes: 200, freeBytes: 40, documentsBytes: 80)
        await service.finishCloud(0, measured)
        await initial.value

        let refresh = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 2 }
        #expect(model.iCloudState == .available(measured))
        #expect(model.iCloudStorage == measured)
        let updated = ICloudStorage(totalBytes: 200, freeBytes: 30, documentsBytes: 90)
        await service.finishCloud(1, updated)
        await refresh.value
        #expect(model.iCloudState == .available(updated))
    }

    enum ICloudSetupResult: CaseIterable { case missingAccess, failure, success }

    @Test("Pending cloud setup returns to Dashboard after restart and reopens only when needed", arguments: ICloudSetupResult.allCases)
    func cloudSetupRestart(result: ICloudSetupResult) async throws {
        let suite = "DashboardCloudTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        #expect(!settings.hasPendingICloudSetup)
        let original = DashboardModel(service: HeldDashboardMeasurements(), settings: settings)
        original.beginICloudSetup()

        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        let reopenedSettings = SettingsStore(defaults: reopenedDefaults, managesLoginItem: false)
        let service = HeldDashboardMeasurements(holdCloud: true)
        let hasAccess = result != .missingAccess
        let reopened = AppModel(
            settings: reopenedSettings, launchAccess: hasAccess ? .ready : .limited,
            hasFullDiskAccess: { hasAccess }, dashboardService: service,
            dashboardPersistence: HeldDashboardPersistence()
        )
        #expect(reopened.view == .dashboard)
        #expect(reopened.dashboard.hasPendingICloudSetup)
        #expect(!reopened.dashboard.shouldResumeICloudSetup)
        reopened.startInitialCleanupScan()
        #expect(!reopened.cleanup.hasStartedInitialScan)
        let check = Task { await reopened.dashboard.loadICloud() }
        if hasAccess {
            try await waitUntil { await service.cloudPlans.count == 1 }
            #expect(!reopened.dashboard.shouldResumeICloudSetup)
            if result == .success {
                await service.finishCloud(0, ICloudStorage(totalBytes: 200, freeBytes: 40, documentsBytes: 80))
            } else {
                await service.failCloud(0)
            }
        }
        await check.value
        #expect(await service.cloudPlans.count == (hasAccess ? 1 : 0))
        #expect(reopened.dashboard.shouldResumeICloudSetup == (result != .success))
        #expect(reopenedSettings.hasPendingICloudSetup == (result != .success))
        #expect(SettingsStore(defaults: reopenedDefaults, managesLoginItem: false).hasPendingICloudSetup == (result != .success))

        reopened.dashboard.finishICloudSetup()
        let finishedSettings = SettingsStore(defaults: reopenedDefaults, managesLoginItem: false)
        #expect(!finishedSettings.hasPendingICloudSetup)
        let later = AppModel(settings: finishedSettings, hasFullDiskAccess: { hasAccess }, dashboardService: service)
        #expect(later.view == .scanner)
        #expect(!later.dashboard.shouldResumeICloudSetup)
    }

    @Test("Cloud failures remain visible and a retry restores measured storage")
    func cloudFailureAndRetry() async throws {
        let service = HeldDashboardMeasurements(holdCloud: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence())
        #expect(model.iCloudState == .idle)
        let first = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 1 }
        #expect(model.iCloudState == .loading)
        await service.failCloud(0)
        await first.value
        #expect(model.iCloudState == .unavailable)
        #expect(model.iCloudStorage == nil)
        let retry = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 2 }
        #expect(model.iCloudState == .unavailable)
        await service.failCloud(1)
        await retry.value
        #expect(model.iCloudState == .unavailable)
        let success = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 3 }
        #expect(model.iCloudState == .unavailable)
        let storage = ICloudStorage(totalBytes: 200, freeBytes: 40, documentsBytes: 80)
        await service.finishCloud(2, storage)
        await success.value
        #expect(model.iCloudState == .available(storage))
    }

    @Test("Cloud retries keep card and setup sizes unchanged", .serialized, arguments: [false, true])
    func cloudRetryLayouts(dark: Bool) async throws {
        let service = HeldDashboardMeasurements(holdCloud: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence())
        let initial = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 1 }
        await service.failCloud(0)
        await initial.value
        let setup = ICloudSetupView(model: model, access: .preview(disk: true))
        let sheetBefore = try await renderTestView(
            setup, width: 560, dark: dark,
            output: URL(fileURLWithPath: "/tmp/moppo-230-setup-before-\(dark).png")
        )
        for width in [788.0, 908.0] {
            let before = try await renderTestView(
                StatTiles(results: nil, iCloudState: model.iCloudState),
                width: width, dark: dark,
                output: URL(fileURLWithPath: "/tmp/moppo-230-card-before-\(Int(width))-\(dark).png")
            )
            let count = await service.cloudPlans.count
            let retry = Task { await model.loadICloud() }
            try await waitUntil { await service.cloudPlans.count > count }
            #expect(model.iCloudState == .unavailable)
            let during = try await renderTestView(
                StatTiles(results: nil, iCloudState: model.iCloudState),
                width: width, dark: dark,
                output: URL(fileURLWithPath: "/tmp/moppo-230-card-during-\(Int(width))-\(dark).png")
            )
            let sheetDuring = try await renderTestView(
                setup, width: 560, dark: dark,
                output: URL(fileURLWithPath: "/tmp/moppo-230-setup-during-\(dark).png")
            )
            #expect(before == during)
            #expect(sheetBefore == sheetDuring)
            await service.failCloud(count)
            await retry.value
            #expect(model.iCloudState == .unavailable)
        }
    }

    @Test("Hidden cloud cards skip measurements and reject an active result")
    func hiddenCloud() async throws {
        let suite = "DashboardCloudTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        let service = HeldDashboardMeasurements(holdCloud: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence(), settings: settings)
        settings.showICloudOnDashboard = false
        await model.loadICloud()
        #expect(await service.cloudPlans.isEmpty)
        settings.showICloudOnDashboard = true
        model.beginICloudSetup()
        #expect(model.hasPendingICloudSetup)
        let caller = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 1 }
        settings.showICloudOnDashboard = false
        await model.loadICloud()
        await service.finishCloud(0, ICloudStorage(totalBytes: 200, freeBytes: 40, documentsBytes: 80))
        await caller.value
        #expect(model.iCloudState == .idle)
        #expect(!model.showsICloudOnDashboard)
        #expect(!model.hasPendingICloudSetup)
    }

    @Test("Revoked cloud access rejects an active measurement without reopening onboarding")
    func revokedCloudAccess() async throws {
        var hasAccess = true
        let service = HeldDashboardMeasurements(holdCloud: true)
        let app = AppModel(hasFullDiskAccess: { hasAccess }, dashboardService: service)
        let caller = Task { await app.dashboard.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 1 }
        hasAccess = false
        await service.finishCloud(0, ICloudStorage(totalBytes: 200, freeBytes: 40, documentsBytes: 80))
        await caller.value
        #expect(app.dashboard.iCloudState == .requiresAccess)
        #expect(!app.isShowingWelcome)
    }

    @Test("Interrupted cloud measurements return to a state with a recovery action")
    func interruptedCloud() async throws {
        let service = HeldDashboardMeasurements(holdCloud: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence(), settings: .preview())
        model.beginICloudSetup()
        let caller = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 1 }
        let pause = Task { await model.pauseMeasurementForScan() }
        await Task.yield()
        await service.finishCloud(0, ICloudStorage(totalBytes: 200, freeBytes: 40, documentsBytes: 80))
        await pause.value
        await caller.value
        #expect(model.iCloudState == .idle)
        #expect(model.hasPendingICloudSetup)
        #expect(!model.shouldResumeICloudSetup)
    }

    @Test("Concurrent cloud reads share a request and automatic plan selection clears the override")
    func cloudSettingsPlan() async throws {
        let suite = "DashboardCloudTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        settings.iCloudPlan = .gb200
        let service = HeldDashboardMeasurements(holdCloud: true)
        let model = DashboardModel(service: service, persistence: HeldDashboardPersistence(), settings: settings)
        model.iCloudPlanBytes = 123
        let first = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 1 }
        let duplicate = Task { await model.loadICloud() }
        await Task.yield()
        settings.iCloudPlan = .automatic
        let automatic = Task { await model.loadICloud() }
        try await waitUntil { await service.cloudPlans.count == 2 }
        await service.finishCloud(1, ICloudStorage(totalBytes: 100, freeBytes: 40, documentsBytes: 20))
        await automatic.value
        await service.failCloud(0)
        await first.value
        await duplicate.value
        #expect(await service.cloudPlans == [ICloudPlan.gb200.bytes, nil])
        #expect(model.iCloudStorage?.totalBytes == 100)
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

    enum Accounting: CaseIterable { case balanced, invalid, reconciled }

    @Test("Captured laptop totals preserve free space and valid cleanup baselines", arguments: Accounting.allCases)
    func allocatedTotalsExceedUsage(accounting: Accounting) async throws {
        let folder = try TemporaryFolder()
        let log = try ScanDiagnostics(directory: folder.url)
        let capacity: Int64 = 1_995_165_736_960
        let physicalUsed: Int64 = 218_835_329_024
        let volume = VolumeInfo(name: "Fixture", capacityBytes: capacity, freeBytes: capacity - physicalUsed,
                                filesystem: "apfs", isEncrypted: true)
        var raw: [StorageSegmentID: Int64] = [
            .documentsDesktop: 54_684_303_360, .macOSSystem: 50_250_059_776, .appDataCaches: 39_739_523_072,
            .systemData: 28_558_753_792, .otherFilesInHome: 27_422_326_784, .packageBuildCaches: 21_540_864_000,
            .applications: 19_171_778_560, .downloads: 552_005_632, .photos: 23_085_056, .music: 307_200,
            .movies: 32_768, .developer: 0, .unmeasured: 0, .free: volume.freeBytes
        ]
        if accounting == .balanced { raw[.documentsDesktop]! -= 23_107_710_976 }
        let allocated = raw.filter { $0.key != .free }.values.reduce(0, +)
        let original = StorageBreakdown.make(capacityBytes: capacity, rawSegments: raw, unreadableCount: 234)
        let breakdown = accounting == .reconciled
            ? original.reconcilingVolume(capacityBytes: capacity, freeBytes: volume.freeBytes) : original
        let measurement = StorageMeasurement(
            home: URL(fileURLWithPath: "/private-fixture"), volume: volume,
            breakdown: breakdown,
            rawSegments: raw, homeTree: [:], rootMeasurements: [:], nodeDepth: 4
        )
        let store = StorageSnapshotStore(directory: folder.url.appendingPathComponent("history"))
        let service = HeldDashboardMeasurements(volume: volume)
        let history = DashboardPersistence(snapshots: store)
        let persistence = HeldDashboardPersistence(recordHistory: { try await history.record($0, trigger: $1) })
        let model = DashboardModel(service: service, persistence: persistence,
                                   beginDiagnostics: { _ in log })
        model.recordTrashRemoval(.init(removedBytes: 4_405_153_792, removedCount: 2, trashedCount: 2))
        let task = Task { await model.measureStorage(trigger: .removal) }
        try await waitUntil { await service.measurementCount == 1 }
        await service.finishMeasurement(0, measurement)
        await task.value
        let valid = accounting != .invalid
        #expect(model.cleanupMeasurementState == (valid ? .none : .failed))
        #expect(model.hasCleanupGrowthBaseline == valid)
        #expect(store.load().count == (valid ? 1 : 0))
        if let snapshot = store.load().first {
            #expect(snapshot.rawSegments == raw)
            #expect(snapshot.volume.freeBytes == volume.freeBytes)
            #expect(snapshot.breakdown.freeBytes == volume.freeBytes)
            #expect(snapshot.breakdown.categorySegments == breakdown.categorySegments)
        }
        #expect(model.trashNotice?.bytes == 4_405_153_792)
        let records = try diagnosticRecords(log)
        let result = try #require(records.first { $0.event == "measurement_result" })
        #expect(result.details["allocated_category_bytes"] == "\(allocated)")
        #expect(result.details["physical_used_bytes"] == "\(physicalUsed)")
        #expect(result.details["consistent"] == "\(valid)")
        let display = try #require(records.first { $0.event == "display_reconciliation" })
        #expect(display.details["consistent"] == "true")
        #expect(display.details["physical_free_bytes"] == "\(volume.freeBytes)")
        #expect(display.details["free_bytes"] == "\(volume.freeBytes)")
        let validation = try #require(records.first {
            $0.event == "span_end" && $0.details["operation"] == "snapshot_validation"
        })
        #expect(validation.details["outcome"] == (valid ? "completed" : "failed"))
        #expect(records.contains { $0.details["operation"] == "history_write" } == valid)
        #expect(records.last?.details["active_operations"] == "0")
        #expect(!String(decoding: try Data(contentsOf: log.fileURL), as: UTF8.self).contains("private-fixture"))
        if accounting == .reconciled {
            let previews = URL(fileURLWithPath: "/tmp/moppo-229-capacity-previews")
            try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
            for width: CGFloat in [500, 900] {
                for dark in [false, true] {
                    _ = try await renderTestView(CapacityCard(volume: volume, breakdown: model.breakdown).background(Token.chrome),
                        width: width, dark: dark, output: previews.appendingPathComponent("\(Int(width))-\(dark).png"))
                }
            }
        }
    }

    @Test("Dashboard logs separate waiting, replacement, active work, and cancellation")
    func measurementDiagnostics() async throws {
        let folder = try TemporaryFolder()
        var logs: [ScanDiagnostics] = []
        let gate = TestGate()
        let service = HeldDashboardMeasurements()
        let persistence = HeldDashboardPersistence()
        let model = DashboardModel(service: service, persistence: persistence, beginDiagnostics: { _ in
            let log = try? ScanDiagnostics(directory: folder.url)
            if let log { logs.append(log) }
            return log
        })
        model.beforeMeasurement = { await gate.wait(); return true }
        let first = Task { await model.measureStorage() }
        try await waitUntil { await gate.isPending }
        #expect(await service.measurementCount == 0)
        model.dismissLowSpaceWarning()
        #expect(model.isLowSpaceWarningDismissed)
        await gate.finish()
        model.beforeMeasurement = { true }
        try await waitUntil { await service.measurementCount == 1 }
        let removal = Task { await model.measureStorage(trigger: .removal) }
        try await waitUntil { logs.count == 2 && (try? diagnosticRecords(logs[1]).contains { $0.event == "cleanup_queued" }) == true }
        let replacement = Task { await model.measureStorage(trigger: .removal) }
        try await waitUntil { logs.count == 3 && (try? diagnosticRecords(logs[2]).contains { $0.event == "cleanup_queued" }) == true }
        await service.finishMeasurement(0, dashboardMeasurement())
        try await waitUntil { await service.measurementCount == 2 }
        let pause = Task { await model.pauseMeasurementForScan() }
        try await waitUntil { (try? diagnosticRecords(logs[0]).contains { $0.event == "measurement_cancel_requested" }) == true }
        await service.finishMeasurement(1, dashboardMeasurement())
        await pause.value
        await first.value
        await removal.value
        await replacement.value
        #expect(model.cleanupMeasurementState == .interrupted)
        #expect(await persistence.records == [.manual])
        let active = try diagnosticRecords(logs[0])
        #expect(active.contains { $0.details["operation"] == "cleanup_worker_wait" && $0.event == "span_end" })
        #expect(active.filter { $0.details["operation"] == "dashboard_measurement" && $0.event == "span_end" }.map {
            $0.details["outcome"]
        } == ["saved", "cancelled"])
        #expect(try diagnosticRecords(logs[1]).last?.details["outcome"] == "replaced")
        #expect(try diagnosticRecords(logs[2]).contains { $0.details["operation"] == "measurement_wait" })
        for log in logs {
            let records = try diagnosticRecords(log)
            #expect(records.last?.details["active_operations"] == "0")
            #expect(records.filter { $0.event == "span_end" }.allSatisfy {
                Double($0.details["duration_seconds"] ?? "") != nil
            })
        }
    }
}

private actor HeldDashboardMeasurements: DashboardMeasuring {
    let holdCloud: Bool
    let holdVolume: Bool
    let volume: VolumeInfo
    private(set) var measurementCount = 0
    private(set) var cloudPlans: [Int64?] = []
    private(set) var volumeCount = 0
    private(set) var cancelled: [Bool] = []
    private var measurements: [Int: CheckedContinuation<StorageMeasurement, Error>] = [:]
    private var clouds: [Int: CheckedContinuation<ICloudStorage, Error>] = [:]
    private var volumes: [Int: CheckedContinuation<VolumeInfo, Never>] = [:]
    init(holdCloud: Bool = false, holdVolume: Bool = false, volume: VolumeInfo = dashboardVolume()) {
        self.holdCloud = holdCloud
        self.holdVolume = holdVolume
        self.volume = volume
    }
    func volumeInfo() async throws -> VolumeInfo {
        let index = volumeCount
        volumeCount += 1
        if holdVolume { return await withCheckedContinuation { volumes[index] = $0 } }
        return volume
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
        if holdCloud { return try await withCheckedThrowingContinuation { clouds[index] = $0 } }
        return ICloudStorage(totalBytes: planBytes ?? 100, freeBytes: 20, documentsBytes: 40)
    }
    func finishMeasurement(_ index: Int, _ value: StorageMeasurement) { measurements.removeValue(forKey: index)?.resume(returning: value) }
    func failMeasurement(_ index: Int) { measurements.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func finishCloud(_ index: Int, _ value: ICloudStorage) { clouds.removeValue(forKey: index)?.resume(returning: value) }
    func failCloud(_ index: Int) { clouds.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func finishVolume(_ index: Int, _ value: VolumeInfo) { volumes.removeValue(forKey: index)?.resume(returning: value) }
}

private actor HeldDashboardPersistence: DashboardPersisting {
    let holdHistory: Bool
    let holdRecord: Bool
    let recordHistory: (@Sendable (StorageMeasurement, SnapshotTrigger) async throws -> [StorageSnapshot])?
    private(set) var cache: BreakdownCache?
    private(set) var cacheLoads = 0
    private(set) var cacheClears = 0
    private(set) var historyLoads = 0
    private(set) var records: [SnapshotTrigger] = []
    private(set) var clearCount = 0
    private var history: [StorageSnapshot] = []
    private var rejectsNextRecord = false
    private var historyReply: CheckedContinuation<[StorageSnapshot], Never>?
    private var recordReply: CheckedContinuation<[StorageSnapshot], Never>?
    init(cache: BreakdownCache? = nil, holdHistory: Bool = false, holdRecord: Bool = false,
         recordHistory: (@Sendable (StorageMeasurement, SnapshotTrigger) async throws -> [StorageSnapshot])? = nil) {
        self.cache = cache
        self.holdHistory = holdHistory
        self.holdRecord = holdRecord
        self.recordHistory = recordHistory
    }
    func loadCache() -> BreakdownCache? { cacheLoads += 1; return cache }
    func saveCache(_ cache: BreakdownCache) { self.cache = cache }
    func clearCache() { cache = nil; cacheClears += 1 }
    func loadHistory() async -> [StorageSnapshot] {
        historyLoads += 1
        if holdHistory { return await withCheckedContinuation { historyReply = $0 } }
        return history
    }
    func rejectNextRecord() { rejectsNextRecord = true }
    func record(_ measurement: StorageMeasurement, trigger: SnapshotTrigger) async throws -> [StorageSnapshot] {
        records.append(trigger)
        if rejectsNextRecord {
            rejectsNextRecord = false
            throw CocoaError(.fileWriteNoPermission)
        }
        if holdRecord { return await withCheckedContinuation { recordReply = $0 } }
        if let recordHistory {
            history = try await recordHistory(measurement, trigger)
            return history
        }
        if let snapshot = SnapshotCapture.snapshot(from: measurement, trigger: trigger) { history.insert(snapshot, at: 0) }
        return history
    }
    func clearHistory() { clearCount += 1; history = [] }
    func finishHistory(_ history: [StorageSnapshot]) { historyReply?.resume(returning: history); historyReply = nil }
    func finishRecord(_ history: [StorageSnapshot]) { recordReply?.resume(returning: history); recordReply = nil }
}
