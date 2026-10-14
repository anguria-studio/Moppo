import Foundation
import Testing
@testable import MoppoCore

@Suite("App Uninstaller feature ownership")
@MainActor
struct AppUninstallerModelTests {
    @Test("Completed details reopen without planning and expire three minutes after completion")
    func detailCacheLifetime() async throws {
        let fixture = try UninstallerFixture()
        let scanner = HeldUninstallerScanner()
        var now = ContinuousClock.now
        let operations = OperationCoordinator()
        let model = AppUninstallerModel(
            operations: operations, scanner: scanner,
            detailCache: AppUninstallDetailCache(now: { now })
        )
        let plan = uninstallPlan("Disposable", at: fixture.application)
        model.planAppUninstall(fixture.application)
        try await waitUntil { await scanner.plans.count == 1 }
        await scanner.finishPlan(0, plan)
        try await waitUntil { !model.isPlanningAppUninstall }
        model.selectedSoundLibraryIDs = ["old selection"]
        model.pendingSoundLibraryRemoval = .init(plan: plan, items: [], keepReceipt: false)
        model.resetAppUninstall()
        #expect(model.appUninstallPlan == nil)
        now += .seconds(179)
        let equivalent = fixture.application.deletingLastPathComponent()
            .appendingPathComponent("../Applications/\(fixture.application.lastPathComponent)")
        model.planAppUninstall(equivalent)
        #expect(model.appUninstallPlan == plan)
        #expect(model.appUninstallReviewURL?.path == fixture.application.path)
        #expect(model.selectedSoundLibraryIDs.isEmpty)
        #expect(model.pendingSoundLibraryRemoval == nil)
        #expect(model.appUninstallError == nil)
        #expect(model.appUninstallOutcome == nil)
        #expect(!operations.isBusy)
        #expect(await scanner.plans.count == 1)
        model.resetAppUninstall()
        now += .seconds(1)
        model.planAppUninstall(fixture.application)
        try await waitUntil { await scanner.plans.count == 2 }
        await scanner.finishPlan(1, plan)
        try await waitUntil { !model.isPlanningAppUninstall }
    }

    enum CacheSetting: CaseIterable {
        case paths, patterns, access
    }

    @Test("Changed exclusions or access require fresh details", arguments: CacheSetting.allCases)
    func detailCacheSettings(_ change: CacheSetting) async throws {
        let fixture = try UninstallerFixture()
        let scanner = HeldUninstallerScanner()
        var preferences = RemovalPreferences()
        var access = false
        let model = AppUninstallerModel(
            operations: OperationCoordinator(), scanner: scanner,
            preferences: { preferences }, hasFullDiskAccess: { access }
        )
        let plan = uninstallPlan("Disposable", at: fixture.application)
        model.planAppUninstall(fixture.application)
        try await waitUntil { await scanner.plans.count == 1 }
        await scanner.finishPlan(0, plan)
        try await waitUntil { !model.isPlanningAppUninstall }
        model.resetAppUninstall()
        switch change {
        case .paths: preferences.excludedPaths = [fixture.profile.path]
        case .patterns: preferences.excludedPatterns = ["*.keep"]
        case .access: access = true
        }
        model.planAppUninstall(fixture.application)
        try await waitUntil { await scanner.plans.count == 2 }
        await scanner.finishPlan(1, plan)
        try await waitUntil { !model.isPlanningAppUninstall }
    }

    enum UncachedReview: CaseIterable {
        case cancelled, failed, refreshed, settingsChanged, bundleChanged
    }

    @Test("Interrupted or invalidated calculations do not become reusable", arguments: UncachedReview.allCases)
    func detailCacheInvalidatedPlanning(_ change: UncachedReview) async throws {
        let fixture = try UninstallerFixture()
        let scanner = HeldUninstallerScanner()
        var preferences = RemovalPreferences()
        let model = AppUninstallerModel(
            operations: OperationCoordinator(), scanner: scanner, preferences: { preferences }
        )
        let plan = uninstallPlan("Disposable", at: fixture.application)
        model.planAppUninstall(fixture.application)
        try await waitUntil { await scanner.plans.count == 1 }
        switch change {
        case .cancelled: model.resetAppUninstall()
        case .failed: await scanner.failPlan(0)
        case .refreshed:
            model.refreshInstalledApplications()
            try await waitUntil { await scanner.listCount == 1 }
            await scanner.finishList(0, [])
        case .settingsChanged: preferences.excludedPatterns = ["*.keep"]
        case .bundleChanged:
            try Data("Updated".utf8).write(to: fixture.application.appendingPathComponent("updated.txt"))
        }
        if change != .failed { await scanner.finishPlan(0, plan) }
        try await waitUntil { !model.isPlanningAppUninstall }
        model.resetAppUninstall()
        model.planAppUninstall(fixture.application)
        try await waitUntil { await scanner.plans.count == 2 }
        await scanner.finishPlan(1, plan)
        try await waitUntil { !model.isPlanningAppUninstall }
    }

    @Test("Refresh Apps clears details for every application")
    func detailCacheRefresh() async throws {
        let fixtures = try [UninstallerFixture(), UninstallerFixture()]
        let scanner = HeldUninstallerScanner()
        let model = AppUninstallerModel(operations: OperationCoordinator(), scanner: scanner)
        for (index, fixture) in fixtures.enumerated() {
            model.planAppUninstall(fixture.application)
            try await waitUntil { await scanner.plans.count == index + 1 }
            await scanner.finishPlan(index, uninstallPlan("Disposable", at: fixture.application))
            try await waitUntil { !model.isPlanningAppUninstall }
            model.resetAppUninstall()
        }
        model.refreshInstalledApplications()
        try await waitUntil { await scanner.listCount == 1 }
        await scanner.finishList(0, [])
        for (index, fixture) in fixtures.enumerated() {
            model.planAppUninstall(fixture.application)
            try await waitUntil { await scanner.plans.count == index + 3 }
            await scanner.finishPlan(index + 2, uninstallPlan("Disposable", at: fixture.application))
            try await waitUntil { !model.isPlanningAppUninstall }
            model.resetAppUninstall()
        }
    }

