import Foundation
import Testing
@testable import MoppoCore

@Suite("App Uninstaller feature ownership")
@MainActor
struct AppUninstallerModelTests {
    @Test("Cancelled reviews retain the guard until the planner returns")
    func planningLifetime() async throws {
        let scanner = HeldUninstallerScanner()
        let app = AppModel(hasFullDiskAccess: { true }, uninstallerScanner: scanner)
        let model = app.uninstaller
        let plan = uninstallPlan("First")
        model.planAppUninstall(plan.applicationURL)
        try await waitUntil { await scanner.plans.count == 1 }
        #expect(app.view == .uninstaller)
        app.view = .history
        model.resetAppUninstall()
        #expect(model.isInterruptingAppUninstall)
        #expect(app.storageExplorer.isMeasurementBlocked)
        #expect(app.operations.begin(.photoScan) == nil)
        #expect(app.operations.begin(.cleanupRemoval) == nil)
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
        #expect(app.view == .trash)
        #expect(!app.isBusyWithDisk)
    }

    @Test("Other operations block review and uninstall", arguments: [
        OperationCoordinator.Kind.photoDeletion, .fileScan, .cleanupScan, .cleanupRemoval, .appLeftoverRemoval
    ])
    func sharedGuard(_ kind: OperationCoordinator.Kind) async throws {
        let operations = OperationCoordinator()
        let scanner = HeldUninstallerScanner()
        let remover = HeldUninstallerRemoval()
        let model = AppUninstallerModel(operations: operations, scanner: scanner, remover: remover)
        model.appUninstallPlan = uninstallPlan("Selected")
        let operation = try #require(operations.begin(kind))
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
        #expect(!operations.isBusy)
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

    @Test("Removal owns its task and captures the plan and receipt setting")
    func removalLifetime() async throws {
        let operations = OperationCoordinator()
        let remover = HeldUninstallerRemoval()
        var preferences = AppUninstallerModel.Preferences(keepReceipt: false)
        let model = AppUninstallerModel(operations: operations, remover: remover, preferences: { preferences })
        let plan = uninstallPlan("Original")
        model.appUninstallPlan = plan
        var refreshes = 0
        model.refreshAfterRemoval = {
            #expect(!operations.isBusy)
            refreshes += 1
        }
        let caller = Task { model.requestAppUninstall() }
        try await waitUntil { await remover.requests.count == 1 }
        caller.cancel()
        preferences.keepReceipt = true
        model.appUninstallPlan = uninstallPlan("Replacement")
        model.requestAppUninstall()
        model.resetAppUninstall()
        #expect(model.isUninstallingApp)
        #expect(operations.begin(.fileScan) == nil)
        #expect(await remover.requests.count == 1)
        let request = try #require(await remover.requests.first)
        #expect(request.plan == plan)
        #expect(!request.keepReceipt)
        #expect(request.privilegedFallback)
        await remover.finish(0, CleanupOutcome(removedBytes: 128, removedCount: 1, trashedCount: 1))
        try await waitUntil { refreshes == 1 }
        #expect(await remover.cancelled == [false])
        #expect(model.lastUninstalledApplicationName == plan.applicationName)
        #expect(model.appUninstallOutcome?.removedBytes == 128)
        #expect(model.appUninstallPlan == nil)
        #expect(!model.isUninstallingApp)
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

    @Test("A batch captures one receipt setting and retains failed applications")
    func batchRemoval() async throws {
        let operations = OperationCoordinator()
        let scanner = HeldUninstallerScanner()
        let remover = HeldUninstallerRemoval()
        var preferences = AppUninstallerModel.Preferences(keepReceipt: false)
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
        model.requestBatchUninstall()
        preferences.keepReceipt = true
        try await waitUntil { await remover.requests.count == 1 }
        await remover.finish(0, CleanupOutcome(removedBytes: 64, removedCount: 1, trashedCount: 1))
        try await waitUntil { await remover.requests.count == 2 }
        #expect(await remover.requests.allSatisfy { !$0.keepReceipt })
        #expect(operations.begin(.photoScan) == nil)
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
        model.onEvent = { if case .leftoversRemoved(let outcome) = $0 { result = outcome } }
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
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "The operation did not finish before the deadline.")
    }
}

private func installedApplication(_ name: String) -> InstalledApplication {
    InstalledApplication(url: URL(fileURLWithPath: "/moppo-fixture/\(name).app"), name: name, bundleIdentifier: "org.moppo.\(name)")
}

private func uninstallPlan(_ name: String) -> AppUninstallPlan {
    let application = installedApplication(name)
    return AppUninstallPlan(
        applicationURL: application.url, applicationName: name, bundleIdentifier: application.bundleIdentifier,
        items: [.init(url: application.url, category: .application, content: .application,
                      allocatedBytes: 64, ownerBundleIdentifier: application.bundleIdentifier)],
        managedPackage: nil, preservedPaths: [], candidateBundleIdentifiers: [application.bundleIdentifier!],
        applicationRoots: [application.url.deletingLastPathComponent()], allowedRelatedRoots: []
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
    struct Request: Sendable {
        let plan: AppUninstallPlan
        let privilegedFallback: Bool
        let keepReceipt: Bool
    }
    struct LeftoverRequest: Sendable {
        let registered: Set<String>
        let paths: Set<String>?
        let keepReceipt: Bool
    }
    private(set) var requests: [Request] = []
    private(set) var leftoverRequests: [LeftoverRequest] = []
    private(set) var cancelled: [Bool] = []
    private var replies: [Int: CheckedContinuation<CleanupOutcome, Never>] = [:]
    private var leftoverReply: CheckedContinuation<CleanupOutcome, Never>?
    func uninstall(_ plan: AppUninstallPlan, privilegedFallback: Bool, keepReceipt: Bool) async throws -> CleanupOutcome {
        let index = requests.count
        requests.append(Request(plan: plan, privilegedFallback: privilegedFallback, keepReceipt: keepReceipt))
        let result = await withCheckedContinuation { replies[index] = $0 }
        cancelled.append(Task.isCancelled)
        return result
    }
    func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan, bundleIdentifiers: Set<String>, itemPaths: Set<String>?,
        registeredApplicationBundleIdentifiers: Set<String>, privilegedFallback: Bool, keepReceipt: Bool
    ) async throws -> CleanupOutcome {
        leftoverRequests.append(LeftoverRequest(registered: registeredApplicationBundleIdentifiers, paths: itemPaths, keepReceipt: keepReceipt))
        return await withCheckedContinuation { leftoverReply = $0 }
    }
    func finish(_ index: Int, _ outcome: CleanupOutcome) { replies.removeValue(forKey: index)?.resume(returning: outcome) }
    func finishLeftovers(_ outcome: CleanupOutcome) { leftoverReply?.resume(returning: outcome); leftoverReply = nil }
}

private final class UninstallerFixture {
    let root: URL
    let application: URL
    let profile: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-uninstaller-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
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
    deinit { try? FileManager.default.removeItem(at: root) }
}
