import AppKit
import SwiftUI
import Testing
@testable import MoppoCore

@Suite("Menu bar controls")
@MainActor
struct MenuBarTests {
    @Test("Opening the panel in either appearance starts no disk work", arguments: [false, true])
    func openingPanel(dark: Bool) async throws {
        let scanner = HeldCleanupScanner()
        let dashboard = HeldDashboardMeasurements()
        let app = AppModel(hasFullDiskAccess: { true }, trashService: UnreadableTrash(),
                           dashboardService: dashboard, dashboardPersistence: HeldDashboardPersistence(),
                           cleanupScanner: scanner)
        let output = ProcessInfo.processInfo.environment["MOPPO_MENU_PREVIEW_DIRECTORY"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("menu-bar-\(dark ? "dark" : "light")-empty.png")
        }
        let size = try await renderTestView(MenuBarView(model: app), width: 288, dark: dark, output: output)

        #expect(size.width == 288)
        #expect(size.height < 450)
        #expect(await scanner.requestCount == 0)
        #expect(await dashboard.volumeCount == 0)
        #expect(await dashboard.measurementCount == 0)
        #expect(!app.recovery.hasLoadedTrash)
        #expect(app.cleanup.scanResults == nil)
        #expect(app.menuBar.canStart(in: app))
    }

    @Test("Reload refreshes all readings without navigation or a Dashboard measurement")
    func reload() async throws {
        let folder = try TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        _ = try folder.write(".Trash/item")
        let scanner = HeldCleanupScanner()
        let dashboard = HeldDashboardMeasurements()
        let app = AppModel(hasFullDiskAccess: { true }, trashService: TrashService(home: folder.url),
                           dashboardService: dashboard, dashboardPersistence: HeldDashboardPersistence(),
                           cleanupScanner: scanner)
        app.view = .history

        app.menuBar.refresh(in: app)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.report(0, percent: 42, phase: "Checking caches")
        try await waitUntil { app.cleanup.scanProgress == 42 }
        #expect(!app.menuBar.canStart(in: app))
        #expect(app.view == .history)

        // A replacement panel reads the same progress without starting another scan.
        _ = try await renderTestView(MenuBarView(model: app), width: 288, dark: true)
        #expect(await scanner.requestCount == 1)
        #expect(app.cleanup.scanProgress == 42)
        await scanner.finish(0, results: ScanResults(categories: [], startedAt: .now, finishedAt: .now))
        #expect(await app.cleanup.waitForScan())
        try await waitUntil { !app.menuBar.isRefreshing }

        #expect(await dashboard.volumeCount == 1)
        #expect(await dashboard.measurementCount == 0)
        #expect(app.dashboard.volume == dashboardVolume())
        #expect(app.recovery.trashSummary?.itemCount == 1)
        #expect(app.recovery.trashMeasuredAt != nil)
        #expect(app.recovery.trashReadError == nil)
        #expect(app.menuBar.status?.message == "Scan complete.")
        #expect(app.menuBar.canStart(in: app))
        #expect(app.view == .history)
    }

    @Test("Delete remains available without a result or with a zero result", arguments: [false, true])
    func deleteWithoutKnownItems(hasResult: Bool) async throws {
        let folder = try TemporaryFolder()
        let safe = FileEntry(url: try folder.write("cache"), kind: .cache, allocatedBytes: 128_000_000, isRegenerable: true)
        let scanner = HeldCleanupScanner()
        let remover = HeldCleanupRemoval()
        let app = AppModel(hasFullDiskAccess: { true }, trashService: TrashService(home: folder.url),
                           dashboardService: HeldDashboardMeasurements(), dashboardPersistence: HeldDashboardPersistence(),
                           cleanupScanner: scanner, cleanupRemover: remover)
        if hasResult {
            app.cleanup.scanResults = ScanResults(categories: [], startedAt: .distantPast, finishedAt: .distantPast)
        }
        app.view = .history
        #expect(app.menuBar.canStart(in: app))

        app.menuBar.deleteSafeToRemove(in: app)
        try await waitUntil { await scanner.requestCount == 1 }
        #expect(await remover.requestCount == 0)
        await scanner.finish(0, results: ScanResults(categories: [
            ScanCategoryResult(categoryID: .systemCaches, totalBytes: 128_000_000, entries: [safe])
        ], startedAt: .now, finishedAt: .now))
        try await waitUntil { await remover.isPending }
        #expect(await remover.entries.map(\.id) == [safe.id])
        #expect(app.activeSheet == nil)
        await remover.finish(CleanupOutcome(removedBytes: 128_000_000, removedCount: 1, trashedCount: 1))
        try await waitUntil { !app.isBusyWithDisk }

        #expect(app.menuBar.status?.message == "128.0 MB removed.")
        #expect(app.menuBar.status?.isFailure == false)
        #expect(app.view == .history)
    }

