import AppIntents
import Foundation
import MoppoCore
import Testing

@Suite("Shortcuts actions")
@MainActor
struct MoppoIntentTests {
    @Test("Cleanup actions reject an incomplete welcome guide", arguments: CleanupShortcutAction.allCases)
    func welcomeGuide(action: CleanupShortcutAction) async throws {
        let model = AppModel(launchAccess: .welcome, hasFullDiskAccess: { false })

        await #expect(throws: MoppoIntentError.welcomeGuideIncomplete) { try await action.perform(model: model) }

        #expect(!model.cleanup.hasStartedInitialScan)
        #expect(!model.isBusyWithDisk)
    }

    @Test("Cleanup actions keep the active disk operation", arguments: CleanupShortcutAction.allCases)
    func busy(action: CleanupShortcutAction) async throws {
        let model = AppModel(launchAccess: .limited, hasFullDiskAccess: { false })
        let operation = try #require(model.operations.begin(.emptyTrash))
        defer { model.operations.finish(operation) }

        await #expect(throws: MoppoIntentError.operationInProgress) { try await action.perform(model: model) }

        #expect(model.operations.activeOperation == operation)
        #expect(!model.cleanup.hasStartedInitialScan)
    }

    @Test("Cleanup actions keep an existing removal review", arguments: CleanupShortcutAction.allCases)
    func pendingReview(action: CleanupShortcutAction) async throws {
        let settings = try RemovalSettingsFixture(confirm: true)
        let model = AppModel(settings: settings.settings, launchAccess: .limited, hasFullDiskAccess: { false })
        let entry = FileEntry(url: URL(fileURLWithPath: "/fixture/cache"), kind: .cache,
                              allocatedBytes: 128, isRegenerable: true)
        model.cleanup.scanResults = ScanResults(categories: [
            ScanCategoryResult(categoryID: .systemCaches, totalBytes: 128, entries: [entry])
        ], startedAt: .now, finishedAt: .now)
        model.cleanup.scannerSelection = [entry.id]
        model.cleanup.requestCleanUp(in: .safeToRemove)
        defer { model.cleanup.cancelCleanUp() }
        let plan = try #require(model.cleanup.pendingCleanUp)

        await #expect(throws: MoppoIntentError.operationInProgress) { try await action.perform(model: model) }

        #expect(model.cleanup.pendingCleanUp?.id == plan.id)
        #expect(!model.cleanup.hasStartedInitialScan)
    }

    @Test("The scan action presents the main window and starts Cleanup")
    func scan() async throws {
        let scanner = HeldCleanupScanner()
        let model = AppModel(launchAccess: .limited, hasFullDiskAccess: { false }, cleanupScanner: scanner)
        model.view = .dashboard
        var presented = false
        var intent = ScanForCleanupItemsIntent()
        intent.$model.wrappedValue = model
        intent.presentMainWindow = { presented = true }

        _ = try await intent.perform()

        #expect(presented)
        #expect(model.view == .scanner)
        #expect(model.cleanup.isScanning)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.finish(0, results: ScanResults(categories: [], startedAt: .now, finishedAt: .now))
        _ = await model.cleanup.waitForScan()
        #expect(!model.isBusyWithDisk)
    }