    @Test("A cached review still checks the running application before removal")
    func cachedReviewRuntime() async throws {
        let fixture = try UninstallerFixture()
        let scanner = HeldUninstallerScanner()
        let remover = HeldUninstallerRemoval()
        let runtime = UninstallerRuntime()
        let model = AppUninstallerModel(
            operations: OperationCoordinator(), scanner: scanner, remover: remover,
            applications: AppUninstallApplications(
                isRunning: { _ in runtime.isRunning }, quit: { _ in runtime.quitRequests += 1; return false }
            )
        )
        let plan = uninstallPlan("Disposable", at: fixture.application)
        model.planAppUninstall(fixture.application)
        try await waitUntil { await scanner.plans.count == 1 }
        await scanner.finishPlan(0, plan)
        try await waitUntil { !model.isPlanningAppUninstall }
        model.resetAppUninstall()
        runtime.isRunning = true
        model.planAppUninstall(fixture.application)
        #expect(model.appUninstallPlan == plan)
        #expect(await scanner.plans.count == 1)
        model.requestAppUninstall()
        try await waitUntil { !model.isUninstallingApp }
        #expect(runtime.quitRequests == 1)
        #expect(await remover.requests.isEmpty)
    }

    @Test("Opening the application list keeps details prepared from another page")
    func firstListRetainsDetails() async throws {
        let fixture = try UninstallerFixture()
        let scanner = HeldUninstallerScanner()
        let model = AppUninstallerModel(operations: OperationCoordinator(), scanner: scanner)
        let plan = uninstallPlan("Disposable", at: fixture.application)
        model.planAppUninstall(fixture.application)
        try await waitUntil { await scanner.plans.count == 1 }
        model.loadInstalledApplications()
        try await waitUntil { await scanner.listCount == 1 }
        await scanner.finishList(0, [])
        await scanner.finishPlan(0, plan)
        try await waitUntil { !model.isPlanningAppUninstall }
        model.resetAppUninstall()
        model.planAppUninstall(fixture.application)
        #expect(model.appUninstallPlan == plan)
        #expect(await scanner.plans.count == 1)
    }

    enum BundleChange: CaseIterable {
        case replaced, removed, version, executable, signature, symbolicLink
    }