    @Test("Blocked Reload reports guidance without starting any refresh", arguments: [LaunchAccess.welcome, .limited, .ready])
    func missingAccess(access: LaunchAccess) async throws {
        let scanner = HeldCleanupScanner()
        let dashboard = HeldDashboardMeasurements()
        let app = AppModel(launchAccess: access, hasFullDiskAccess: { false }, trashService: UnreadableTrash(),
                           dashboardService: dashboard, dashboardPersistence: HeldDashboardPersistence(),
                           cleanupScanner: scanner)
        app.menuBar.refresh(in: app)

        let expected: MoppoOperationError = access == .welcome ? .welcomeGuideIncomplete : .backgroundAccessRequired
        #expect(app.menuBar.status?.message == expected.errorDescription)
        #expect(app.menuBar.status?.isFailure == true)
        #expect(await scanner.requestCount == 0)
        #expect(await dashboard.volumeCount == 0)
        #expect(!app.recovery.hasLoadedTrash)
        #expect(!app.menuBar.isRefreshing)
        #expect(!app.isBusyWithDisk)
    }

    @Test("Stop keeps the shared guard until scan workers finish")
    func stop() async throws {
        let scanner = HeldCleanupScanner()
        let app = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        app.menuBar.deleteSafeToRemove(in: app)
        try await waitUntil { await scanner.requestCount == 1 }
        let operation = try #require(app.operations.activeOperation)

        app.operations.cancel()

        #expect(app.cleanup.isInterruptingScan)
        #expect(app.operations.activeOperation == operation)
        #expect(!app.menuBar.canStart(in: app))
        await scanner.finish(0, results: ScanResults(categories: [], startedAt: .now, finishedAt: .now))
        #expect(await app.cleanup.waitForScan() == false)
        #expect(!app.isBusyWithDisk)
        #expect(app.menuBar.status?.message == "Scan stopped. No items were removed.")
    }

    @Test("A scan failure remains visible after its workers finish")
    func failedScan() async throws {
        let scanner = HeldCleanupScanner()
        let app = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        app.menuBar.deleteSafeToRemove(in: app)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.fail(0)

        #expect(await app.cleanup.waitForScan() == false)
        #expect(app.menuBar.status?.isFailure == true)
        #expect(app.menuBar.status?.message.contains("could not finish") == true)
        #expect(app.cleanup.scanResults == nil)
    }

    @Test("Busy operations disable menu actions without replacing the active operation")
    func busy() throws {
        let app = AppModel(hasFullDiskAccess: { true })
        let operation = try #require(app.operations.begin(.emptyTrash))
        defer { app.operations.finish(operation) }
        #expect(!app.menuBar.canStart(in: app))
        app.menuBar.refresh(in: app)
        #expect(app.operations.activeOperation == operation)
        #expect(app.menuBar.status?.isFailure == true)
        #expect(!app.menuBar.isRefreshing)
        #expect(!app.cleanup.hasStartedInitialScan)
        #expect(!app.operations.canCancel)
    }

    @Test("Unreadable Trash reports access guidance without a false zero")
    func unreadableTrash() async {
        let app = AppModel(trashService: UnreadableTrash())
        await app.recovery.loadTrash()
        #expect(app.recovery.trashSummary == nil)
        #expect(app.recovery.trashMeasuredAt == nil)
        #expect(app.recovery.trashReadError?.contains("Full Disk Access") == true)
    }

    @Test("Partial removal results remain visible in the menu bar")
    func partialResult() {
        let app = AppModel()
        app.cleanup.onEvent(.removed(CleanupOutcome(removedBytes: 128_000_000, removedCount: 1, failed: ["/fixture/kept"])))
        #expect(app.menuBar.status?.isFailure == true)
        #expect(app.menuBar.status?.message == "128.0 MB removed. Some items need review in Moppo.")
    }
}
