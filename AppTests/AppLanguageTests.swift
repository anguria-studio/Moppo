import AppKit
import MoppoCore
import MoppoPlans
import Testing

@Suite("Application language")
@MainActor
struct AppLanguageTests {
    @Test("System Default ignores languages inherited from another preference domain")
    func inheritedLanguages() throws {
        let domain = makeDomain()
        let inheritedDomain = makeDomain()
        let defaults = try #require(UserDefaults(suiteName: domain))
        let inherited = try #require(UserDefaults(suiteName: inheritedDomain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            inherited.removePersistentDomain(forName: inheritedDomain)
        }
        inherited.set(["es"], forKey: "AppleLanguages")
        defaults.addSuite(named: inheritedDomain)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["es"])

        let settings = SettingsStore(defaults: defaults, managesLoginItem: false, languageDomain: domain)
        #expect(settings.appLanguage == .system)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        settings.setAppLanguage(.french)
        settings.setAppLanguage(.system)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        #expect(inherited.stringArray(forKey: "AppleLanguages") == ["es"])
    }

    @Test("The first supported saved language is shown without changing the native preference",
          arguments: ["fr-CA", "fr_CA"])
    func existingOverride(identifier: String) throws {
        let domain = makeDomain()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let languages = ["ja-JP", identifier, "es"]
        defaults.set(languages, forKey: "AppleLanguages")
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false, languageDomain: domain)
        #expect(settings.appLanguage == .french)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == languages)
        defaults.set(["it-IT"], forKey: "AppleLanguages")
        settings.reloadAppLanguage()
        #expect(settings.appLanguage == .italian)
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["it-IT"])
    }

    @Test("A language choice persists and a settings reset removes only its override")
    func persistenceAndReset() throws {
        let domain = makeDomain()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let settings = SettingsStore(defaults: defaults, managesLoginItem: false, languageDomain: domain)
        settings.setAppLanguage(.spanish)
        defaults.set("keep", forKey: "unrelated")
        #expect(defaults.stringArray(forKey: "AppleLanguages") == ["es"])
        let reopened = SettingsStore(defaults: defaults, managesLoginItem: false, languageDomain: domain)
        #expect(reopened.appLanguage == .spanish)
        reopened.resetToDefaults()
        #expect(reopened.appLanguage == .system)
        #expect(defaults.persistentDomain(forName: domain)?["AppleLanguages"] == nil)
        #expect(defaults.string(forKey: "unrelated") == "keep")
    }

    @Test("A preview language can change and reset without a persistent domain")
    func previewLanguage() {
        let preview = SettingsStore.preview()
        preview.setAppLanguage(.italian)
        preview.reloadAppLanguage()
        #expect(preview.appLanguage == .italian)
        #expect(SettingsStore.preview().appLanguage == .system)
        preview.resetToDefaults()
        #expect(preview.appLanguage == .system)
    }

    @Test("Equivalent selections and a return to the running language need no restart")
    func effectiveLanguageChanges() throws {
        let domain = makeDomain()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var systemLanguage = AppLanguage.english
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false, runningAppLanguage: .english,
                                     readSystemAppLanguage: { systemLanguage })

        #expect(!settings.setAppLanguage(.english))
        #expect(!settings.hasPendingAppLanguageChange)
        #expect(settings.setAppLanguage(.french))
        #expect(settings.hasPendingAppLanguageChange)

        systemLanguage = .french
        settings.reloadAppLanguage()
        #expect(!settings.setAppLanguage(.system))
        #expect(settings.hasPendingAppLanguageChange)

        #expect(!settings.setAppLanguage(.english))
        #expect(!settings.hasPendingAppLanguageChange)
    }

    @Test("A deferred language change persists through a reload and clears after launch")
    func deferredLanguageChange() throws {
        let domain = makeDomain()
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }

        let settings = SettingsStore(defaults: defaults, managesLoginItem: false, languageDomain: domain,
                                     runningAppLanguage: .english, readSystemAppLanguage: { .english })
        #expect(settings.setAppLanguage(.spanish))
        settings.reloadAppLanguage()
        #expect(settings.hasPendingAppLanguageChange)

        let reopened = SettingsStore(defaults: defaults, managesLoginItem: false, languageDomain: domain,
                                     runningAppLanguage: .spanish, readSystemAppLanguage: { .english })
        #expect(!reopened.hasPendingAppLanguageChange)
        #expect(reopened.resetToDefaults())
        #expect(reopened.hasPendingAppLanguageChange)
    }

    @Test("Language restart leaves active work untouched",
          arguments: [OperationCoordinator.Kind.fileScan, .fileRemoval, .updateInstallation])
    func restartWhileBusy(kind: OperationCoordinator.Kind) throws {
        let operations = OperationCoordinator()
        let delegate = AppDelegate()
        delegate.operations = operations
        delegate.prepareLanguageRelaunch = {
            Issue.record("The restart prepared a new launch during active work.")
            return nil
        }
        delegate.requestTermination = { Issue.record("The restart requested termination during active work.") }
        let active = try #require(operations.begin(kind, cancel: { Issue.record("The restart cancelled active work.") }))

        #expect(delegate.languageRestartAvailability == .blocked)
        #expect(delegate.restartForLanguage() == .busy)
        #expect(operations.activeOperation == active)
        operations.finish(active)
        #expect(delegate.languageRestartAvailability == .ready)
    }

    @Test("An update that cannot acquire the cleanup lease does not block language restart")
    func restartWhenUpdateCannotBegin() async throws {
        let operations = OperationCoordinator(acquireRemovalLease: { throw PlanExecutionError.busy })
        let installation = UpdateInstallationGate(operations: operations)
        let delegate = AppDelegate()
        delegate.operations = operations
        installation.schedule { Issue.record("The update started without a cleanup lease.") }
        defer { installation.cancel() }

        try await waitUntil { operations.blockedAction?.operation.kind == .updateInstallation }
        #expect(!operations.isBusy)
        #expect(delegate.languageRestartAvailability == .ready)
    }

    @Test("One restart request stops Cleanup even when Dashboard is measuring or waiting to measure")
    func restartWhileCleanupScans() async throws {
        let scanner = HeldCleanupScanner()
        let dashboard = HeldDashboardMeasurements(holdCloud: true)
        let persistence = HeldDashboardPersistence()
        let app = AppModel(hasFullDiskAccess: { true }, dashboardService: dashboard,
                           dashboardPersistence: persistence, cleanupScanner: scanner)
        let delegate = AppDelegate()
        delegate.operations = app.operations
        delegate.dashboard = app.dashboard
        var restarts = 0
        delegate.prepareLanguageRelaunch = { { restarts += 1 } }
        delegate.requestTermination = { [weak delegate] in
            guard let delegate else { return }
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }

        app.cleanup.startScan(refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        let cloud = Task { await app.dashboard.loadICloud() }
        let rebuild = Task { await app.dashboard.rebuildSizeIndex() }
        defer {
            Task {
                await scanner.fail(0)
                await dashboard.failCloud(0)
                await dashboard.failMeasurement(0)
            }
        }
        try await waitUntil { await dashboard.cloudPlans.count == 1 }
        try await waitUntil { await persistence.cacheClears == 1 && !app.dashboard.hasActiveFileChanges }
        #expect(delegate.languageRestartAvailability == .stopCleanupScan)
        #expect(delegate.restartForLanguage() == nil)
        #expect(delegate.languageRestartAvailability == .waitingForCleanup)
        #expect(app.cleanup.isInterruptingScan)
        #expect(app.operations.begin(.updateInstallation) == nil)
        #expect(delegate.restartForLanguage() == .busy)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(restarts == 0)

        await scanner.fail(0)
        try await waitUntil { restarts == 1 }
        #expect(!app.cleanup.isScanning)
        #expect(app.dashboard.hasActiveDiskWork)
        await dashboard.failCloud(0)
        await cloud.value
        await rebuild.value
    }

    @Test("Language restart waits for Cleanup removal and its outcome")
    func restartWhileCleanupRemovesFiles() async throws {
        let folder = try TemporaryFolder()
        let entry = FileEntry(url: try folder.write("cache"), kind: .file, allocatedBytes: 64, isRegenerable: true)
        let operations = OperationCoordinator()
        let remover = HeldCleanupRemoval()
        let cleanup = CleanupModel(operations: operations, remover: remover)
        cleanup.scanResults = ScanResults(categories: [ScanCategoryResult(categoryID: .systemCaches, entries: [entry])],
                                          startedAt: .now, finishedAt: .now)
        cleanup.scannerSelection = [entry.id]
        cleanup.requestCleanUp()

        let delegate = AppDelegate()
        delegate.operations = operations
        var restarts = 0
        delegate.prepareLanguageRelaunch = { { restarts += 1 } }
        delegate.requestTermination = { [weak delegate] in
            guard let delegate else { return }
            #expect(!cleanup.isRemoving)
            #expect(cleanup.cleanupOutcome?.trashedCount == 1)
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
            delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        }

        let removal = Task { await cleanup.performCleanUp() }
        let result = CleanupOutcome(removedBytes: 64, removedCount: 1, trashedCount: 1)
        defer { Task { await remover.finish(result) } }
        try await waitUntil { await remover.isPending }
        #expect(delegate.languageRestartAvailability == .afterCleanup)
        #expect(delegate.restartForLanguage() == nil)
        #expect(cleanup.isRemoving)
        #expect(!cleanup.isInterruptingRemoval)
        #expect(restarts == 0)

        await remover.finish(result)
        await removal.value
        try await waitUntil { restarts == 1 }
        #expect(await remover.keepReceipt)
        #expect(await remover.trashFirst)
        #expect(await remover.requestCount == 1)
        #expect(!(await remover.wasCancelled))
    }

    @Test("A denied restart after Cleanup releases the reservation and the relaunch callback")
    func deferredRestartDenied() async throws {
        let operations = OperationCoordinator()
        let operation = try #require(operations.begin(.cleanupRemoval))
        let delegate = AppDelegate()
        delegate.operations = operations
        delegate.prepareLanguageRelaunch = { { Issue.record("A denied restart relaunched Moppo.") } }
        delegate.requestTermination = { }
        var failures = 0

        #expect(delegate.restartForLanguage { failures += 1 } == nil)
        operations.finish(operation)
        try await waitUntil { failures == 1 }
        #expect(!operations.isBusy)
        #expect(delegate.languageRestartAvailability == .ready)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
    }

    @Test("Restart closes a saved cleanup plan review before it quits")
    func restartClosesSavedPlanReview() async throws {
        let operations = OperationCoordinator()
        var cancellations = 0
        let review = try #require(operations.begin(.cleanupPlanReview, cancel: { cancellations += 1 }))
        let delegate = AppDelegate()
        delegate.operations = operations
        delegate.prepareLanguageRelaunch = { {} }
        var quitRequests = 0
        delegate.requestTermination = { quitRequests += 1 }

        #expect(delegate.languageRestartAvailability == .closePlanReview)
        #expect(delegate.restartForLanguage() == nil)
        #expect(cancellations == 1)
        #expect(quitRequests == 0)
        operations.finish(review)
        try await waitUntil { quitRequests == 1 }
    }

    @Test("Deferred restart checks relaunch availability at the quit boundary")
    func deferredRelaunchUnavailable() async throws {
        let operations = OperationCoordinator()
        let removal = try #require(operations.begin(.cleanupRemoval))
        let delegate = AppDelegate()
        delegate.operations = operations
        var checks = 0
        delegate.prepareLanguageRelaunch = {
            checks += 1
            return checks == 1 ? {} : nil
        }
        delegate.requestTermination = { Issue.record("The restart requested termination without a relaunch.") }
        var failures = 0

        #expect(delegate.restartForLanguage { failures += 1 } == nil)
        #expect(checks == 1)
        operations.finish(removal)
        try await waitUntil { failures == 1 }
        #expect(checks == 2)
        #expect(delegate.languageRestartAvailability == .ready)
    }

    @Test("Cleanup continues when Moppo cannot relaunch at the time of the restart request")
    func relaunchUnavailableDuringScan() throws {
        let operations = OperationCoordinator()
        let scan = try #require(operations.begin(.cleanupScan, cancel: {
            Issue.record("The restart stopped Cleanup without a relaunch.")
        }))
        let delegate = AppDelegate()
        delegate.operations = operations
        delegate.prepareLanguageRelaunch = { nil }
        delegate.requestTermination = { Issue.record("The restart requested termination without a relaunch.") }

        #expect(delegate.restartForLanguage() == .unavailable)
        #expect(!operations.isTerminating)
        #expect(operations.activeOperation == scan)
        operations.finish(scan)
    }

    @Test("Work that starts before the quit decision blocks restart and leaves no relaunch")
    func restartDeniedDuringTermination() {
        let operations = OperationCoordinator()
        let delegate = AppDelegate()
        delegate.operations = operations
        delegate.prepareLanguageRelaunch = { { Issue.record("A denied restart relaunched the app.") } }
        delegate.requestTermination = {
            _ = operations.begin(.fileScan, cancel: { Issue.record("The restart cancelled the scan.") })
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        }

        #expect(delegate.restartForLanguage() == .busy)
        #expect(operations.activeOperation?.kind == .fileScan)
        delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification))
        delegate.requestTermination = {}
    }

    @Test("A language restart relaunches only once after AppKit approves termination")
    func relaunchOnTermination() {
        let delegate = AppDelegate()
        let termination = Notification(name: NSApplication.willTerminateNotification)
        var launches = 0
        delegate.prepareLanguageRelaunch = { { launches += 1 } }
        delegate.requestTermination = {
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
            #expect(launches == 0)
            delegate.applicationWillTerminate(termination)
            delegate.applicationWillTerminate(termination)
        }

        #expect(delegate.restartForLanguage() == nil)
        #expect(launches == 1)
        delegate.requestTermination = {}
    }

    @Test("A language restart keeps the current app open if relaunch is unavailable")
    func relaunchUnavailable() {
        let delegate = AppDelegate()
        delegate.prepareLanguageRelaunch = { nil }
        delegate.requestTermination = { Issue.record("The restart requested termination without a relaunch.") }

        #expect(delegate.restartForLanguage() == .unavailable)
    }

    private func makeDomain() -> String {
        "moppo-tests.language.\(UUID().uuidString)"
    }
}
