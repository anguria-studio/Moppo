import Foundation
import Testing
import MoppoCore
import MoppoPlans

@MainActor
struct SavedPlanTests {
    private struct Fixture {
        let folder: TemporaryFolder
        let entry: FileEntry
        let validation: CleanupPlanService
        let outcomes: PlanOutcomeStore
        let history: MoppoCore.RemovalLog
        let review: PlanReview
        let handoff: PlanHandoff

        init(permanent: Bool = false) async throws {
            folder = try TemporaryFolder(prefix: "saved-plan")
            let url = try folder.write("target")
            var entry = FileEntry(url: url, kind: .file, allocatedBytes: 4096)
            if permanent {
                let cache = folder.url.appendingPathComponent("cache")
                try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                entry = FileEntry(url: cache, kind: .cache, allocatedBytes: 0,
                    removalMethod: .toolCommand(.goModuleCache(at: cache, executable: "/usr/bin/true")))
            }
            self.entry = entry
            let settings = ScanConfiguration(enabledCategories: [.aiTools])
            let results = ScanResults(categories: [.init(categoryID: .aiTools, totalBytes: 4096, entries: [entry])],
                                      startedAt: Date(), finishedAt: Date())
            let scans = ScanStore(directory: folder.url.appendingPathComponent("scans"))
            let plans = PlanStore(directory: folder.url.appendingPathComponent("plans"))
            let report = ScanReport(results: results, configuration: settings)
            try scans.save(report)
            validation = CleanupPlanService(scans: scans, plans: plans, configuration: { settings }, scanner: { _ in results })
            outcomes = PlanOutcomeStore(directory: folder.url.appendingPathComponent("outcomes"))
            history = MoppoCore.RemovalLog(directory: folder.url.appendingPathComponent("history"))
            review = try await validation.create(scanId: report.scanId, scanRevision: RecordDigest.of(report), itemIds: [report.items[0].id])
            handoff = try PlanHandoff(planId: review.plan.planId, revision: review.revision)
        }

        func services(remove: @escaping PlanExecutionService.Remover = { _, _, _ in
            Issue.record("An unconfirmed plan reached removal."); return CleanupOutcome()
        }) -> SavedPlanServices {
            SavedPlanServices(validation: validation, outcomes: outcomes,
                executor: PlanExecutionService(validation: validation, outcomes: outcomes,
                    lockDirectory: folder.url.appendingPathComponent("execution"), history: history, remove: remove))
        }
    }

    @Test func cancellationPreservesSelectionAndRejectsReplacement() async throws {
        let f = try await Fixture()
        let preferences = try RemovalSettingsFixture(confirm: false)
        let app = AppModel(settings: preferences.settings, hasFullDiskAccess: { false }, savedPlanServices: f.services())
        app.cleanup.scannerSelection = ["existing-selection"]
        app.openSavedPlan(f.handoff.url)
        try await waitUntil { app.savedPlans.phase == .reviewing }
        #expect(app.cleanup.scannerSelection == ["existing-selection"])
        app.startInitialCleanupScan()
        #expect(!app.cleanup.hasStartedInitialScan)
        let other = try PlanHandoff(planId: "plan_" + UUID().uuidString.lowercased(), revision: f.handoff.revision)
        app.openSavedPlan(other.url)
        #expect(app.savedPlans.handoff == f.handoff)
        #expect(app.savedPlans.otherRequestMessage != nil)
        #expect(try f.outcomes.outcomes(planId: other.planId).first?.status == .blocked)
        app.savedPlans.confirmRemoval()
        #expect(app.savedPlans.phase == .reviewing)
        app.savedPlans.acceptProposal()
        #expect(app.savedPlans.phase == .confirming)
        app.savedPlans.cancel()
        #expect(!app.savedPlans.isPresented)
        #expect(!app.operations.isBusy)
        #expect(app.cleanup.scannerSelection == ["existing-selection"])
        #expect(try f.outcomes.outcomes(planId: f.handoff.planId).first?.status == .cancelled)
        #expect(FileManager.default.fileExists(atPath: f.entry.url.path))
    }

