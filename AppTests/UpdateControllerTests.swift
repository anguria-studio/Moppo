import AppKit
import Foundation
import Sparkle
import Testing

@Suite("Application updates")
@MainActor
struct UpdateControllerTests {
    private var configuration: UpdateConfiguration {
        UpdateConfiguration(feedURL: "https://updates.example.test/appcast.xml", publicKey: Data(repeating: 1, count: 32).base64EncodedString())!
    }

    @Test("An unconfigured build makes no update requests")
    func unconfiguredBuild() {
        var serviceCreated = false
        let updates = UpdateController(operations: OperationCoordinator(), configuration: nil) { _ in
            serviceCreated = true
            return TestUpdateService()
        }
        updates.start()
        updates.checkForUpdates()
        #expect(!serviceCreated)
        #expect(!updates.isAvailable)
        #expect(!updates.canCheckForUpdates)
        #expect(updates.statusMessage != nil)
    }

    @Test("Update checks follow persisted preferences and current availability")
    func checkPreferences() {
        let service = TestUpdateService()
        service.automaticallyChecksForUpdates = true
        let updates = UpdateController(operations: OperationCoordinator(), configuration: configuration) { _ in service }
        updates.start()
        updates.start()
        #expect(service.startCount == 1)
        #expect(updates.automaticallyChecksForUpdates)
        updates.automaticallyChecksForUpdates = false
        #expect(!service.automaticallyChecksForUpdates)
        updates.checkForUpdates()
        #expect(service.checkCount == 1)
        service.onAvailabilityChange?(false)
        updates.checkForUpdates()
        #expect(service.checkCount == 1)
    }

    @Test("Startup failure disables checks and permits a later retry")
    func startFailure() {
        let service = TestUpdateService()
        service.startError = CocoaError(.fileReadUnknown)
        let updates = UpdateController(operations: OperationCoordinator(), configuration: configuration) { _ in service }
        updates.start()
        #expect(!updates.isAvailable)
        updates.checkForUpdates()
        #expect(service.checkCount == 0)
        service.startError = nil
        updates.start()
        #expect(updates.isAvailable)
        #expect(updates.canCheckForUpdates)
        #expect(updates.statusMessage == nil)
    }

    @Test("Installation waits through consecutive operations and blocks new work")
    func installationWaits() async throws {
        let operations = OperationCoordinator()
        let gate = UpdateInstallationGate(operations: operations)
        let scan = try #require(operations.begin(.cleanupScan))
        var installations = 0
        gate.schedule { installations += 1 }
        await Task.yield()
        #expect(gate.isWaiting)
        #expect(installations == 0)
        operations.finish(scan)
        let restore = try #require(operations.begin(.trashRestoration))
        await Task.yield()
        #expect(installations == 0)
        operations.finish(restore)
        try await waitUntil { installations == 1 }
        #expect(operations.activeOperation?.kind == .updateInstallation)
        #expect(operations.begin(.appUninstall) == nil)
        #expect(!gate.isWaiting)
        gate.cancel()
        #expect(!operations.isBusy)
    }

    @Test("Canceled installation cannot resume after the current operation finishes")
    func cancelWaitingInstallation() async throws {
        let operations = OperationCoordinator()
        let gate = UpdateInstallationGate(operations: operations)
        let operation = try #require(operations.begin(.emptyTrash))
        var installed = false
        gate.schedule { installed = true }
        await Task.yield()
        gate.cancel()
        #expect(operations.activeOperation == operation)
        operations.finish(operation)
        await Task.yield()
        #expect(!installed)
        #expect(!operations.isBusy)
    }

    @Test("App termination waits for disk work and permits the reserved update installation")
    func terminationSafety() throws {
        let operations = OperationCoordinator()
        let delegate = AppDelegate()
        delegate.operations = operations
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
        let work = try #require(operations.begin(.fileRemoval))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        operations.finish(work)
        _ = try #require(operations.begin(.updateInstallation))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test("Quit stops Cleanup and replies once after its workers return", arguments: [false, true])
    func quitDuringScan(alreadyStopping: Bool) async throws {
        let scanner = HeldCleanupScanner()
        let app = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        let delegate = AppDelegate()
        delegate.operations = app.operations
        var replies = 0
        delegate.completeTermination = { _ in replies += 1 }
        app.cleanup.startScan(refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        if alreadyStopping { app.cleanup.cancelScan() }

        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(app.cleanup.isInterruptingScan)
        #expect(app.operations.isTerminating)
        #expect(app.operations.activeOperation?.kind == .cleanupScan)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        await Task.yield()
        #expect(replies == 0)
        #expect(app.operations.begin(.fileRemoval) == nil)

        await scanner.fail(0)
        try await waitUntil { replies == 1 }
        #expect(!app.cleanup.isScanning)
        #expect(app.cleanup.scanResults == nil)
        #expect(app.notice == nil)
        #expect(app.operations.activeOperation == nil)
        #expect(app.operations.begin(.cleanupScan) == nil)
        await Task.yield()
        #expect(replies == 1)
    }

    @Test("Immediate scan cancellation replies after the termination decision")
    func immediateScanTermination() async throws {
        let operations = OperationCoordinator()
        let delegate = AppDelegate()
        delegate.operations = operations
        var replies = 0
        var cancellations = 0
        delegate.completeTermination = { _ in replies += 1 }
        _ = try #require(operations.begin(.fileScan, cancel: {
            cancellations += 1
            if let operation = operations.activeOperation { operations.finish(operation) }
        }))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(replies == 0)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(cancellations == 1)
        #expect(operations.begin(.updateInstallation) == nil)
        try await waitUntil { replies == 1 }
    }

    @Test("A completed Sparkle cycle cancels a deferred installation without an error")
    func completedCycleCancelsInstallation() async throws {
        let operations = OperationCoordinator()
        let updates = UpdateController(operations: operations, configuration: configuration) { _ in TestUpdateService() }
        let work = try #require(operations.begin(.fileRemoval))
        var installed = false
        updates.installation.schedule { installed = true }
        let sparkle = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: updates, userDriverDelegate: nil)
        let delegate: any SPUUpdaterDelegate = updates
        delegate.updater?(sparkle.updater, didFinishUpdateCycleFor: .updates, error: nil)
        #expect(!updates.installation.isWaiting)
        operations.finish(work)
        await Task.yield()
        #expect(!installed)
        #expect(!operations.isBusy)
    }

    @Test("Feed configuration refuses insecure URLs and incomplete signing keys")
    func secureConfiguration() {
        #expect(UpdateConfiguration(feedURL: "http://updates.example.test/appcast.xml", publicKey: configuration.publicKey) == nil)
        #expect(UpdateConfiguration(feedURL: "https://user:password@updates.example.test/appcast.xml", publicKey: configuration.publicKey) == nil)
        #expect(UpdateConfiguration(feedURL: configuration.feedURL.absoluteString, publicKey: "missing") == nil)
        #expect(UpdateConfiguration(feedURL: configuration.feedURL.absoluteString, publicKey: configuration.publicKey) != nil)
    }
}

@MainActor
private final class TestUpdateService: UpdateServicing {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    var onAvailabilityChange: ((Bool) -> Void)?
    var startError: Error?
    var startCount = 0
    var checkCount = 0
    func start() throws {
        startCount += 1
        if let startError { throw startError }
    }
    func checkForUpdates() { checkCount += 1 }
}