    @Test("Missing, replaced, or updated bundles do not reuse details", arguments: BundleChange.allCases)
    func changedCachedBundle(_ change: BundleChange) throws {
        let fixture = try UninstallerFixture()
        let application = fixture.application
        let executable = application.appendingPathComponent("Contents/MacOS/fixture")
        let signature = application.appendingPathComponent("Contents/_CodeSignature/CodeResources")
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: signature.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Executable".utf8).write(to: executable)
        try Data("Signature".utf8).write(to: signature)
        let infoURL = application.appendingPathComponent("Contents/Info.plist")
        var properties = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: infoURL), format: nil
        ) as? [String: String])
        properties["CFBundleExecutable"] = "fixture"
        properties["CFBundleVersion"] = "1"
        try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: infoURL)
        var cache = AppUninstallDetailCache()
        let settings = AppUninstallDetailCache.Settings(excludedPaths: [], excludedPatterns: [], hasFullDiskAccess: false)
        let plan = uninstallPlan("Disposable", at: application)
        cache.store(plan, stamp: try #require(.init(application)), settings: settings, generation: cache.generation)
        #expect(cache.plan(for: application, settings: settings) == plan)
        switch change {
        case .replaced, .symbolicLink:
            let old = fixture.root.appendingPathComponent("Old.app")
            try FileManager.default.moveItem(at: application, to: old)
            if change == .replaced {
                try FileManager.default.copyItem(at: old, to: application)
            } else {
                try FileManager.default.createSymbolicLink(at: application, withDestinationURL: old)
            }
        case .removed: try FileManager.default.removeItem(at: application)
        case .version:
            properties["CFBundleVersion"] = "2"
            try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0).write(to: infoURL)
        case .executable: try Data("New executable".utf8).write(to: executable)
        case .signature: try Data("New signature".utf8).write(to: signature)
        }
        #expect(cache.plan(for: application, settings: settings) == nil)
    }

    @Test("Details stay separate, retain recent entries, and do not persist")
    func detailCacheBound() throws {
        let fixtures = try (0..<33).map { _ in try UninstallerFixture() }
        var cache = AppUninstallDetailCache()
        let settings = AppUninstallDetailCache.Settings(excludedPaths: [], excludedPatterns: [], hasFullDiskAccess: false)
        for fixture in fixtures.prefix(32) {
            let plan = uninstallPlan(fixture.application.lastPathComponent, at: fixture.application)
            cache.store(plan, stamp: try #require(.init(fixture.application)), settings: settings, generation: cache.generation)
        }
        let first = fixtures[0].application
        #expect(cache.plan(for: first, settings: settings)?.applicationURL.path == first.path)
        let last = fixtures[32].application
        cache.store(
            uninstallPlan("Last", at: last), stamp: try #require(.init(last)),
            settings: settings, generation: cache.generation
        )
        #expect(cache.plan(for: fixtures[1].application, settings: settings) == nil)
        #expect(cache.plan(for: first, settings: settings)?.applicationURL.path == first.path)
        #expect(cache.plan(for: last, settings: settings)?.applicationName == "Last")
        var nextLaunch = AppUninstallDetailCache()
        #expect(nextLaunch.plan(for: last, settings: settings) == nil)
    }

    @Test("Sound removal clears details for other sound owners")
    func soundRemovalInvalidatesDetails() async throws {
        let fixtures = try [UninstallerFixture(), UninstallerFixture()]
        let scanner = HeldUninstallerScanner()
        let remover = HeldUninstallerRemoval()
        var cache = AppUninstallDetailCache()
        let settings = AppUninstallDetailCache.Settings(excludedPaths: [], excludedPatterns: [], hasFullDiskAccess: false)
        var plans = fixtures.map { uninstallPlan("Disposable", at: $0.application) }
        let sound = soundLibraryItem()
        plans[0].soundLibraryItems = [sound]
        for plan in plans {
            cache.store(plan, stamp: try #require(.init(plan.applicationURL)), settings: settings, generation: cache.generation)
        }
        let model = AppUninstallerModel(
            operations: OperationCoordinator(), scanner: scanner, remover: remover,
            hasFullDiskAccess: { false }, detailCache: cache
        )
        model.planAppUninstall(fixtures[0].application)
        #expect(model.appUninstallPlan == plans[0])
        let removal = Task { await model.requestSoundLibraryRemoval(plans[0], itemPaths: [sound.id]) }
        try await waitUntil { await remover.soundRequests.count == 1 }
        await remover.finishSounds(CleanupOutcome(removedBytes: 64, removedCount: 1, trashedCount: 1))
        await removal.value
        model.planAppUninstall(fixtures[1].application)
        try await waitUntil { await scanner.plans.count == 1 }
        await scanner.finishPlan(0, plans[1])
        try await waitUntil { !model.isPlanningAppUninstall }
    }

    @Test("Cancelled reviews retain the guard until the planner returns")
    func planningLifetime() async throws {
        let scanner = HeldUninstallerScanner()
        let app = AppModel(hasFullDiskAccess: { true }, uninstallerScanner: scanner)
        let model = app.uninstaller
        let plan = uninstallPlan("First")
        model.planAppUninstall(plan.applicationURL)
        try await waitUntil { await scanner.plans.count == 1 }
        #expect(model.isShowingAppUninstallDetail)
        #expect(model.appUninstallReviewURL == plan.applicationURL)
        #expect(app.view == .uninstaller)
        app.view = .history
        model.resetAppUninstall()
        #expect(model.isInterruptingAppUninstall)
        #expect(!model.isShowingAppUninstallDetail)
        #expect(model.appUninstallReviewURL == nil)
        #expect(app.storageExplorer.isMeasurementBlocked)
        #expect(app.isBusyWithDisk)
        model.planAppUninstall(uninstallPlan("Blocked").applicationURL)
        #expect(await scanner.plans.count == 1)
        await scanner.finishPlan(0, plan)
        try await waitUntil { !model.isPlanningAppUninstall }
        #expect(model.appUninstallPlan == nil)
        #expect(!model.isInterruptingAppUninstall)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)

        let next = uninstallPlan("Next")
        model.planAppUninstall(next.applicationURL)
        try await waitUntil { await scanner.plans.count == 2 }
        app.view = .trash
        await scanner.finishPlan(1, next)
        try await waitUntil { !model.isPlanningAppUninstall }
        #expect(model.appUninstallPlan == next)
        #expect(model.isShowingAppUninstallDetail)
        #expect(app.view == .trash)
        #expect(!app.isBusyWithDisk)
        model.resetAppUninstall()
        #expect(!model.isShowingAppUninstallDetail)
    }

    @Test("Another operation blocks review and uninstall")
    func sharedGuard() async throws {
        let operations = OperationCoordinator()
        let scanner = HeldUninstallerScanner()
        let remover = HeldUninstallerRemoval()
        let model = AppUninstallerModel(operations: operations, scanner: scanner, remover: remover)
        model.appUninstallPlan = uninstallPlan("Selected")
        let operation = try #require(operations.begin(.cleanupScan))
        model.planAppUninstall(uninstallPlan("Other").applicationURL)
        model.requestAppUninstall()
        #expect(await scanner.plans.isEmpty)
        #expect(await remover.requests.isEmpty)
        #expect(!model.isPlanningAppUninstall)
        #expect(!model.isUninstallingApp)
        operations.finish(operation)
    }

    @Test("Reviews capture exclusions and report planning failures")
    func planningPreferences() async throws {
        let scanner = HeldUninstallerScanner()
        var preferences = AppUninstallerModel.Preferences(excludedPaths: ["/excluded"], excludedPatterns: ["*.keep"])
        let operations = OperationCoordinator()
        let model = AppUninstallerModel(operations: operations, scanner: scanner, preferences: { preferences })
        model.planAppUninstall(uninstallPlan("Selected").applicationURL)
        preferences.excludedPaths = ["/later"]
        try await waitUntil { await scanner.plans.count == 1 }
        let context = try #require(await scanner.plans.first?.1)
        #expect(context.isExcluded(URL(fileURLWithPath: "/excluded/item")))
        #expect(context.isExcluded(URL(fileURLWithPath: "/folder/file.keep")))
        #expect(!context.isExcluded(URL(fileURLWithPath: "/later/item")))
        await scanner.failPlan(0)
        try await waitUntil { !model.isPlanningAppUninstall }
        #expect(model.appUninstallError != nil)
        #expect(model.appUninstallPlan == nil)
        #expect(model.isShowingAppUninstallDetail)
        #expect(!model.isShowingUninstallerLibrary)
        #expect(!operations.isBusy)
        model.resetAppUninstall()
        #expect(!model.isShowingAppUninstallDetail)
        #expect(model.appUninstallError == nil)
    }

    @Test("Replaced list loads cannot restore old applications or selection")
    func replacedLists() async throws {
        let scanner = HeldUninstallerScanner()
        let model = AppUninstallerModel(operations: OperationCoordinator(), scanner: scanner)
        let old = installedApplication("Old")
        let current = installedApplication("Current")
        model.loadInstalledApplications()
        try await waitUntil { await scanner.listCount == 1 }
        model.loadInstalledApplications()
        try await waitUntil { await scanner.listCount == 2 }
        await scanner.finishList(1, [current])
        try await waitUntil { await scanner.measurements.count == 1 }
        await scanner.finishMeasurement(0, 99)
        try await waitUntil { model.installedApplicationsMeasured }
        model.toggleApplicationSelection(current)
        await scanner.finishList(0, [old])
        await Task.yield()
        #expect(model.installedApplications == [current])
        #expect(model.selectedApplicationIDs == [current.id])
        #expect(model.selectedApplicationBytes == 99)
        #expect(await scanner.measurements.count == 1)
    }

    @Test("Application size walks wait for Cleanup and remain paused after Stop Scan", arguments: [false, true])
    func sizesWaitForCleanup(stopScan: Bool) async throws {
        let scanner = HeldUninstallerScanner()
        let cleanup = HeldCleanupScanner()
        let app = AppModel(hasFullDiskAccess: { true }, uninstallerScanner: scanner, cleanupScanner: cleanup)
        app.cleanup.startScan(refreshOverview: false)
        try await waitUntil { await cleanup.requestCount == 1 }
        app.uninstaller.loadInstalledApplications()
        try await waitUntil { await scanner.listCount == 1 }
        await scanner.finishList(0, [installedApplication("Current")])
        try await waitUntil { app.uninstaller.installedApplications?.isEmpty == false }
        #expect(await scanner.measurements.isEmpty)
        if stopScan { app.cleanup.cancelScan() }
        await cleanup.finish(0, results: ScanResults(categories: [], startedAt: .now, finishedAt: .now))
        try await waitUntil { !app.cleanup.isScanning }
        if !stopScan {
            try await waitUntil { await scanner.measurements.count == 1 }
            await scanner.finishMeasurement(0, 99)
            try await waitUntil { app.uninstaller.installedApplicationsMeasured }
        }
        #expect(await scanner.measurements.count == (stopScan ? 0 : 1))
        #expect(app.uninstaller.installedApplicationsMeasured == !stopScan)
    }

    @Test("Measurements from a replaced load cannot overwrite current sizes")
    func replacedMeasurements() async throws {
        let scanner = HeldUninstallerScanner()
        let model = AppUninstallerModel(operations: OperationCoordinator(), scanner: scanner)
        let application = installedApplication("Same")
        model.loadInstalledApplications()
        try await waitUntil { await scanner.listCount == 1 }
        await scanner.finishList(0, [application])
        try await waitUntil { await scanner.measurements.count == 1 }
        model.toggleApplicationSelection(application)
        #expect(model.selectedApplicationBytes == nil)
        model.loadInstalledApplications()
        try await waitUntil { await scanner.listCount == 2 }
        await scanner.finishList(1, [application])
        try await waitUntil { await scanner.measurements.count == 2 }
        await scanner.finishMeasurement(1, 42)
        try await waitUntil { model.installedApplicationsMeasured }
        await scanner.finishMeasurement(0, 999)
        await Task.yield()
        #expect(model.installedApplicationBytes == [application.id: 42])
        #expect(model.selectedApplicationBytes == 42)
        model.loadInstalledApplications()
        try await waitUntil { await scanner.listCount == 3 }
        await scanner.finishList(2, [])
        try await waitUntil { model.installedApplications == [] }
        #expect(model.selectedApplicationIDs.isEmpty)
        #expect(model.installedApplicationBytes.isEmpty)
    }

    @Test("Removal follows confirmation settings and retains its reviewed plan", arguments: RemovalConfirmationChoice.allCases)
    func removalLifetime(_ choice: RemovalConfirmationChoice) async throws {
        let fixture = try RemovalSettingsFixture(confirm: choice.isEnabled)
        fixture.settings.keepReceipt = false
        let remover = HeldUninstallerRemoval()
        let app = AppModel(settings: fixture.settings, uninstallerRemover: remover)
        let model = app.uninstaller
        let operations = app.operations
        let plan = uninstallPlan("Original")
        model.appUninstallPlan = plan
        var refreshes = 0
        model.refreshAfterRemoval = {
            #expect(!operations.isBusy)
            refreshes += 1
        }
        let caller = Task { model.requestAppUninstall() }
        if choice.isEnabled {
            try await waitUntil { app.pendingRemovalConfirmation != nil }
            #expect(app.pendingRemovalConfirmation == .trash(itemCount: plan.items.count, totalBytes: plan.totalBytes))
            #expect(await remover.requests.isEmpty)
            app.finishRemovalConfirmation(choice == .confirm)
            if choice == .cancel {
                try await waitUntil { !model.isUninstallingApp }
                #expect(model.appUninstallPlan == plan)
                #expect(!operations.isBusy)
                #expect(refreshes == 0)
                #expect(model.appUninstallOutcome == nil)
                return
            }
        }
        try await waitUntil { await remover.requests.count == 1 }
        #expect(app.pendingRemovalConfirmation == nil)
        caller.cancel()
        fixture.settings.keepReceipt = true
        model.appUninstallPlan = uninstallPlan("Replacement")
        model.requestAppUninstall()
        model.resetAppUninstall()
        #expect(model.isUninstallingApp)
        #expect(model.isShowingAppUninstallDetail)
        #expect(operations.isBusy)
        #expect(await remover.requests.count == 1)
        let request = try #require(await remover.requests.first)
        #expect(request.plan == plan)
        #expect(!request.keepReceipt)
        await remover.finish(0, CleanupOutcome(removedBytes: 128, removedCount: 1, trashedCount: 1))
        try await waitUntil { refreshes == 1 }
        #expect(await remover.cancelled == [false])
        #expect(model.lastUninstalledApplicationName == plan.applicationName)
        #expect(model.appUninstallOutcome?.removedBytes == 128)
        #expect(model.appUninstallPlan == nil)
        #expect(!model.isUninstallingApp)
        #expect(!model.isShowingAppUninstallDetail)
    }

    @Test("A quit refusal retains the review and prevents removal")
    func quitRefusal() async throws {
        let operations = OperationCoordinator()
        let remover = HeldUninstallerRemoval()
        var quitRequests: [URL] = []
        let applications = AppUninstallApplications(
            isRunning: { _ in true },
            quit: { quitRequests.append($0); return false }
        )
        let model = AppUninstallerModel(operations: operations, remover: remover, applications: applications)
        let plan = uninstallPlan("Running")
        model.appUninstallPlan = plan
        var waiting = false
        model.onEvent = {
            if case .uninstalling(_, _, true, _) = $0 { waiting = true }
        }
        model.requestAppUninstall()
        try await waitUntil { !model.isUninstallingApp }
        #expect(waiting)
        #expect(quitRequests == [plan.applicationURL])
        #expect(await remover.requests.isEmpty)
        #expect(model.appUninstallPlan == plan)
        #expect(model.appUninstallError?.contains("still running") == true)
        #expect(!operations.isBusy)
    }

    @Test("A batch follows confirmation settings and retains failed applications", arguments: [true, false])
    func batchRemoval(confirm: Bool) async throws {
        let operations = OperationCoordinator()
        let scanner = HeldUninstallerScanner()
        let remover = HeldUninstallerRemoval()
        var preferences = AppUninstallerModel.Preferences(confirmBeforeCleanup: confirm, keepReceipt: false)
        let model = AppUninstallerModel(
            operations: operations, scanner: scanner, remover: remover, preferences: { preferences }
        )
        let apps = [installedApplication("First"), installedApplication("Second")]
        model.loadInstalledApplications()
        try await waitUntil { await scanner.listCount == 1 }
        await scanner.finishList(0, apps)
        for i in 0..<2 {
            try await waitUntil { await scanner.measurements.count == i + 1 }
            await scanner.finishMeasurement(i, 64)
        }
        try await waitUntil { model.installedApplicationsMeasured }
        for app in apps { model.toggleApplicationSelection(app) }
        model.moveSelectedApplicationsToTrash()
        for i in 0..<2 {
            try await waitUntil { await scanner.plans.count == i + 1 }
            await scanner.finishPlan(i, uninstallPlan(apps[i].name))
        }
        try await waitUntil { !model.isPlanningAppUninstall }
        #expect(model.batchUninstallReview?.plans.count == 2)
        if confirm {
            #expect(await remover.requests.isEmpty)
            model.requestBatchUninstall()
        }
        preferences.keepReceipt = true
        try await waitUntil { await remover.requests.count == 1 }
        await remover.finish(0, CleanupOutcome(removedBytes: 64, removedCount: 1, trashedCount: 1))
        try await waitUntil { await remover.requests.count == 2 }
        #expect(await remover.requests.allSatisfy { !$0.keepReceipt })
        #expect(operations.isBusy)
        await remover.finish(1, CleanupOutcome(failed: [apps[1].id]))
        try await waitUntil { !model.isUninstallingApp }
        #expect(model.batchUninstallOutcome?.uninstalled == ["First"])
        #expect(model.batchUninstallOutcome?.setAside.first?.name == "Second")
        #expect(model.selectedApplicationIDs == [apps[1].id])
        #expect(!operations.isBusy)
    }

    @Test("Leftover refresh rejects old results and removal rechecks owners")
    func leftoversLifetime() async throws {
        let operations = OperationCoordinator()
        let scanner = HeldUninstallerScanner()
        let remover = HeldUninstallerRemoval()
        var preferences = AppUninstallerModel.Preferences(keepReceipt: false)
        var checked: Set<String> = []
        let model = AppUninstallerModel(
            operations: operations, scanner: scanner, remover: remover, preferences: { preferences },
            applications: AppUninstallApplications(registeredIdentifiers: {
                checked = $0
                return $0
            })
        )
        let old = leftoverPlan("org.moppo.old")
        let current = leftoverPlan("org.moppo.current")
        model.loadApplicationLeftovers()
        try await waitUntil { await scanner.leftoverCount == 1 }
        model.loadApplicationLeftovers()
        try await waitUntil { await scanner.leftoverCount == 2 }
        await scanner.finishLeftovers(1, current)
        try await waitUntil { !model.isLoadingApplicationLeftovers }
        model.toggleLeftoverSelection("org.moppo.current")
        await scanner.finishLeftovers(0, old)
        await Task.yield()
        #expect(model.applicationLeftovers == current)
        #expect(model.selectedLeftoverBytes == 64)
        var result: CleanupOutcome?
        model.onEvent = { if case .removed(let outcome) = $0 { result = outcome } }
        let caller = Task { await model.requestLeftoverRemoval() }
        try await waitUntil { await remover.leftoverRequests.count == 1 }
        caller.cancel()
        preferences.keepReceipt = true
        #expect(checked == ["org.moppo.current"])
        let request = try #require(await remover.leftoverRequests.first)
        #expect(request.registered == checked)
        #expect(request.paths == Set(current.groups[0].items.map(\.id)))
        #expect(!request.keepReceipt)
        let path = current.groups[0].items[0].id
        await remover.finishLeftovers(CleanupOutcome(failed: [path], permissionDenied: [path]))
        try await waitUntil { await scanner.leftoverCount == 3 }
        #expect(operations.isBusy)
        await scanner.finishLeftovers(2, current)
        await caller.value
        #expect(result?.failed == [path])
        #expect(result?.permissionDenied == [path])
        #expect(model.selectedLeftoverIdentifiers.isEmpty)
        #expect(!operations.isBusy)
    }

    @Test("Sound removal follows the setting and retains the application", arguments: [true, false])
    func soundRemoval(confirm: Bool) async throws {
        let operations = OperationCoordinator()
        let remover = HeldUninstallerRemoval()
        var preferences = AppUninstallerModel.Preferences(confirmBeforeCleanup: confirm, keepReceipt: false)
        let runtime = UninstallerRuntime()
        runtime.isRunning = true
        let model = AppUninstallerModel(
            operations: operations, remover: remover, preferences: { preferences },
            applications: AppUninstallApplications(isRunning: { _ in runtime.isRunning })
        )
        var plan = uninstallPlan("GarageBand")
        let sound = soundLibraryItem()
        plan.soundLibraryItems = [sound]
        model.appUninstallPlan = plan
        #expect(model.selectedSoundLibraryIDs.isEmpty)
        let operation = try #require(operations.begin(.cleanupScan))
        await model.requestSoundLibraryRemoval(plan, itemPaths: [sound.id])
        #expect(await remover.soundRequests.isEmpty)
        operations.finish(operation)
        await model.requestSoundLibraryRemoval(plan, itemPaths: [sound.id])
        #expect(await remover.soundRequests.isEmpty)
        #expect(!operations.isBusy)
        runtime.isRunning = false
        var result: CleanupOutcome?
        model.onEvent = { if case .removed(let outcome) = $0 { result = outcome } }
        var caller = Task { await model.requestSoundLibraryRemoval(plan, itemPaths: [sound.id, plan.applicationURL.path]) }
        if confirm {
            await caller.value
            #expect(model.pendingSoundLibraryRemoval?.items == [sound])
            #expect(await remover.soundRequests.isEmpty)
            preferences.keepReceipt = true
            caller = Task { await model.confirmSoundLibraryRemoval() }
        }
        try await waitUntil { await remover.soundRequests.count == 1 }
        caller.cancel()
        preferences.keepReceipt = true
        model.resetAppUninstall()
        #expect(model.isUninstallingApp)
        #expect(operations.isBusy)
        let request = try #require(await remover.soundRequests.first)
        #expect(request.plan == plan)
        #expect(request.paths == [sound.id])
        #expect(!request.keepReceipt)
        #expect(await remover.requests.isEmpty)
        await remover.finishSounds(CleanupOutcome(removedBytes: 64, removedCount: 1, trashedCount: 1))
        await caller.value
        #expect(result?.trashedCount == 1)
        #expect(model.lastUninstalledApplicationName == nil)
        #expect(model.appUninstallOutcome == nil)
        #expect(model.appUninstallPlan == nil)
        #expect(model.pendingSoundLibraryRemoval == nil)
        #expect(!operations.isBusy)
    }

    @Test("Leftover removal follows the setting and captures content owners", arguments: [true, false], [true, false])
    func leftoverConfirmation(confirm: Bool, sounds: Bool) async throws {
        let operations = OperationCoordinator()
        let scanner = HeldUninstallerScanner()
        let remover = HeldUninstallerRemoval()
        let suite = "LeftoverConfirmationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        settings.confirmBeforeCleanup = confirm
        settings.keepReceipt = false
        var checked: Set<String> = []
        let model = AppUninstallerModel(
            operations: operations, scanner: scanner, remover: remover,
            preferences: { RemovalPreferences(settings: settings) },
            applications: AppUninstallApplications(registeredIdentifiers: { checked = $0; return [] })
        )
        let item = sounds ? soundLibraryItem() : leftoverPlan("org.moppo.fixture").groups[0].items[0]
        let identifier = try #require(item.ownerBundleIdentifier)
        let plan = OrphanedAppLeftoverPlan(
            groups: [.init(bundleIdentifier: identifier, items: [item])],
            preservedPaths: [], unreadableCount: 0, applicationRoots: [], allowedRelatedRoots: []
        )
        model.loadApplicationLeftovers()
        try await waitUntil { await scanner.leftoverCount == 1 }
        await scanner.finishLeftovers(0, plan)
        try await waitUntil { !model.isLoadingApplicationLeftovers }
        #expect(model.selectedLeftoverIdentifiers.isEmpty)
        model.toggleLeftoverSelection(identifier)
        let operation = try #require(operations.begin(.cleanupScan))
        await model.requestLeftoverRemoval()
        #expect(model.pendingLeftoverRemoval == nil)
        operations.finish(operation)
        var caller = Task { await model.requestLeftoverRemoval() }
        if confirm {
            await caller.value
            #expect(model.pendingLeftoverRemoval?.items == [item])
            #expect(await remover.leftoverRequests.isEmpty)
            settings.keepReceipt = true
            model.selectedLeftoverIdentifiers.removeAll()
            caller = Task { await model.confirmLeftoverRemoval() }
        }
        try await waitUntil { await remover.leftoverRequests.count == 1 }
        let request = try #require(await remover.leftoverRequests.first)
        #expect(request.paths == [item.id])
        #expect(!request.keepReceipt)
        #expect(checked == (sounds ? AppleSoundLibrary.ownerIdentifiers : [identifier]))
        #expect(model.pendingLeftoverRemoval == nil)
        await remover.finishLeftovers(CleanupOutcome(removedBytes: 64, removedCount: 1, trashedCount: 1))
        try await waitUntil { await scanner.leftoverCount == 2 }
        await scanner.finishLeftovers(1, plan)
        await caller.value
        #expect(!operations.isBusy)
    }

    @Test("Partial uninstall retains receipts and Put Back clears stale results")
    func receiptRecovery() async throws {
        let fixture = try UninstallerFixture()
        let log = MoppoCore.RemovalLog(directory: fixture.root.appendingPathComponent("logs"))
        defer {
            for record in log.recentEntries() {
                if let path = record.trashedPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        let planner = AppUninstallPlanner(
            home: fixture.root, systemLibrary: fixture.root.appendingPathComponent("SystemLibrary"),
            applicationRoots: [fixture.root.appendingPathComponent("Applications")], darwinCache: nil, darwinTemp: nil
        )
        let app = AppModel(
            launchAccess: .limited, hasFullDiskAccess: { false },
            trashService: TrashService(log: log), cleanupHistoryService: CleanupHistoryService(log: log),
            appUninstallPlanner: planner, cleanupService: CleanupService(log: log)
        )
        let model = app.uninstaller
        model.planAppUninstall(fixture.application)
        try await waitUntil { !model.isPlanningAppUninstall }
        let plan = try #require(model.appUninstallPlan)
        model.resetAppUninstall()
        model.planAppUninstall(fixture.application)
        #expect(model.appUninstallPlan == plan)
        #expect(!model.isPlanningAppUninstall)
        #expect(plan.items.contains { $0.url == fixture.profile.deletingLastPathComponent() })
        let support = fixture.profile.deletingLastPathComponent()
        try FileManager.default.moveItem(at: support, to: fixture.root.appendingPathComponent("old-profile"))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("Replacement profile".utf8).write(to: fixture.profile)
        let stale = FileEntry(url: fixture.application, kind: .appBundle, allocatedBytes: 64)
        app.cleanup.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        app.cleanup.scannerSelection = [stale.id]
        model.requestAppUninstall()
        app.view = .history
        try await waitUntil { !model.isUninstallingApp }
        #expect(model.appUninstallOutcome?.removedCount == 1)
        #expect(model.appUninstallOutcome?.failed.isEmpty == false)
        #expect(!FileManager.default.fileExists(atPath: fixture.application.path))
        #expect(FileManager.default.fileExists(atPath: fixture.profile.path))
        #expect(app.cleanup.scanResults == nil)
        #expect(app.cleanup.scannerSelection.isEmpty)
        #expect(app.view == .history)
        let receipt = try #require(log.recentEntries().first { $0.disposition == .trashed })
        let trashed = URL(fileURLWithPath: try #require(receipt.trashedPath))
        #expect(receipt.originalPath == fixture.application.path)
        app.cleanup.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        app.cleanup.scannerSelection = [stale.id]
        await app.recovery.putBack(TrashItem(url: trashed, bytes: receipt.bytes, canPutBack: true))
        #expect(FileManager.default.fileExists(atPath: fixture.application.path))
        #expect(app.cleanup.scanResults == nil)
        #expect(app.cleanup.scannerSelection.isEmpty)
        #expect(app.recovery.cleanupHistory?.items.first { $0.originalURL.path == receipt.originalPath }?.state == .restored)
        model.planAppUninstall(fixture.application)
        #expect(model.isPlanningAppUninstall)
        try await waitUntil { !model.isPlanningAppUninstall }
        model.resetAppUninstall()
    }
}

@MainActor
private final class UninstallerRuntime {
    var isRunning = false
    var quitRequests = 0
}

private func installedApplication(_ name: String) -> InstalledApplication {
    InstalledApplication(url: URL(fileURLWithPath: "/moppo-fixture/\(name).app"), name: name, bundleIdentifier: "org.moppo.\(name)")
}

private func uninstallPlan(_ name: String, at applicationURL: URL? = nil) -> AppUninstallPlan {
    let application = installedApplication(name)
    let url = applicationURL ?? application.url
    return AppUninstallPlan(
        applicationURL: url, applicationName: name, bundleIdentifier: application.bundleIdentifier,
        items: [.init(url: url, category: .application, content: .application,
                      allocatedBytes: 64, ownerBundleIdentifier: application.bundleIdentifier)],
        managedPackage: nil, preservedPaths: [], candidateBundleIdentifiers: [application.bundleIdentifier!],
        applicationRoots: [url.deletingLastPathComponent()], allowedRelatedRoots: []
    )
}

private func leftoverPlan(_ identifier: String) -> OrphanedAppLeftoverPlan {
    let url = URL(fileURLWithPath: "/moppo-fixture/Library/Containers/\(identifier)")
    return OrphanedAppLeftoverPlan(
        groups: [.init(bundleIdentifier: identifier, items: [
            .init(url: url, category: .containers, content: .userData, allocatedBytes: 64, ownerBundleIdentifier: identifier)
        ])], preservedPaths: [], unreadableCount: 0, applicationRoots: [], allowedRelatedRoots: [url.deletingLastPathComponent()]
    )
}

private actor HeldUninstallerScanner: AppUninstallerScanning {
    private(set) var plans: [(URL, ScanContext)] = []
    private(set) var listCount = 0
    private(set) var measurements: [URL] = []
    private(set) var leftoverCount = 0
    private var planReplies: [Int: CheckedContinuation<AppUninstallPlan, Error>] = [:]
    private var listReplies: [Int: CheckedContinuation<[InstalledApplication], Never>] = [:]
    private var measurementReplies: [Int: CheckedContinuation<Int64, Never>] = [:]
    private var leftoverReplies: [Int: CheckedContinuation<OrphanedAppLeftoverPlan, Never>] = [:]

    func plan(applicationURL: URL, context: ScanContext) async throws -> AppUninstallPlan {
        let index = plans.count
        plans.append((applicationURL, context))
        return try await withCheckedThrowingContinuation { planReplies[index] = $0 }
    }
    func installedApplications(context: ScanContext) async -> [InstalledApplication] {
        let index = listCount
        listCount += 1
        return await withCheckedContinuation { listReplies[index] = $0 }
    }
    func allocatedBytes(at url: URL, context: ScanContext) async throws -> Int64 {
        let index = measurements.count
        measurements.append(url)
        return await withCheckedContinuation { measurementReplies[index] = $0 }
    }
    func leftovers(context: ScanContext) async throws -> OrphanedAppLeftoverPlan {
        let index = leftoverCount
        leftoverCount += 1
        return await withCheckedContinuation { leftoverReplies[index] = $0 }
    }
    func finishPlan(_ index: Int, _ plan: AppUninstallPlan) { planReplies.removeValue(forKey: index)?.resume(returning: plan) }
    func failPlan(_ index: Int) { planReplies.removeValue(forKey: index)?.resume(throwing: AppUninstallPlanningError.applicationExcluded) }
    func finishList(_ index: Int, _ apps: [InstalledApplication]) { listReplies.removeValue(forKey: index)?.resume(returning: apps) }
    func finishMeasurement(_ index: Int, _ bytes: Int64) { measurementReplies.removeValue(forKey: index)?.resume(returning: bytes) }
    func finishLeftovers(_ index: Int, _ plan: OrphanedAppLeftoverPlan) { leftoverReplies.removeValue(forKey: index)?.resume(returning: plan) }
}

private actor HeldUninstallerRemoval: AppUninstallRemoving {
    func removeSoundLibraries(
        _ plan: AppUninstallPlan, itemPaths: Set<String>,
        keepReceipt: Bool
    ) async throws -> CleanupOutcome {
        soundRequests.append(SoundRequest(plan: plan, paths: itemPaths, keepReceipt: keepReceipt))
        return await withCheckedContinuation { soundReply = $0 }
    }
    struct Request: Sendable {
        let plan: AppUninstallPlan
        let keepReceipt: Bool
    }
    struct LeftoverRequest: Sendable {
        let registered: Set<String>
        let paths: Set<String>?
        let keepReceipt: Bool
    }
    struct SoundRequest: Sendable {
        let plan: AppUninstallPlan
        let paths: Set<String>
        let keepReceipt: Bool
    }
    private(set) var requests: [Request] = []
    private(set) var leftoverRequests: [LeftoverRequest] = []
    private(set) var soundRequests: [SoundRequest] = []
    private(set) var cancelled: [Bool] = []
    private var replies: [Int: CheckedContinuation<CleanupOutcome, Never>] = [:]
    private var leftoverReply: CheckedContinuation<CleanupOutcome, Never>?
    private var soundReply: CheckedContinuation<CleanupOutcome, Never>?
    func uninstall(_ plan: AppUninstallPlan, keepReceipt: Bool) async throws -> CleanupOutcome {
        let index = requests.count
        requests.append(Request(plan: plan, keepReceipt: keepReceipt))
        let result = await withCheckedContinuation { replies[index] = $0 }
        cancelled.append(Task.isCancelled)
        return result
    }
    func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan, bundleIdentifiers: Set<String>, itemPaths: Set<String>?,
        registeredApplicationBundleIdentifiers: Set<String>, keepReceipt: Bool
    ) async throws -> CleanupOutcome {
        leftoverRequests.append(LeftoverRequest(registered: registeredApplicationBundleIdentifiers, paths: itemPaths, keepReceipt: keepReceipt))
        return await withCheckedContinuation { leftoverReply = $0 }
    }
    func finish(_ index: Int, _ outcome: CleanupOutcome) { replies.removeValue(forKey: index)?.resume(returning: outcome) }
    func finishLeftovers(_ outcome: CleanupOutcome) { leftoverReply?.resume(returning: outcome); leftoverReply = nil }
    func finishSounds(_ outcome: CleanupOutcome) { soundReply?.resume(returning: outcome); soundReply = nil }
}

private final class UninstallerFixture {
    private let folder: TemporaryFolder
    var root: URL { folder.url }
    let application: URL
    let profile: URL
    init() throws {
        folder = try TemporaryFolder(prefix: "moppo-uninstaller")
        let root = folder.url
        application = root.appendingPathComponent("Applications/Disposable-\(root.lastPathComponent).app")
        profile = root.appendingPathComponent("Library/Application Support/org.moppo.uninstallerfixture/profile.txt")
        try FileManager.default.createDirectory(at: application.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "org.moppo.uninstallerfixture", "CFBundleName": "Disposable", "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try plist.write(to: application.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Disposable profile".utf8).write(to: profile)
    }
}