    @Test("Background deletion keeps navigation and removes only fresh Safe to Remove items without confirmation")
    func deleteSafeToRemove() async throws {
        let settings = try RemovalSettingsFixture(confirm: true)
        let folder = try TemporaryFolder()
        let safe = FileEntry(url: try folder.write("cache"), kind: .cache, allocatedBytes: 128, isRegenerable: true)
        let unsafe = FileEntry(url: try folder.write("notes"), kind: .file, allocatedBytes: 256)
        let protected = FileEntry(url: try folder.write("protected"), kind: .cache,
                                  allocatedBytes: 512, isRegenerable: true, protectionReason: .userData)
        let cache = folder.url.appendingPathComponent("go-cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let command = ToolCommandRemoval.goModuleCache(at: cache, executable: "/usr/bin/true")
        let tool = FileEntry(url: cache, kind: .cache, allocatedBytes: 1024, isRegenerable: true,
                             removalMethod: .toolCommand(command))
        let scanner = HeldCleanupScanner()
        let remover = HeldCleanupRemoval()
        let model = AppModel(settings: settings.settings, launchAccess: .ready, hasFullDiskAccess: { true },
                             cleanupScanner: scanner, cleanupRemover: remover)
        model.cleanup.scanResults = ScanResults(categories: [
            ScanCategoryResult(categoryID: .systemCaches, totalBytes: 768, entries: [unsafe, protected])
        ], startedAt: .distantPast, finishedAt: .distantPast)
        model.cleanup.scannerSelection = [unsafe.id, protected.id]
        model.cleanup.userDataRemovalOverrides = [protected.id]
        model.cleanup.scanFilter = .all
        model.cleanup.dataTypeFilter = .nodeModules
        var requestedConfirmation = false
        let handleEvent = model.cleanup.onEvent
        model.cleanup.onEvent = { event in
            if case .confirmationRequested = event { requestedConfirmation = true }
            handleEvent(event)
        }
        model.view = .dashboard
        let intent = DeleteSafeToRemoveIntent()
        intent.$model.wrappedValue = model

        _ = try await intent.perform()

        #expect(model.view == .dashboard)
        try await waitUntil { await scanner.requestCount == 1 }
        #expect(await remover.requestCount == 0)
        await scanner.finish(0, results: ScanResults(categories: [
            ScanCategoryResult(categoryID: .systemCaches, totalBytes: 1920, entries: [safe, unsafe, protected, tool])
        ], startedAt: .now, finishedAt: .now))
        try await waitUntil { await remover.isPending }
        #expect(Set(await remover.entries.map(\.id)) == [safe.id, tool.id])
        #expect(await remover.overrides.isEmpty)
        #expect(await remover.confirmedToolCommands == [tool.id: command])
        #expect(await remover.trashFirst)
        #expect(await remover.keepReceipt)
        #expect(model.cleanup.scanFilter == .safeToRemove)
        #expect(model.cleanup.dataTypeFilter == .all)
        #expect(model.activeSheet == nil)
        #expect(model.cleanup.pendingCleanUp == nil)
        #expect(!requestedConfirmation)
        #expect(settings.settings.confirmBeforeCleanup)
        #expect(model.isBusyWithDisk)
        await remover.finish(CleanupOutcome(removedBytes: 1152, removedCount: 2, trashedCount: 1, deletedCount: 1))
        try await waitUntil { !model.isBusyWithDisk }
        #expect(model.cleanup.cleanupOutcome?.removedCount == 2)
        #expect(model.view == .dashboard)
        #expect(FileManager.default.fileExists(atPath: unsafe.id))
        #expect(FileManager.default.fileExists(atPath: protected.id))
    }

    @Test("Delete removes nothing after a stopped or failed scan", arguments: [false, true])
    func interruptedDelete(cancelled: Bool) async throws {
        let scanner = HeldCleanupScanner()
        let remover = HeldCleanupRemoval()
        let model = AppModel(launchAccess: .ready, hasFullDiskAccess: { true },
                             cleanupScanner: scanner, cleanupRemover: remover)
        let old = FileEntry(url: URL(fileURLWithPath: "/fixture/old-cache"), kind: .cache,
                            allocatedBytes: 128, isRegenerable: true)
        let results = ScanResults(categories: [
            ScanCategoryResult(categoryID: .systemCaches, totalBytes: 128, entries: [old])
        ], startedAt: .distantPast, finishedAt: .distantPast)
        model.cleanup.scanResults = results
        model.cleanup.scannerSelection = [old.id]
        try await CleanupShortcutAction.delete.perform(model: model)
        try await waitUntil { await scanner.requestCount == 1 }
        if cancelled {
            model.cleanup.cancelScan()
            await scanner.finish(0, results: results)
        } else {
            await scanner.fail(0)
        }

        #expect(await model.cleanup.waitForScan() == false)
        #expect(await remover.requestCount == 0)
        #expect(model.cleanup.scanResults?.finishedAt == .distantPast)
        #expect(!model.isBusyWithDisk)
        #expect(model.cleanup.pendingCleanUp == nil)
    }

    @Test("Delete completes without removal when the new scan has no safe items")
    func nothingToDelete() async throws {
        let scanner = HeldCleanupScanner()
        let remover = HeldCleanupRemoval()
        let model = AppModel(launchAccess: .ready, hasFullDiskAccess: { true },
                             cleanupScanner: scanner, cleanupRemover: remover)
        try await CleanupShortcutAction.delete.perform(model: model)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.finish(0, results: ScanResults(categories: [], startedAt: .now, finishedAt: .now))

        #expect(await model.cleanup.waitForScan())
        #expect(await remover.requestCount == 0)
        #expect(!model.isBusyWithDisk)
        #expect(model.activeSheet == nil)
    }

    @Test("Background deletion stops when scan settings change during its scan")
    func changedBackgroundScanSettings() async throws {
        let settings = try RemovalSettingsFixture(confirm: true)
        let scanner = HeldCleanupScanner()
        let remover = HeldCleanupRemoval()
        let model = AppModel(settings: settings.settings, launchAccess: .ready, hasFullDiskAccess: { true },
                             cleanupScanner: scanner, cleanupRemover: remover)
        try await CleanupShortcutAction.delete.perform(model: model)
        try await waitUntil { await scanner.requestCount == 1 }
        settings.settings.showsSmallItems.toggle()
        let entry = FileEntry(url: URL(fileURLWithPath: "/fixture/cache"), kind: .cache,
                              allocatedBytes: 128, isRegenerable: true)
        await scanner.finish(0, results: ScanResults(categories: [
            ScanCategoryResult(categoryID: .systemCaches, totalBytes: 128, entries: [entry])
        ], startedAt: .now, finishedAt: .now))

        #expect(await model.cleanup.waitForScan())
        #expect(model.cleanup.showsOutdatedResultsNotice)
        #expect(model.cleanup.scannerSelection.isEmpty)
        #expect(await remover.requestCount == 0)
        #expect(!model.isBusyWithDisk)
    }

    @Test("Background deletion requires Full Disk Access", arguments: [LaunchAccess.limited, .ready])
    func backgroundAccess(access: LaunchAccess) async throws {
        let scanner = HeldCleanupScanner()
        let model = AppModel(launchAccess: access, hasFullDiskAccess: { false }, cleanupScanner: scanner)
        model.view = .dashboard

        await #expect(throws: MoppoIntentError.backgroundAccessRequired) {
            try await CleanupShortcutAction.delete.perform(model: model)
        }

        #expect(await scanner.requestCount == 0)
        #expect(!model.cleanup.hasStartedInitialScan)
        #expect(!model.isBusyWithDisk)
        #expect(model.view == .dashboard)
        #expect(model.launchAccess == (access == .limited ? .limited : .diskAccess))
    }