    @Test(arguments: [false, true])
    func mandatoryConfirmation(permanent: Bool) async throws {
        let f = try await Fixture(permanent: permanent)
        let gate = TestGate()
        let preferences = try RemovalSettingsFixture(confirm: false)
        let app = AppModel(settings: preferences.settings, hasFullDiskAccess: { false }, savedPlanServices: f.services { entry, identities, commands in
            #expect(identities[entry.id] != nil)
            #expect((commands[entry.id] != nil) == permanent)
            await gate.wait()
            return CleanupOutcome()
        })
        app.openSavedPlan(f.handoff.url)
        try await waitUntil { app.savedPlans.phase == .reviewing }
        #expect(await gate.count == 0)
        app.savedPlans.acceptProposal()
        #expect(app.savedPlans.phase == .confirming)
        #expect(await gate.count == 0)
        app.savedPlans.confirmRemoval()
        if permanent {
            #expect(app.savedPlans.phase == .permanentConfirmation)
            #expect(app.savedPlans.permanentEntries.first?.toolCommand?.arguments == ["clean", "-modcache"])
            #expect(await gate.count == 0)
            app.savedPlans.confirmPermanentRemoval()
        }
        try await waitUntil { await gate.isPending }
        app.savedPlans.cancel()
        #expect(app.savedPlans.phase == .removing)
        app.savedPlans.stopRemoval()
        #expect(app.operations.isBusy)
        await gate.finish()
        try await waitUntil { app.savedPlans.phase == .finished }
        #expect(!app.operations.isBusy)
        #expect(try f.outcomes.outcomes(planId: f.handoff.planId).first?.items.count == 1)
    }

    @Test func staleAndBusyRequestsCannotReachReview() async throws {
        let f = try await Fixture()
        let operations = OperationCoordinator()
        let model = SavedPlanModel(operations: operations, services: f.services())
        let operation = try #require(operations.begin(.cleanupScan))
        model.open(f.handoff)
        #expect(model.phase == .failed)
        #expect(model.review == nil)
        #expect(operations.activeOperation == operation)
        model.cancel()
        operations.finish(operation)
        let stale = try PlanHandoff(planId: f.handoff.planId, revision: String(repeating: "0", count: 64))
        model.open(stale)
        try await waitUntil { model.phase == .failed }
        #expect(model.review == nil)
        #expect(!operations.isBusy)
        model.cancel()
        model.open(f.handoff)
        try await waitUntil { model.phase == .reviewing }
        try Data("changed after review".utf8).write(to: f.entry.url)
        model.acceptProposal()
        model.confirmRemoval()
        try await waitUntil { model.phase == .failed }
        #expect(try String(contentsOf: f.entry.url, encoding: .utf8) == "changed after review")
        model.cancel()
    }

    @Test func loadingCancellationRetainsOperationUntilWorkerStops() async throws {
        let f = try await Fixture()
        let gate = TestGate()
        let entry = f.entry
        let validation = CleanupPlanService(scans: f.validation.scans, plans: f.validation.plans,
            configuration: { ScanConfiguration(enabledCategories: [.aiTools]) }, scanner: { _ in
                await gate.wait()
                return ScanResults(categories: [.init(categoryID: .aiTools, totalBytes: 4096, entries: [entry])],
                                   startedAt: Date(), finishedAt: Date())
            })
        let operations = OperationCoordinator()
        let model = SavedPlanModel(operations: operations, services: SavedPlanServices(validation: validation, outcomes: f.outcomes))
        model.open(f.handoff)
        try await waitUntil { await gate.isPending }
        model.cancel()
        #expect(model.phase == .stopping)
        #expect(operations.isBusy)
        #expect(operations.begin(.cleanupScan) == nil)
        await gate.finish()
        try await waitUntil { !model.isPresented }
        #expect(!operations.isBusy)
        #expect(try f.outcomes.outcomes(planId: f.handoff.planId).first?.status == .cancelled)
    }

    @Test func coldRequestWaitsForHandlerAndWelcomeGuide() async throws {
        let f = try await Fixture()
        let app = AppModel(launchAccess: .welcome, hasFullDiskAccess: { false }, savedPlanServices: f.services())
        let center = MainWindowRequestCenter()
        center.submit(f.handoff.url)
        center.install(app.openSavedPlan)
        #expect(!app.savedPlans.isPresented)
        app.finishWelcomeGuide()
        app.startInitialCleanupScan()
        #expect(!app.cleanup.hasStartedInitialScan)
        try await waitUntil { app.savedPlans.phase == .reviewing }
        app.savedPlans.cancel()
        app.openSavedPlan(URL(string: "moppo://plan-review?command=rm")!)
        #expect(!app.savedPlans.isPresented)
    }
}