    @Test("The size action reads the current safe total without starting a scan")
    func safeToRemove() async throws {
        let model = AppModel(launchAccess: .welcome, hasFullDiskAccess: { false })
        let safe = FileEntry(url: URL(fileURLWithPath: "/fixture/cache"), kind: .folder,
                             allocatedBytes: 128, isRegenerable: true)
        let protected = FileEntry(url: URL(fileURLWithPath: "/fixture/data"), kind: .folder, allocatedBytes: 256)
        model.cleanup.scanResults = ScanResults(categories: [
            ScanCategoryResult(categoryID: .systemCaches, totalBytes: 384, entries: [safe, protected])
        ], startedAt: .now, finishedAt: .now)
        let intent = GetSafeToRemoveSizeIntent()
        intent.$model.wrappedValue = model

        let result = try await intent.perform()

        #expect(result.value == 128)
        #expect(result.value == model.cleanup.scanResults.map { Int($0.safeToRemoveBytes) })
        #expect(!model.cleanup.hasStartedInitialScan)
        #expect(model.isShowingWelcome)
    }

    @Test("The size action requires a Cleanup result without starting a scan")
    func scanRequired() async throws {
        let model = AppModel()
        let intent = GetSafeToRemoveSizeIntent()
        intent.$model.wrappedValue = model

        await #expect(throws: MoppoIntentError.scanRequired) { try await intent.perform() }

        #expect(!model.cleanup.hasStartedInitialScan)
    }

    @Test("The Trash action returns bytes without requiring item rows")
    func trash() async throws {
        let folder = try TemporaryFolder()
        try FileManager.default.createDirectory(at: folder.url.appendingPathComponent(".Trash"), withIntermediateDirectories: true)
        _ = try folder.write(".Trash/item.txt")
        let service = TrashService(home: folder.url)
        let expected = try await service.summary(limit: 50)
        var intent = GetTrashSizeIntent()
        intent.trashService = service

        let result = try await intent.perform()

        #expect(result.value == Int(expected.totalBytes))
        #expect(try #require(result.value) > 0)
    }

    @Test("An unreadable Trash names Full Disk Access")
    func trashAccess() async throws {
        var intent = GetTrashSizeIntent()
        intent.trashService = UnreadableTrash()

        await #expect(throws: MoppoIntentError.trashAccessRequired) { try await intent.perform() }
        #expect(String(localized: MoppoIntentError.trashAccessRequired.localizedStringResource).contains("Full Disk Access"))
    }

    @Test("A main window request waits for its presenter")
    func pendingPresentation() {
        let center = MainWindowRequestCenter()
        center.present()
        var presentations = 0
        center.installPresenter { presentations += 1 }
        #expect(presentations == 1)
        center.present()
        #expect(presentations == 2)
    }
}

enum CleanupShortcutAction: CaseIterable {
    case scan, delete

    @MainActor
    func perform(model: AppModel) async throws {
        switch self {
        case .scan:
            var intent = ScanForCleanupItemsIntent()
            intent.$model.wrappedValue = model
            intent.presentMainWindow = {}
            _ = try await intent.perform()
        case .delete:
            let intent = DeleteSafeToRemoveIntent()
            intent.$model.wrappedValue = model
            _ = try await intent.perform()
        }
    }
}

private struct UnreadableTrash: TrashServicing {
    func summary(limit: Int) async throws -> TrashSummary { throw TrashError.unreadable("/fixture/.Trash") }
    func empty() async throws -> EmptyTrashOutcome { Issue.record("The action must not empty the Trash."); return .init() }
    func putBack(_ item: TrashItem) async throws { Issue.record("The action must not restore an item.") }
}
