import Foundation
import SwiftUI
import Testing
@testable import MoppoCore

@Suite("Cleanup feature ownership")
@MainActor
struct CleanupModelTests {
    @Test("Type options count nested matches and follow safety and scan results")
    func dataTypeOptions() throws {
        var safeNode = cleanupEntry("project/node_modules")
        safeNode.kind = .cache
        var reviewNode = cleanupEntry("other/node_modules")
        reviewNode.kind = .cache
        reviewNode.isRegenerable = false
        reviewNode.allocatedBytes = 200
        var project = cleanupEntry("project")
        project.kind = .folder
        project.isRegenerable = false
        project.children = [safeNode, reviewNode]
        var photo = cleanupEntry("holiday.HEIC")
        photo.isRegenerable = false
        var archive = cleanupEntry("Installer.zip")
        archive.kind = .archive
        archive.isRegenerable = false
        let cleanup = CleanupModel(operations: OperationCoordinator())
        cleanup.scanResults = cleanupResults([project, photo, archive])
        cleanup.scanFilter = .all
        #expect(cleanup.dataTypeOptions.map(\.type) == [.all, .nodeModules, .archivesAndInstallers])
        let nodes = try #require(cleanup.dataTypeOptions.first { $0.type == .nodeModules })
        #expect(nodes.count == 2)
        #expect(nodes.bytes == 300)
        cleanup.dataTypeFilter = .nodeModules
        #expect(cleanup.visibleCategories.flatMap(\.entries).map(\.id) == [safeNode.id, reviewNode.id])
        #expect(cleanup.visibleCategories.first?.totalBytes == 300)
        cleanup.scanFilter = .safeToRemove
        #expect(cleanup.dataTypeFilter == .nodeModules)
        #expect(cleanup.dataTypeOptions.map(\.type) == [.all, .nodeModules])
        #expect(cleanup.dataTypeOptions.last?.count == 1)
        #expect(cleanup.dataTypeOptions.last?.bytes == 100)
        cleanup.scanFilter = .all
        cleanup.dataTypeFilter = .archivesAndInstallers
        cleanup.scanFilter = .safeToRemove
        #expect(cleanup.dataTypeFilter == .all)
        cleanup.dataTypeFilter = .nodeModules
        cleanup.scanResults = cleanupResults([photo])
        #expect(cleanup.dataTypeFilter == .all)
        #expect(cleanup.dataTypeOptions.map(\.type) == [.all])
        cleanup.scanFilter = .all
        #expect(cleanup.visibleCategories.flatMap(\.entries).map(\.id) == [photo.id])
    }

    @Test("Type filters preserve selections and limit cleanup totals and plans to visible items")
    func dataTypeSelection() throws {
        var node = cleanupEntry("project/node_modules")
        node.kind = .cache
        var python = cleanupEntry("project/.venv")
        python.kind = .cache
        var project = cleanupEntry("project")
        project.kind = .folder
        project.children = [node, python]
        var otherNode = cleanupEntry("other/node_modules")
        otherNode.kind = .cache
        let audio = cleanupEntry("recording.wav")
        let cleanup = CleanupModel(operations: OperationCoordinator(), measureSaving: { _ in nil })
        cleanup.scanResults = cleanupResults([project, otherNode, audio])
        cleanup.scanFilter = .all
        cleanup.scannerSelection = [project.id, otherNode.id, audio.id]
        cleanup.userDataRemovalOverrides = [project.id, audio.id]
        cleanup.dataTypeFilter = .nodeModules
        #expect(cleanup.scannerSelection == [project.id, otherNode.id, audio.id])
        #expect(cleanup.userDataRemovalOverrides == [project.id, audio.id])
        #expect(cleanup.hiddenSelectionCount == 2)
        #expect(cleanup.cleanupSelectionBytes(in: .all) == otherNode.allocatedBytes)
        #expect(cleanup.selectAllStateInCurrentView == .mixed)
        cleanup.requestCleanUp(in: .all)
        #expect(cleanup.pendingCleanUp?.entries.map(\.id) == [otherNode.id])
        #expect(cleanup.pendingCleanUp?.totalBytes == otherNode.allocatedBytes)
        #expect(cleanup.pendingCleanUp?.userDataRemovalOverrides.isEmpty == true)
        cleanup.cancelCleanUp()
        cleanup.dataTypeFilter = .all
        #expect(cleanup.scannerSelection == [project.id, otherNode.id, audio.id])
        #expect(cleanup.userDataRemovalOverrides == [project.id, audio.id])
        let restoredBytes = [project, node, python, otherNode, audio].reduce(Int64(0)) { $0 + $1.allocatedBytes }
        #expect(cleanup.cleanupSelectionBytes(in: .all) == restoredBytes)
        cleanup.dataTypeFilter = .nodeModules
        cleanup.selectAllInCurrentView()
        #expect(cleanup.scannerSelection == [node.id, otherNode.id, audio.id])
        #expect(cleanup.selectAllStateInCurrentView == .on)
        #expect(cleanup.hiddenSelectionCount == 1)
        #expect(cleanup.selectedBytes(in: .systemCaches) == node.allocatedBytes + otherNode.allocatedBytes)
        cleanup.requestCleanUp(in: .all)
        #expect(Set(cleanup.pendingCleanUp?.entries.map(\.id) ?? []) == [node.id, otherNode.id])
        #expect(cleanup.pendingCleanUp?.entries.first { $0.id == node.id } == node)
        cleanup.cancelCleanUp()
        cleanup.dataTypeFilter = .pythonEnvironments
        #expect(cleanup.scannerSelection == [node.id, otherNode.id, audio.id])
        #expect(cleanup.hiddenSelectionCount == 3)
        #expect(cleanup.cleanupSelectionBytes(in: .all) == 0)
        cleanup.requestCleanUp(in: .all)
        #expect(cleanup.pendingCleanUp == nil)
        cleanup.selectAllInCurrentView()
        #expect(cleanup.scannerSelection == [node.id, otherNode.id, python.id, audio.id])
        cleanup.deselectAllInCurrentView()
        #expect(cleanup.scannerSelection == [node.id, otherNode.id, audio.id])
        cleanup.dataTypeFilter = .nodeModules
        let category = try #require(cleanup.visibleCategories.first)
        #expect(cleanup.selectAllState(in: category) == .on)
        cleanup.setSelected(false, in: category)
        #expect(cleanup.scannerSelection == [audio.id])
        cleanup.setSelected(true, in: category)
        #expect(cleanup.scannerSelection == [node.id, otherNode.id, audio.id])
        cleanup.dataTypeFilter = .all
        #expect(cleanup.scannerSelection == [node.id, otherNode.id, audio.id])
        #expect(!cleanup.scannerSelection.contains(python.id))
        #expect(cleanup.hiddenSelectionCount == 0)
    }

    @Test("Filtered selection keeps protections and busy guards")
    func dataTypeProtection() throws {
        var locked = cleanupEntry("protected/node_modules")
        locked.kind = .cache
        locked.protectionReason = .inventory
        var node = cleanupEntry("project/node_modules")
        node.kind = .cache
        var project = cleanupEntry("project")
        project.kind = .folder
        project.children = [node]
        let operations = OperationCoordinator()
        let cleanup = CleanupModel(operations: operations)
        cleanup.scanResults = cleanupResults([project, locked])
        cleanup.scanFilter = .all
        cleanup.dataTypeFilter = .nodeModules
        cleanup.scannerSelection = [project.id]
        cleanup.setScannerSelection([project.id, node.id])
        #expect(cleanup.scannerSelection == [node.id])
        cleanup.selectAllInCurrentView()
        #expect(cleanup.scannerSelection == [node.id])
        #expect(cleanup.selectAllStateInCurrentView == .on)
        let operation = try #require(operations.begin(.appUninstall))
        cleanup.deselectAllInCurrentView()
        #expect(cleanup.scannerSelection == [node.id])
        operations.finish(operation)
        cleanup.invalidateResults()
        #expect(cleanup.dataTypeFilter == .all)
        #expect(cleanup.hiddenSelectionCount == 0)
    }

    @Test("The cleanup button follows visible selections across type and safety filters")
    func cleanupButtonScope() {
        var node = cleanupEntry("project/node_modules")
        node.kind = .cache
        var archive = cleanupEntry("Installer.zip")
        archive.kind = .archive
        archive.isRegenerable = false
        let image = FileEntry(
            url: URL(string: "docker://images/fixture")!, kind: .diskImage, allocatedBytes: 200,
            dockerImage: DockerImage(imageID: "fixture", context: "fixture", tags: ["fixture:latest"], containerCount: 0)
        )
        let app = AppModel()
        app.view = .scanner
        let cleanup = app.cleanup
        cleanup.scanFilter = .all
        cleanup.scanResults = cleanupResults([node, archive, image])
        cleanup.scannerSelection = [node.id, archive.id, image.id]
        #expect(cleanup.hasSelectedDockerImages)
        cleanup.dataTypeFilter = .nodeModules
        #expect(!cleanup.hasSelectedDockerImages)
        #expect(app.removeLabel == "Move to Trash (\(ByteFormatting.string(node.allocatedBytes)))")
        cleanup.setScannerSelection(cleanup.scannerSelection.subtracting([node.id]))
        #expect(cleanup.cleanupSelection(in: cleanup.scanFilter).isEmpty)
        #expect(app.removeLabel == "Move to Trash (\(ByteFormatting.string(0)))")
        cleanup.requestCleanUp(in: cleanup.scanFilter)
        #expect(cleanup.pendingCleanUp == nil)
        cleanup.dataTypeFilter = .all
        #expect(cleanup.scannerSelection == [archive.id, image.id])
        #expect(cleanup.hasSelectedDockerImages)
        let remainingBytes = archive.allocatedBytes + image.allocatedBytes
        #expect(app.removeLabel == "Remove (\(ByteFormatting.string(remainingBytes)))")
        cleanup.scanFilter = .safeToRemove
        #expect(!cleanup.hasSelectedDockerImages)
        #expect(app.removeLabel == "Move to Trash (\(ByteFormatting.string(0)))")
        cleanup.requestCleanUp(in: cleanup.scanFilter)
        #expect(cleanup.pendingCleanUp == nil)
        cleanup.scanFilter = .all
        #expect(app.removeLabel == "Remove (\(ByteFormatting.string(remainingBytes)))")
    }

    @Test("Worktrees seed only safe rows and warn before explicit unsafe selection")
    func worktreeSelectionAndReview() {
        var safe = safeWorktreeReview()
        safe.mergedInto = "origin/main"
        var ignored = GitWorktreeReview.File(path: ".env", status: .ignored, regeneratesSafely: false)
        ignored.canRemoveWhenMerged = true
        safe.ignoredFiles = [ignored]
        var local = safe
        local.status = .uncommittedChanges
        local.localFiles = [.init(path: "notes.txt", status: .untracked)]
        var safeEntry = cleanupEntry("safe-worktree")
        safeEntry.gitWorktreeReview = safe
        var localEntry = cleanupEntry("local-worktree")
        localEntry.gitWorktreeReview = local
        var unknownEntry = cleanupEntry("unknown-worktree")
        unknownEntry.gitWorktreeReview = GitWorktreeReview()
        var parent = cleanupEntry("worktree-parent")
        parent.isRegenerable = false
        parent.children = [safeEntry, localEntry, unknownEntry]
        let cleanup = CleanupModel(operations: OperationCoordinator(),
            preferences: { .init(confirmBeforeCleanup: false) }, measureSaving: { _ in nil })
        cleanup.scanResults = cleanupResults([parent])
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection == [safeEntry.id])
        cleanup.updateWorktreeReview(local, for: safeEntry.id)
        #expect(cleanup.scannerSelection.isEmpty)
        cleanup.scannerSelection = [parent.id]
        cleanup.selectWorktree(localEntry.id)
        #expect(cleanup.scannerSelection == [localEntry.id])
        cleanup.selectWorktree(unknownEntry.id)
        var requested = false
        cleanup.onEvent = { if case .confirmationRequested = $0 { requested = true } }
        cleanup.requestCleanUp(in: .all)
        #expect(requested)
        #expect(cleanup.pendingCleanUp?.worktreeWarning?.contains("1 worktree has uncommitted changes.") == true)
        #expect(cleanup.pendingCleanUp?.worktreeWarning?.contains("1 worktree needs further review.") == true)
        cleanup.cancelCleanUp()
    }

    @Test("Parent selection includes grouped worktree checks and remainder bytes", arguments: [false, true])
    func groupedWorktreeParentReview(hasLocalChanges: Bool) throws {
        var worktree = cleanupEntry("parent/cache/task")
        var review = safeWorktreeReview()
        if hasLocalChanges {
            review.status = .uncommittedChanges
            review.localFiles = [.init(path: "notes.txt", status: .untracked)]
        }
        worktree.gitWorktreeReview = review
        var remainder = cleanupEntry("parent/cache")
        remainder.protectionReason = .folderRemainder
        var parent = cleanupEntry("parent")
        parent.kind = .folder
        parent.isRegenerable = false
        parent.children = [remainder, worktree]
        let cleanup = CleanupModel(operations: OperationCoordinator(), measureSaving: { _ in nil })
        cleanup.scanResults = cleanupResults([parent])
        cleanup.scanFilter = .all
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection == (hasLocalChanges ? [] : [worktree.id]))
        #expect(!parent.isRemovalLocked)
        cleanup.scannerSelection = [remainder.id]
        #expect(cleanup.cleanupSelection(in: .all).isEmpty)
        cleanup.scannerSelection = [parent.id]
        #expect(cleanup.selectedBytes(in: .systemCaches) == 300)
        cleanup.requestCleanUp(in: .all)
        let plan = try #require(cleanup.pendingCleanUp)
        #expect(plan.entries.map(\.id) == [parent.id])
        #expect(plan.totalBytes == 300)
        #expect((plan.worktreeWarning != nil) == hasLocalChanges)
        #expect(CleanupService.alwaysMovesToTrash(parent))
        cleanup.cancelCleanUp()
    }

    @Test("Docker scanning defaults on and preserves a saved choice")
    func dockerDefault() throws {
        let suite = "moppo-tests.docker-default.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fresh = SettingsStore(defaults: defaults, managesLoginItem: false)
        #expect(fresh.isEnabled(.docker))
        fresh.setEnabled(false, for: .docker)
        let reopened = SettingsStore(defaults: defaults, managesLoginItem: false)
        #expect(!reopened.isEnabled(.docker))
        reopened.resetToDefaults()
        #expect(reopened.isEnabled(.docker))
        #expect(SettingsStore(defaults: defaults, managesLoginItem: false).isEnabled(.docker))
    }

    enum WorktreeChange: CaseIterable { case unchanged, localChanges, inUse, unavailable, mergeLost }

    @Test("Docker setup remains visible across filters only for an installed application", arguments: CleanupModel.ScanFilter.allCases)
    func dockerCategoryVisibility(filter: CleanupModel.ScanFilter) {
        let cleanup = CleanupModel(operations: OperationCoordinator())
        cleanup.scanFilter = filter
        let prompt = ScanCategoryResult.unavailable(.docker, reason: "Start Docker Desktop, then scan again to see results.")
        cleanup.scanResults = ScanResults(categories: [prompt], startedAt: .now, finishedAt: .now)
        #expect(cleanup.visibleCategories == [prompt])
        #expect(cleanup.scanResults?.safeToRemoveBytes == 0)
        #expect(cleanup.scannerSelection.isEmpty)
        cleanup.scanResults?.categories = [ScanCategoryResult(categoryID: .docker, availability: .notInstalled)]
        #expect(cleanup.visibleCategories.isEmpty)
        cleanup.scanResults?.categories = [.empty(.docker)]
        #expect(cleanup.visibleCategories == (filter == .all ? [.empty(.docker)] : []))
    }

    @Test("Changed worktrees leave selection while other cleanup items proceed", arguments: WorktreeChange.allCases)
    func changedWorktree(_ change: WorktreeChange) async throws {
        let fixture = try CleanupFixture()
        var initial = safeWorktreeReview()
        initial.mergedInto = "origin/main"
        var ignored = GitWorktreeReview.File(path: ".env", status: .ignored, regeneratesSafely: false)
        ignored.canRemoveWhenMerged = true
        initial.ignoredFiles = [ignored]
        let worktrees = try (0..<3).map { index in
            var entry = try fixture.entry("worktree-\(index)")
            entry.gitWorktreeReview = initial
            return entry
        }
        let cache = try fixture.entry("cache")
        let removal = HeldCleanupRemoval()
        let gate = TestGate()
        let operations = OperationCoordinator()
        let cleanup = CleanupModel(operations: operations, remover: removal,
            reviewWorktrees: { urls in
                await gate.wait()
                var review = initial
                switch change {
                case .unchanged: break
                case .localChanges: review.status = .uncommittedChanges
                case .inUse: review.activity = .found("Active process")
                case .unavailable: throw CocoaError(.fileReadNoPermission)
                case .mergeLost: review.mergedInto = nil
                }
                return Dictionary(uniqueKeysWithValues: urls.map { ($0, review) })
            }, measureSaving: { _ in nil })
        cleanup.scanResults = cleanupResults(worktrees + [cache])
        cleanup.scannerSelection = Set((worktrees + [cache]).map(\.id))
        var failures = 0
        var announcedCount: Int?
        var isCheckingWorktrees = false
        cleanup.onEvent = {
            if case .failure = $0 { failures += 1 }
            if case .checkingWorktrees = $0 { isCheckingWorktrees = true }
            if case .removalStarted(let count, _) = $0 { announcedCount = count }
        }
        cleanup.requestCleanUp(in: .safeToRemove)
        let task = Task { await cleanup.performCleanUp() }
        try await waitUntil { await gate.isPending }
        // One request checks every selected worktree with one process inventory.
        #expect(await gate.count == 1)
        #expect(isCheckingWorktrees)
        #expect(announcedCount == nil)
        #expect(cleanup.isRemoving)
        #expect(operations.isBusy)
        #expect(await removal.requestCount == 0)
        #expect(cleanup.visibleCategories.flatMap(\.entries).count == 4)
        #expect(worktrees.allSatisfy { cleanup.scannerSelection.contains($0.id) })
        await gate.finish()
        try await waitUntil { await removal.isPending }
        let expected = change == .unchanged ? worktrees + [cache] : [cache]
        #expect(await removal.entries.map(\.id) == expected.map(\.id))
        #expect(worktrees.allSatisfy { cleanup.scannerSelection.contains($0.id) == (change == .unchanged) })
        #expect(announcedCount == expected.count)
        await removal.finish(.init(removedCount: expected.count, trashedCount: expected.count))
        await task.value
        #expect(cleanup.cleanupOutcome?.skippedWorktrees == (change == .unchanged ? [] : worktrees.map(\.id).sorted()))
        #expect(failures == 0)
        #expect(!operations.isBusy)
        #expect(worktrees.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) })
    }

    @Test("Opening worktree dialogs reuses completed checks", arguments: [false, true])
    func cachedWorktreeDialog(safe: Bool) async throws {
        var entry = cleanupEntry("reviewed-worktree")
        var review = safeWorktreeReview()
        if !safe { review.activity = .unknown("The process check timed out.") }
        entry.gitWorktreeReview = review
        let gate = TestGate()
        let output = URL(fileURLWithPath: "/tmp/moppo-228-worktree-previews", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var updates = 0
        var probeRan = false
        for dark in [false, true] {
            let sheet = WorktreeReviewSheet(entry: entry, onReview: { _ in updates += 1 }, onSelect: {}, onClose: {},
                reviewWorktree: { _ in await gate.wait(); return review })
            _ = try await renderTestView(sheet.background(Token.chrome), width: 500, dark: dark,
                output: output.appendingPathComponent("\(safe ? "safe" : "unknown")-\(dark ? "dark" : "light").png"))
        }
        // The probe shows that this window runs view tasks, so the sheet had a chance to start a check.
        let host = NSHostingView(rootView: ZStack {
            WorktreeReviewSheet(entry: entry, onReview: { _ in updates += 1 }, onSelect: {}, onClose: {},
                reviewWorktree: { _ in await gate.wait(); return review })
            Color.clear.task { probeRan = true }
        }.frame(width: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 620),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await waitUntil { probeRan }
        try await Task.sleep(for: .milliseconds(100))
        let requests = await gate.count
        if await gate.isPending { await gate.finish() }
        #expect(requests == 0)
        #expect(updates == 0)
    }

    @Test("A changed worktree also protects a selected parent", arguments: [false, true])
    func changedWorktreeParent(selectedParent: Bool) async throws {
        var worktree = cleanupEntry("changed-worktree")
        worktree.gitWorktreeReview = safeWorktreeReview()
        var selected = worktree
        if selectedParent {
            selected = cleanupEntry("parent")
            var remainder = cleanupEntry("parent/cache")
            remainder.protectionReason = .folderRemainder
            selected.children = [remainder, worktree]
        }
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(operations: OperationCoordinator(), remover: removal,
            reviewWorktrees: { _ in [:] }, measureSaving: { _ in nil })
        cleanup.scanResults = cleanupResults([selected])
        cleanup.scannerSelection = [selected.id]
        cleanup.userDataRemovalOverrides = [selected.id, worktree.id]
        var refreshes = 0
        var checkingEvents = 0
        var removalEvents = 0
        cleanup.onEvent = {
            if case .checkingWorktrees = $0 { checkingEvents += 1 }
            if case .removalStarted = $0 { removalEvents += 1 }
        }
        cleanup.refreshAfterRemoval = { refreshes += 1 }
        cleanup.requestCleanUp(in: .all)
        await cleanup.performCleanUp()
        try await waitUntil { !cleanup.isRemoving }
        #expect(await removal.requestCount == 0)
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.userDataRemovalOverrides.isEmpty)
        #expect(cleanup.cleanupOutcome?.skippedWorktrees == [worktree.id])
        #expect(cleanup.cleanupOutcome?.removedCount == 0)
        #expect(refreshes == 0)
        #expect(checkingEvents == 1)
        #expect(removalEvents == 0)
        #expect(cleanup.allEntries.first { $0.id == worktree.id }?.gitWorktreeReview?.isSafeToRemove == false)
    }

    @Test("Cleanup identifies kept worktrees after removing other items")
    func changedWorktreeNotice() async throws {
        let fixture = try CleanupFixture()
        let cache = try fixture.entry("notice-cache")
        let removal = HeldCleanupRemoval()
        let app = AppModel(cleanupRemover: removal)
        app.view = .scanner
        app.cleanup.refreshAfterRemoval = {}
        app.cleanup.scanResults = cleanupResults([cache])
        app.cleanup.scannerSelection = [cache.id]
        app.cleanup.requestCleanUp(in: .all)
        let task = Task { await app.cleanup.performCleanUp() }
        try await waitUntil { await removal.isPending }
        let kept = fixture.root.appendingPathComponent("changed-worktree")
        await removal.finish(.init(removedCount: 1, trashedCount: 1, skippedWorktrees: [kept.path]))
        await task.value
        try await waitUntil { !app.cleanup.isRemoving }
        let notice = try #require(app.notice)
        #expect(notice.title == "Worktrees Were Kept")
        #expect(notice.message.contains("changed-worktree"))
        #expect(notice.message.contains("The folders remain on disk. Select All to review their current status."))
        #expect(notice.message.contains("Moppo removed 1 other item."))
        #expect(notice.finderURLs == [kept])
    }

    @Test("A build folder review selects the whole folder while automatic selection keeps only caches")
    func buildFolderSelection() async throws {
        let fixture = try TemporaryFolder()
        let root = fixture.url.appendingPathComponent("Temporary/job")
        for path in ["Build/Products/Debug", "Logs/Build", "TestResults"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        _ = try fixture.write("Temporary/job/Build/Products/Debug/app.o")
        _ = try fixture.write("Temporary/job/Logs/Build/build.xcactivitylog")
        let info = try PropertyListSerialization.data(fromPropertyList:
            ["WorkspacePath": "/Projects/Demo/Demo.xcodeproj/project.xcworkspace"], format: .xml, options: 0)
        try info.write(to: root.appendingPathComponent("info.plist"))
        let testMetadata = try PropertyListSerialization.data(fromPropertyList:
            ["FormatVersion": 1, "Store": [:]], format: .xml, options: 0)
        try testMetadata.write(to: root.appendingPathComponent("TestResults/metadata.db"))
        var scanner = XcodeScanner(developerRoot: fixture.url.appendingPathComponent("no-developer"),
            projectRoots: [], systemSimulatorRoot: fixture.url.appendingPathComponent("no-simulators"),
            temporaryRoots: [root.deletingLastPathComponent()])
        scanner.captureBuildActivity = { WorktreeActivity(roots: $0, processes: [:]) }
        let category = try await scanner.scan(context: ScanContext())
        let parent = try #require(category.entries.first)
        let cache = try #require(parent.children.first { $0.isRegenerable })
        let cleanup = CleanupModel(operations: OperationCoordinator(), measureSaving: { _ in nil })
        let now = Date()
        cleanup.scanResults = ScanResults(categories: [category], startedAt: now, finishedAt: now)
        cleanup.scanFilter = .all
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection == [cache.id])
        #expect(cleanup.selectedBytes(in: .xcode) == cache.allocatedBytes)
        let testResults = try #require(parent.children.first { $0.url.lastPathComponent == "TestResults" })
        cleanup.scannerSelection = [testResults.id]
        #expect(cleanup.cleanupSelection(in: .safeToRemove).isEmpty)
        #expect(cleanup.cleanupSelection(in: .all) == [testResults.id])
        cleanup.scannerSelection = [parent.id, cache.id]
        #expect(cleanup.cleanupSelection(in: .all) == [parent.id])
        #expect(cleanup.selectedBytes(in: .xcode) == parent.displayBytes)
        cleanup.requestCleanUp(in: .all)
        #expect(cleanup.pendingCleanUp?.entries.map(\.id) == [parent.id])
        #expect(cleanup.scannerSelection.contains(parent.id))
    }

    @Test("AI inventory stays visible but cannot enter cleanup selection")
    func aiInventorySelection() {
        var cache = cleanupEntry("ai-cache")
        cache.isRegenerable = true
        var history = cleanupEntry("ai-history")
        history.protectionReason = .inventory
        var root = cleanupEntry("ai-root")
        root.isRegenerable = false
        root.protectionReason = .inventory
        root.children = [cache, history]
        let category = ScanCategoryResult(categoryID: .aiTools,
            totalBytes: root.displayBytes, entries: [root])
        let cleanup = CleanupModel(operations: OperationCoordinator())
        let now = Date()
        cleanup.scanResults = ScanResults(categories: [category], startedAt: now, finishedAt: now)
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection == [cache.id])
        cleanup.scanFilter = .all
        #expect(cleanup.selectableIDs(in: category) == [cache.id])
        #expect(cleanup.selectAllStateInCurrentView == .on)
        #expect(cleanup.selectAllState(in: category) == .on)
        cleanup.scannerSelection = [root.id, history.id, cache.id]
        cleanup.userDataRemovalOverrides = [root.id, history.id]
        #expect(cleanup.selectedEntries.map(\.id) == [cache.id])
        #expect(cleanup.cleanupSelection(in: .all) == [cache.id])
        #expect(cleanup.selectedBytes(in: .aiTools) == cache.allocatedBytes)
    }

    @Test("Codex session deletion always requires confirmation and cannot enter safe cleanup")
    func codexSessionConfirmation() {
        let home = URL(fileURLWithPath: "/moppo-fixture/.codex")
        var session = cleanupEntry("codex-session")
        session.isRegenerable = false
        session.protectionReason = .userData
        session.codexSession = .init(codexHome: home, threadID: "parent", members: [
            .init(threadID: "parent", url: session.url, identity: "fixture-parent", modifiedAt: .distantPast, fileSize: 1),
            .init(threadID: "child", url: home.appendingPathComponent("child.jsonl"), identity: "fixture-child", modifiedAt: .distantPast, fileSize: 1)
        ])
        var group = cleanupEntry("codex-sessions")
        group.isRegenerable = false
        group.protectionReason = .inventory
        group.children = [session]
        let category = ScanCategoryResult(categoryID: .aiTools, totalBytes: group.displayBytes, entries: [group])
        let cleanup = CleanupModel(operations: OperationCoordinator(),
            preferences: { .init(confirmBeforeCleanup: false) }, measureSaving: { _ in nil })
        let now = Date()
        cleanup.scanResults = ScanResults(categories: [category], startedAt: now, finishedAt: now)
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.selectableIDs(in: category).isEmpty)
        cleanup.scannerSelection = [session.id]
        cleanup.userDataRemovalOverrides = [session.id]
        #expect(cleanup.cleanupSelection(in: .safeToRemove).isEmpty)
        #expect(cleanup.cleanupSelection(in: .all) == [session.id])
        var requested = false
        cleanup.onEvent = { if case .confirmationRequested = $0 { requested = true } }
        cleanup.requestCleanUp(in: .all)
        #expect(requested)
        #expect(cleanup.pendingCleanUp?.codexSessionCount == 2)
        #expect(cleanup.pendingCleanUp?.codexSessionWarning?.contains("1 child session") == true)
        #expect(cleanup.pendingCleanUp?.totalBytes == session.allocatedBytes)
        cleanup.cancelCleanUp()
    }

    @Test("Group review unlocks unchanged children without selection and keeps them unlocked after deselection")
    func childGroupReview() throws {
        let home = URL(fileURLWithPath: "/moppo-fixture/.codex")
        func session(_ name: String) -> FileEntry {
            var entry = cleanupEntry(name)
            entry.isRegenerable = false
            entry.protectionReason = .userData
            entry.codexSession = .init(codexHome: home, threadID: name, members: [
                .init(threadID: name, url: entry.url, identity: name, modifiedAt: .distantPast, fileSize: 1)
            ])
            return entry
        }
        let first = session("first")
        let second = session("second")
        var active = session("active")
        active.protectionReason = .inventory
        var otherData = cleanupEntry("unknown-data")
        otherData.protectionReason = .inventory
        var group = cleanupEntry("codex-sessions")
        group.aiTool = .codex
        group.protectionReason = .inventory
        group.children = [first, second, active, otherData]
        let operations = OperationCoordinator()
        let cleanup = CleanupModel(operations: operations)
        cleanup.scanResults = cleanupResults([group])
        let unrelated = cleanupEntry("unrelated")
        cleanup.scannerSelection = [unrelated.id]
        cleanup.userDataRemovalOverrides = [unrelated.id]
        let operation = try #require(operations.begin(.fileScan))
        cleanup.unlockChildren(in: group)
        cleanup.setChildrenSelected(true, in: group.id)
        #expect(cleanup.scannerSelection == [unrelated.id])
        operations.finish(operation)

        var changedGroup = group
        changedGroup.children[0].protectionReason = .inventory
        changedGroup.children[1].codexSession = .init(codexHome: home, threadID: "second", members: [
            .init(threadID: "second", url: second.url, identity: "replacement", modifiedAt: .distantPast, fileSize: 2)
        ])
        changedGroup.children.append(session("new-session"))
        cleanup.scanResults = cleanupResults([changedGroup])
        cleanup.unlockChildren(in: group)
        #expect(cleanup.scannerSelection == [unrelated.id])
        #expect(cleanup.userDataRemovalOverrides == [unrelated.id])

        cleanup.scanResults = cleanupResults([group])
        cleanup.setChildrenSelected(true, in: group.id)
        #expect(cleanup.scannerSelection == [unrelated.id])
        cleanup.scannerSelection.insert(first.id)
        cleanup.userDataRemovalOverrides.insert(first.id)
        cleanup.unlockChildren(in: group)
        #expect(cleanup.scannerSelection == [unrelated.id])
        #expect(cleanup.userDataRemovalOverrides == [unrelated.id, first.id, second.id])
        #expect(cleanup.selectedEntries.isEmpty)
        cleanup.setChildrenSelected(true, in: group.id)
        #expect(cleanup.scannerSelection == [unrelated.id, first.id, second.id])
        #expect(cleanup.selectedEntries.map(\.id) == [first.id, second.id])
        #expect(cleanup.cleanupSelection(in: .safeToRemove).isEmpty)
        cleanup.setChildrenSelected(false, in: group.id)
        #expect(cleanup.scannerSelection == [unrelated.id])
        #expect(cleanup.userDataRemovalOverrides == [unrelated.id, first.id, second.id])
        cleanup.selectAllInCurrentView()
        #expect(cleanup.scannerSelection == [unrelated.id, first.id, second.id])
        cleanup.deselectAllInCurrentView()
        #expect(cleanup.scannerSelection == [unrelated.id])
        #expect(cleanup.userDataRemovalOverrides == [unrelated.id])
    }

    @Test("Other protected groups use child unlocking while complete removal groups keep their own review")
    func otherChildGroups() {
        var data = cleanupEntry("profile")
        data.protectionReason = .userData
        var active = cleanupEntry("active")
        active.protectionReason = .running
        var group = cleanupEntry("storage-group")
        group.children = [data, active]
        let cleanup = CleanupModel(operations: OperationCoordinator())
        cleanup.scanResults = cleanupResults([group])
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(group.unlockableChildren.map(\.id) == [data.id])
        cleanup.unlockChildren(in: group)
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.userDataRemovalOverrides == [data.id])
        cleanup.setChildrenSelected(true, in: group.id)
        #expect(cleanup.selectedEntries.map(\.id) == [data.id])
        #expect(cleanup.cleanupSelection(in: .all) == [data.id])
        cleanup.scannerSelection.insert(group.id)
        #expect(cleanup.selectedEntries.map(\.id) == [data.id])
        #expect(cleanup.cleanupSelection(in: .all) == [data.id])
        group.removesAsUnit = true
        #expect(group.unlockableChildren.isEmpty)
        group.removesAsUnit = false
        group.kind = .appBundle
        #expect(group.unlockableChildren.isEmpty)
    }

    @Test("Opening Cleanup starts one foreground scan with full or limited access", arguments: [false, true])
    func initialScan(hasDiskAccess: Bool) async throws {
        let scanner = HeldCleanupScanner()
        let app = AppModel(
            launchAccess: hasDiskAccess ? .ready : .limited,
            hasFullDiskAccess: { hasDiskAccess }, cleanupScanner: scanner
        )
        app.view = .history
        app.startInitialCleanupScan()
        #expect(!app.cleanup.hasStartedInitialScan)
        app.view = .scanner
        app.startInitialCleanupScan()
        app.startInitialCleanupScan()
        try await waitUntil { await scanner.requestCount == 1 }
        #expect(app.cleanup.isScanning)
        #expect(app.cleanup.hasStartedInitialScan)
        #expect(app.checkDiskAccess(automatic: true) == hasDiskAccess)
        await scanner.report(0, percent: 32)
        try await waitUntil { app.cleanup.scanProgress == 32 }
        let results = cleanupResults([])
        await scanner.finish(0, results: results)
        try await waitUntil { !app.cleanup.isScanning }
        #expect(app.cleanup.scanResults == results)
        #expect(!app.isBusyWithDisk)
        app.startInitialCleanupScan()
        #expect(!app.cleanup.isScanning)
        #expect(await scanner.requestCount == 1)
    }

    @Test("Cancellation retains the guard and rejects old callbacks after a restart")
    func scanLifetime() async throws {
        let scanner = HeldCleanupScanner()
        let app = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        let cleanup = app.cleanup
        cleanup.dismissRunningAppsNotice()
        #expect(cleanup.isRunningAppsNoticeDismissed)
        cleanup.startScan(refreshOverview: false)
        #expect(!cleanup.isRunningAppsNoticeDismissed)
        try await waitUntil { await scanner.requestCount == 1 }
        app.view = .history
        cleanup.dismissRunningAppsNotice()
        app.view = .scanner
        #expect(cleanup.isRunningAppsNoticeDismissed)
        app.view = .history
        #expect(app.storageExplorer.isMeasurementBlocked)
        #expect(app.isBusyWithDisk)
        cleanup.cancelScan()
        #expect(cleanup.isInterruptingScan)
        cleanup.startScan(refreshOverview: false)
        #expect(cleanup.isRunningAppsNoticeDismissed)
        #expect(await scanner.requestCount == 1)
        await scanner.report(0, percent: 99, phase: "Old phase")
        await scanner.finish(0, results: cleanupResults([]))
        try await waitUntil { !cleanup.isScanning }
        #expect(cleanup.scanResults == nil)
        #expect(cleanup.scanProgress == 0)
        #expect(cleanup.scanPhase == nil)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)

        cleanup.startScan(automatic: true, refreshOverview: false)
        #expect(!cleanup.isRunningAppsNoticeDismissed)
        try await waitUntil { await scanner.requestCount == 2 }
        #expect(app.view == .history)
        await scanner.report(1, percent: 32, phase: "Measuring local iCloud files")
        try await waitUntil { cleanup.scanProgress == 32 }
        #expect(cleanup.scanProgressDetail == "32% · Measuring local iCloud files")
        let measurementPhase = "Measuring Project\nFiles checked: 1,024 · Worktrees found: 12"
        await scanner.report(1, percent: 32, phase: measurementPhase)
        try await waitUntil { cleanup.scanPhase == measurementPhase }
        #expect(cleanup.scanProgressDetail == "32% · \(measurementPhase)")
        #expect(cleanup.scanProgress == 32)
        await scanner.report(0, percent: 98, phase: "Old phase")
        let latest = cleanupResults([])
        await scanner.finish(1, results: latest)
        try await waitUntil { !cleanup.isScanning }
        #expect(cleanup.scanResults == latest)
        #expect(cleanup.scanProgress == 32)
        #expect(cleanup.scanPhase == measurementPhase)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)
    }

    @Test("Permanent notice dismissal remains saved across scans and model creation")
    func permanentRunningAppsNoticeDismissal() async throws {
        let suite = "CleanupModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = HeldCleanupScanner()
        let cleanup = CleanupModel(operations: OperationCoordinator(), scanner: scanner, defaults: defaults)
        #expect(!cleanup.isRunningAppsNoticeDismissed)
        cleanup.dismissRunningAppsNotice(permanently: true)
        #expect(cleanup.isRunningAppsNoticeDismissed)
        cleanup.startScan(refreshOverview: false)
        #expect(cleanup.isRunningAppsNoticeDismissed)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.finish(0, results: cleanupResults([]))
        try await waitUntil { !cleanup.isScanning }
        #expect(cleanup.isRunningAppsNoticeDismissed)
        let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
        let reopened = CleanupModel(operations: OperationCoordinator(), defaults: reopenedDefaults)
        #expect(reopened.isRunningAppsNoticeDismissed)
    }

    @Test("A failed scan releases the guard and permits another scan")
    func scanFailure() async throws {
        let scanner = HeldCleanupScanner()
        let app = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        app.cleanup.startScan(refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.fail(0)
        try await waitUntil { !app.cleanup.isScanning }
        #expect(app.notice?.title == "The Scan Did Not Finish")
        #expect(!app.isBusyWithDisk)
        app.cleanup.startScan(refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 2 }
        app.cleanup.invalidateResults()
        await scanner.finish(1, results: cleanupResults([]))
        try await waitUntil { !app.cleanup.isScanning }
        #expect(app.cleanup.scanResults == nil)
        #expect(!app.cleanup.hasStartedInitialScan)
    }

    @Test("Another operation blocks Cleanup scans and removal")
    func sharedGuard() async throws {
        let operations = OperationCoordinator()
        let scanner = HeldCleanupScanner()
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(operations: operations, scanner: scanner, remover: removal)
        let item = cleanupEntry("guard")
        cleanup.scanResults = cleanupResults([item])
        cleanup.scannerSelection = [item.id]
        cleanup.requestCleanUp(in: .all)
        let operation = try #require(operations.begin(.fileScan))
        cleanup.startScan()
        await cleanup.performCleanUp()
        #expect(await scanner.requestCount == 0)
        #expect(await removal.requestCount == 0)
        #expect(cleanup.pendingCleanUp != nil)
        #expect(!cleanup.isRemoving)
        operations.finish(operation)
        cleanup.cancelCleanUp()
    }

    @Test("Scans capture preferences and seed safe selection only once")
    func preferencesAndSelection() async throws {
        let scanner = HeldCleanupScanner()
        var preferences = CleanupModel.Preferences(
            enabledCategories: [.systemCaches], excludedPaths: ["/excluded"], excludedPatterns: ["*.keep"]
        )
        let suite = "CleanupModelTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cleanup = CleanupModel(
            operations: OperationCoordinator(), scanner: scanner,
            preferences: { preferences }, defaults: defaults
        )
        let child = cleanupEntry("child")
        var parent = cleanupEntry("parent")
        parent.children = [child]
        var protected = cleanupEntry("protected")
        protected.protectionReason = .userData
        cleanup.scannerSelection = [protected.id]
        cleanup.userDataRemovalOverrides = [protected.id]
        cleanup.startScan()
        preferences.excludedPaths = ["/later"]
        #expect(cleanup.userDataRemovalOverrides.isEmpty)
        #expect(cleanup.scannerSelection.isEmpty)
        try await waitUntil { await scanner.requestCount == 1 }
        let captured = try #require(await scanner.preferences.first)
        #expect(captured.excludedPaths == ["/excluded"])
        #expect(captured.excludedPatterns == ["*.keep"])
        #expect(captured.enabledCategories == [.systemCaches])
        let results = cleanupResults([parent, protected])
        await scanner.finish(0, results: results)
        try await waitUntil { !cleanup.isScanning }
        #expect(cleanup.scannerSelection == [parent.id])
        #expect(cleanup.openCategories.isEmpty)
        #expect(cleanup.lastScanFinishedAt == results.finishedAt)
        #expect(defaults.object(forKey: "lastScanFinishedAt") as? Date == results.finishedAt)
        cleanup.deselectAll()
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection.isEmpty)
        cleanup.scanFilter = .all
        cleanup.selectAllInCurrentView()
        #expect(cleanup.scannerSelection == [parent.id])
        #expect(!cleanup.scannerSelection.contains(child.id))
    }

    @Test("Select All shows partial selection when the filter contains more selectable items")
    func selectAllStateAcrossFilters() {
        let first = cleanupEntry("first-cache")
        let second = cleanupEntry("second-cache")
        var review = cleanupEntry("review-file")
        review.isRegenerable = false
        var locked = cleanupEntry("locked-file")
        locked.protectionReason = .inventory
        locked.isRegenerable = false
        let cleanup = CleanupModel(operations: OperationCoordinator())
        cleanup.scanResults = cleanupResults([first, second, review, locked])
        #expect(cleanup.selectAllStateInCurrentView == .off)
        cleanup.scannerSelection = [first.id]
        #expect(cleanup.selectAllStateInCurrentView == .mixed)
        cleanup.selectAllInCurrentView()
        #expect(cleanup.selectAllStateInCurrentView == .on)
        cleanup.scanFilter = .all
        #expect(cleanup.scannerSelection == [first.id, second.id])
        #expect(cleanup.selectAllStateInCurrentView == .mixed)
        cleanup.selectAllInCurrentView()
        #expect(cleanup.scannerSelection == [first.id, second.id, review.id])
        #expect(cleanup.selectAllStateInCurrentView == .on)
        cleanup.scanFilter = .safeToRemove
        #expect(cleanup.scannerSelection == [first.id, second.id, review.id])
        #expect(cleanup.cleanupSelectionBytes(in: .safeToRemove) == first.allocatedBytes + second.allocatedBytes)
        #expect(cleanup.selectedBytes(in: .systemCaches, filter: .safeToRemove) == first.allocatedBytes + second.allocatedBytes)
        #expect(cleanup.selectAllStateInCurrentView == .on)
        cleanup.deselectAllInCurrentView()
        #expect(cleanup.scannerSelection == [review.id])
        #expect(cleanup.selectAllStateInCurrentView == .off)
        cleanup.scanFilter = .all
        #expect(cleanup.cleanupSelectionBytes(in: .all) == review.allocatedBytes)
        #expect(cleanup.selectedBytes(in: .systemCaches) == review.allocatedBytes)
        #expect(cleanup.selectAllStateInCurrentView == .mixed)
        cleanup.deselectAllInCurrentView()
        #expect(cleanup.selectAllStateInCurrentView == .off)
    }

    @Test("A category checkbox selects only its removable rows and clears only its own selection")
    func categorySelection() throws {
        let operations = OperationCoordinator()
        let cleanup = CleanupModel(operations: operations)
        let child = cleanupEntry("child")
        var parent = cleanupEntry("parent")
        parent.children = [child]
        var locked = cleanupEntry("locked")
        locked.protectionReason = .userData
        locked.isRegenerable = false
        let appCache = cleanupEntry("app-cache")
        var app = cleanupEntry("Application.app")
        app.kind = .appBundle
        app.isRegenerable = false
        app.children = [appCache]
        let unrelated = cleanupEntry("other-category")
        let category = ScanCategoryResult(
            categoryID: .systemCaches, totalBytes: 300, entries: [parent, locked, app]
        )
        cleanup.scanFilter = .all
        cleanup.scannerSelection = [unrelated.id, child.id]
        cleanup.userDataRemovalOverrides = [child.id]
        #expect(cleanup.selectedIDs(in: category) == [child.id])
        #expect(cleanup.selectableIDs(in: category) == [parent.id, appCache.id])
        #expect(cleanup.selectAllState(in: category) == .mixed)

        cleanup.setSelected(true, in: category)
        #expect(cleanup.scannerSelection == [unrelated.id, parent.id, appCache.id])
        #expect(cleanup.userDataRemovalOverrides.isEmpty)
        #expect(cleanup.selectAllState(in: category) == .on)
        cleanup.scannerSelection.insert(locked.id)
        cleanup.userDataRemovalOverrides = [locked.id, unrelated.id]
        cleanup.setSelected(false, in: category)
        #expect(cleanup.scannerSelection == [unrelated.id])
        #expect(cleanup.userDataRemovalOverrides == [unrelated.id])
        #expect(cleanup.selectAllState(in: category) == .off)

        cleanup.scanFilter = .safeToRemove
        let filtered = category.filtered(safeToRemove: true)
        cleanup.setSelected(true, in: filtered)
        #expect(cleanup.scannerSelection == [unrelated.id, parent.id, appCache.id])
        #expect(cleanup.selectAllState(in: filtered) == .on)
        let operation = try #require(operations.begin(.appUninstall))
        cleanup.setSelected(false, in: filtered)
        #expect(cleanup.scannerSelection == [unrelated.id, parent.id, appCache.id])
        operations.finish(operation)
    }

    @Test("Selected application caches fully select All headers without selecting the application")
    func applicationCacheSelectionState() {
        let cache = cleanupEntry("application-cache")
        var app = cleanupEntry("Application.app")
        app.kind = .appBundle
        app.isRegenerable = false
        app.children = [cache]
        let category = ScanCategoryResult(categoryID: .applications, entries: [app])
        let cleanup = CleanupModel(operations: OperationCoordinator())
        cleanup.scanResults = .init(categories: [category], startedAt: .now, finishedAt: .now)
        cleanup.seedSafeToRemoveSelection()
        #expect(cleanup.scannerSelection == [cache.id])
        #expect(cleanup.selectAllStateInCurrentView == .on)
        #expect(cleanup.selectAllState(in: category.filtered(safeToRemove: true)) == .on)
        cleanup.scanFilter = .all
        #expect(cleanup.selectAllStateInCurrentView == .on)
        #expect(cleanup.selectAllState(in: category) == .on)
        #expect(!cleanup.canSelectAllInCurrentView)
        #expect(cleanup.selectedBytes(in: .applications) == cache.allocatedBytes)
        cleanup.openCategories.insert(.applications)
        #expect(cleanup.selectAllState(in: category) == .on)
        cleanup.setSelected(false, in: category)
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.selectAllStateInCurrentView == .off)
        #expect(cleanup.selectAllState(in: category) == .off)
    }

    @Test("Removal uses the captured plan and survives caller cancellation")
    func capturedPlanAndRemovalLifetime() async throws {
        let fixture = try CleanupFixture()
        let first = try fixture.entry("first")
        var protected = try fixture.entry("protected")
        protected.protectionReason = .userData
        let later = try fixture.entry("later")
        let removal = HeldCleanupRemoval()
        let operations = OperationCoordinator()
        var preferences = CleanupModel.Preferences(keepReceipt: false)
        let cleanup = CleanupModel(
            operations: operations, remover: removal, preferences: { preferences }, measureSaving: { _ in nil }
        )
        cleanup.scanResults = cleanupResults([first, protected, later])
        cleanup.scannerSelection = [first.id, protected.id]
        cleanup.userDataRemovalOverrides = [protected.id, later.id]
        cleanup.requestCleanUp(in: .all)
        #expect(cleanup.pendingCleanUp?.protectedDataCount == 1)
        cleanup.scannerSelection = [later.id]
        cleanup.userDataRemovalOverrides = [later.id]
        preferences.keepReceipt = true
        let refresh = TestGate()
        var completed: CleanupOutcome?
        cleanup.onEvent = { event in
            if case .removed(let outcome) = event { completed = outcome }
        }
        cleanup.refreshAfterRemoval = {
            #expect(!operations.isBusy)
            #expect(!cleanup.isRemoving)
            #expect(completed?.removedCount == 1)
            await refresh.wait()
        }
        let caller = Task { await cleanup.performCleanUp() }
        try await waitUntil { await removal.isPending }
        caller.cancel()
        #expect(operations.isBusy)
        #expect(cleanup.pendingCleanUp == nil)
        #expect(await removal.entries.map(\.id) == [first.id, protected.id])
        #expect(await removal.overrides == [protected.id])
        #expect(await removal.keepReceipt == false)
        #expect(await removal.trashFirst)
        #expect(operations.isBusy)
        await removal.finish(CleanupOutcome(
            removedBytes: first.allocatedBytes, removedCount: 1,
            failed: [protected.id], trashedCount: 1
        ))
        try await waitUntil { await refresh.isPending }
        #expect(cleanup.scanResults == nil)
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.userDataRemovalOverrides.isEmpty)
        #expect(completed?.failed == [protected.id])
        await refresh.finish()
        await caller.value
    }

    @Test("Cancelling confirmation rejects its delayed size measurement")
    func cancelledAndReplacedPlan() async throws {
        let fixture = try CleanupFixture()
        let first = try fixture.entry("first")
        let second = try fixture.entry("second")
        let measurements = CleanupMeasurements()
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(
            operations: OperationCoordinator(), remover: removal,
            measureSaving: { await measurements.measure($0) }
        )
        cleanup.scanResults = cleanupResults([first, second])
        cleanup.scannerSelection = [first.id]
        cleanup.requestCleanUp(in: .all)
        try await waitUntil { await measurements.count == 1 }
        let previous = cleanup.pendingCleanUp?.id
        cleanup.cancelCleanUp()
        await cleanup.performCleanUp()
        #expect(await removal.requestCount == 0)
        cleanup.scannerSelection = [second.id]
        cleanup.requestCleanUp(in: .all)
        try await waitUntil { await measurements.count == 2 }
        #expect(cleanup.pendingCleanUp?.id != previous)
        await measurements.finish(0, bytes: 99)
        await measurements.finish(1, bytes: 42)
        try await waitUntil { cleanup.pendingCleanUp?.freed?.privateBytes == 42 }
        #expect(cleanup.pendingCleanUp?.entries.map(\.id) == [second.id])
        cleanup.cancelCleanUp()
    }

    @Test("Quit refusal removes nothing and keeps the guard until the quit request returns")
    func quitRefusal() async throws {
        let removal = HeldCleanupRemoval()
        let gate = TestGate()
        let owner = FileEntry.RunningOwner(name: "Fixture", bundleIdentifier: "test.cleanup", bundlePath: "/fixture.app")
        var item = cleanupEntry("running")
        item.inUseBy = owner
        let operations = OperationCoordinator()
        let cleanup = CleanupModel(
            operations: operations, remover: removal,
            applications: CleanupApplications(stillRunning: { $0 }, quit: { owners in
                await gate.wait()
                return owners
            }, registeredIdentifiers: { _ in [] }),
            measureSaving: { _ in nil }
        )
        var failure: String?
        cleanup.onEvent = { event in
            if case .failure(let title, _) = event { failure = title }
        }
        cleanup.scanResults = cleanupResults([item])
        cleanup.scannerSelection = [item.id]
        cleanup.requestCleanUp(in: .all)
        let caller = Task { await cleanup.performCleanUp(quittingOwners: true) }
        try await waitUntil { await gate.isPending }
        caller.cancel()
        #expect(operations.isBusy)
        await gate.finish()
        await caller.value
        #expect(await removal.requestCount == 0)
        #expect(failure == "Nothing Was Removed")
        #expect(!operations.isBusy)
        #expect(cleanup.pendingCleanUp == nil)
        #expect(cleanup.scannerSelection == [item.id])
    }

    @Test("Cancelling the app quit wait rejects delayed success and preserves the review", arguments: [false, true])
    func cancelApplicationQuit(beforeRemoval: Bool) async throws {
        let removal = HeldCleanupRemoval()
        let gate = TestGate()
        let open = FileEntry.RunningOwner(name: "Open", bundleIdentifier: "test.open", bundlePath: "/open.app")
        let closed = FileEntry.RunningOwner(name: "Closed", bundleIdentifier: "test.closed", bundlePath: "/closed.app")
        var first = cleanupEntry("open-cache")
        first.inUseBy = open
        var second = cleanupEntry("closed-cache")
        second.inUseBy = closed
        var running = [open, closed]
        var quitWasCancelled = false
        let operations = OperationCoordinator()
        let cleanup = CleanupModel(
            operations: operations, remover: removal,
            applications: CleanupApplications(stillRunning: { owners in owners.filter { running.contains($0) } }, quit: { _ in
                await gate.wait()
                quitWasCancelled = Task.isCancelled
                return []
            }, registeredIdentifiers: { _ in [] }),
            measureSaving: { _ in nil }
        )
        var failures = 0
        var finishes = 0
        var removals = 0
        cleanup.onEvent = { event in
            switch event {
            case .failure: failures += 1
            case .operationFinished: finishes += 1
            case .removalStarted: removals += 1
            default: break
            }
        }
        cleanup.scanResults = cleanupResults([first, second])
        cleanup.scannerSelection = [first.id, second.id]
        let scannedAt = cleanup.scanResults?.finishedAt
        if beforeRemoval { cleanup.requestCleanUp(in: .all) }
        let caller = Task {
            if beforeRemoval { await cleanup.performCleanUp(quittingOwners: true) }
            else { await cleanup.quitAppsForCleanup() }
        }
        try await waitUntil { await gate.isPending }
        #expect(cleanup.isWaitingForApplications)
        #expect(!cleanup.isInterruptingApplicationQuit)
        caller.cancel()
        running = [open]
        cleanup.cancelApplicationQuit()
        cleanup.cancelApplicationQuit()
        #expect(cleanup.isInterruptingApplicationQuit)
        #expect(operations.isBusy)
        cleanup.startScan()
        await cleanup.quitAppsForCleanup()
        #expect(!cleanup.isScanning)
        #expect(await gate.count == 1)
        await gate.finish()
        await caller.value
        #expect(quitWasCancelled)
        #expect(!operations.isBusy)
        #expect(!cleanup.isWaitingForApplications)
        #expect(!cleanup.isInterruptingApplicationQuit)
        #expect(!cleanup.isRemoving)
        #expect(cleanup.pendingCleanUp == nil)
        #expect(cleanup.cleanupOutcome == nil)
        #expect(cleanup.scanResults?.finishedAt == scannedAt)
        #expect(cleanup.scannerSelection == [first.id, second.id])
        #expect(cleanup.allEntries.first { $0.id == first.id }?.inUseBy == open)
        #expect(cleanup.allEntries.first { $0.id == second.id }?.inUseBy == nil)
        #expect(cleanup.cleanupRunningOwners == [open])
        #expect(await removal.requestCount == 0)
        #expect(failures == 0)
        #expect(removals == 0)
        #expect(finishes == 1)
        cleanup.cancelApplicationQuit()
        #expect(!cleanup.isInterruptingApplicationQuit)
    }

    @Test("Quit Apps completes or reports refusal without removing files", arguments: [false, true])
    func quitAppsCompletion(refuses: Bool) async throws {
        let gate = TestGate()
        let removal = HeldCleanupRemoval()
        let owner = FileEntry.RunningOwner(name: "Fixture", bundleIdentifier: "test.cleanup", bundlePath: "/fixture.app")
        let ownOwner = FileEntry.RunningOwner(name: "Moppo", bundleIdentifier: AppIdentity.bundleIdentifier,
                                             bundlePath: "/Applications/Moppo.app")
        var item = cleanupEntry("running-cache")
        item.inUseBy = owner
        var ownCache = cleanupEntry("moppo-cache")
        ownCache.inUseBy = ownOwner
        let operations = OperationCoordinator()
        let cleanup = CleanupModel(
            operations: operations, remover: removal,
            applications: CleanupApplications(stillRunning: { $0 }, quit: { owners in
                #expect(owners == [owner])
                await gate.wait()
                return refuses ? owners : []
            }, registeredIdentifiers: { _ in [] })
        )
        var failure: String?
        cleanup.onEvent = { if case .failure(let title, _) = $0 { failure = title } }
        cleanup.scanResults = cleanupResults([item, ownCache])
        cleanup.scannerSelection = [item.id]
        cleanup.refreshCleanupRunningOwners()
        #expect(cleanup.cleanupRunningOwners == [owner])
        #expect(cleanup.runningAppCaches.map(\.id) == [item.id])
        let caller = Task { await cleanup.quitAppsForCleanup() }
        try await waitUntil { await gate.isPending }
        caller.cancel()
        #expect(operations.isBusy)
        await gate.finish()
        await caller.value
        #expect(!operations.isBusy)
        #expect(!cleanup.isWaitingForApplications)
        #expect(failure == (refuses ? "Some Apps Are Still Open" : nil))
        #expect(cleanup.allEntries.first?.inUseBy == (refuses ? owner : nil))
        #expect(cleanup.allEntries.first { $0.id == ownCache.id }?.inUseBy == ownOwner)
        #expect(cleanup.allEntries.first { $0.id == ownCache.id }?.regeneratesSafely == false)
        #expect(cleanup.scannerSelection == [item.id])
        #expect(await removal.requestCount == 0)
    }

    @Test("Cleanup quit targets use application identity instead of display names")
    func cleanupQuitTargets() {
        let otherBuild = FileEntry.RunningOwner(name: "Moppo Test", bundleIdentifier: AppIdentity.bundleIdentifier,
                                               bundlePath: "/Downloads/Moppo.app")
        let currentPath = FileEntry.RunningOwner(name: "Current app", bundleIdentifier: nil,
                                                bundlePath: Bundle.main.bundlePath)
        let sameName = FileEntry.RunningOwner(name: "Moppo", bundleIdentifier: "test.another-app",
                                             bundlePath: "/Applications/Another.app")
        #expect(!ApplicationRuntime.canQuitForCleanup(otherBuild))
        #expect(!ApplicationRuntime.canQuitForCleanup(currentPath))
        #expect(ApplicationRuntime.canQuitForCleanup(sameName))
    }

    @Test("Partial cleanup retains its receipt and Put Back invalidates later results")
    func partialRemovalAndRecovery() async throws {
        let fixture = try CleanupFixture()
        let removable = try fixture.entry("removable")
        var protected = try fixture.entry("protected")
        protected.protectionReason = .userData
        let log = MoppoCore.RemovalLog(directory: fixture.root.appendingPathComponent("logs"))
        let suite = "CleanupRecoveryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        settings.confirmBeforeCleanup = true
        let app = AppModel(
            settings: settings, launchAccess: .limited, hasFullDiskAccess: { false },
            trashService: TrashService(log: log),
            cleanupHistoryService: CleanupHistoryService(log: log),
            cleanupService: CleanupService(log: log)
        )
        app.cleanup.scanResults = cleanupResults([removable, protected])
        app.cleanup.scannerSelection = [removable.id, protected.id]
        app.cleanup.requestCleanUp(in: .all)
        #expect(app.activeSheet == .cleanUp)
        await app.cleanup.performCleanUp()
        #expect(app.activity == nil)
        #expect(!app.isBusyWithDisk)
        #expect(app.cleanupCompletion == nil)
        #expect(app.notice?.title == "Some Items Could Not Be Removed")
        #expect(app.cleanup.cleanupOutcome?.removedCount == 1)
        #expect(app.cleanup.scanResults == nil)
        #expect(FileManager.default.fileExists(atPath: protected.url.path))
        let receipt = try #require(log.recentEntries(limit: 10).first { $0.disposition == .trashed })
        let trashed = URL(fileURLWithPath: try #require(receipt.trashedPath))
        defer { try? FileManager.default.removeItem(at: trashed) }
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(receipt.originalPath == removable.id)
        app.cleanup.scanResults = cleanupResults([protected])
        app.cleanup.scannerSelection = [protected.id]
        app.cleanup.userDataRemovalOverrides = [protected.id]
        app.cleanup.requestCleanUp(in: .all)
        await app.recovery.putBack(TrashItem(url: trashed, bytes: receipt.bytes, canPutBack: true))
        #expect(FileManager.default.fileExists(atPath: removable.id))
        #expect(app.cleanup.scanResults == nil)
        #expect(app.cleanup.scannerSelection.isEmpty)
        #expect(app.cleanup.pendingCleanUp == nil)
        #expect(app.cleanup.userDataRemovalOverrides.isEmpty)
        #expect(app.recovery.cleanupHistory?.items.first { $0.originalURL.path == removable.id }?.state == .restored)
    }

    @Test("The scan service preserves exclusions, category settings, and leftover candidates", arguments: [false, true])
    func scanContext(leftoversEnabled: Bool) async throws {
        let fixture = try CleanupFixture()
        let evidence = fixture.root.appendingPathComponent("Library/Saved Application State/com.moppo.cleanupfixture.savedState")
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let recorder = CleanupContextRecorder(id: .systemCaches)
        let disabled = CleanupContextRecorder(id: .documentsAndFiles)
        let planner = AppUninstallPlanner(
            home: fixture.root, systemLibrary: fixture.root.appendingPathComponent("SystemLibrary"),
            applicationRoots: [fixture.root.appendingPathComponent("Applications")],
            darwinCache: nil, darwinTemp: nil
        )
        let service = CleanupScanService(
            coordinator: ScanCoordinator(scanners: [recorder, disabled]),
            leftoverPlanner: OrphanedAppLeftoverPlanner(pathPlanner: planner)
        )
        let preferences = CleanupModel.Preferences(
            enabledCategories: leftoversEnabled ? [.systemCaches, .applicationLeftovers] : [.systemCaches],
            excludedPaths: ["/excluded"], excludedPatterns: ["*.keep"]
        )
        let result = try await service.scan(preferences: preferences, onProgress: { _ in })
        let context = try #require(await recorder.context)
        #expect(context.excludedPaths == ["/excluded"])
        #expect(context.excludedPatterns == ["*.keep"])
        #expect(context.measurer.protectedPatterns == ["*.keep"])
        #expect(!context.measurer.followSymlinks)
        #expect(await disabled.context == nil)
        #expect(result.categories.map(\.categoryID) == [.systemCaches])
        if leftoversEnabled {
            #expect(context.applicationLeftoverCandidates?.identifiers == ["com.moppo.cleanupfixture"])
        } else {
            #expect(context.applicationLeftoverCandidates == nil)
        }
    }

    @Test("Cleanup confirmation follows the setting for sounds and open applications", arguments: [true, false], [true, false])
    func confirmationSetting(confirm: Bool, sounds: Bool) async throws {
        var item = sounds ? soundLibraryItem().fileEntry : cleanupEntry("running")
        if !sounds {
            item.inUseBy = FileEntry.RunningOwner(name: "Fixture", bundleIdentifier: "test.cleanup", bundlePath: "/fixture.app")
        }
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(
            operations: OperationCoordinator(), remover: removal,
            preferences: { CleanupModel.Preferences(confirmBeforeCleanup: confirm) },
            applications: CleanupApplications(stillRunning: { $0 }),
            measureSaving: { _ in nil }
        )
        cleanup.scanResults = ScanResults(categories: [ScanCategoryResult(
            categoryID: sounds ? .applications : .systemCaches, totalBytes: item.allocatedBytes, entries: [item]
        )], startedAt: .now, finishedAt: .now)
        cleanup.scannerSelection = [item.id]
        var confirmed = false
        cleanup.onEvent = { if case .confirmationRequested = $0 { confirmed = true } }
        cleanup.requestCleanUp(in: .all)
        #expect(confirmed == confirm)
        if confirm {
            #expect(cleanup.pendingCleanUp?.includesSoundLibrary == sounds)
            #expect(!cleanup.isRemoving)
            #expect(await removal.requestCount == 0)
            cleanup.cancelCleanUp()
        } else {
            #expect(cleanup.pendingCleanUp == nil)
            try await waitUntil { await removal.isPending }
            #expect(await removal.entries == [item])
            await removal.finish(CleanupOutcome(failed: [item.id]))
            try await waitUntil { !cleanup.isRemoving }
        }
    }

    @Test("Docker removal follows the confirmation setting and updates storage", arguments: RemovalConfirmationChoice.allCases)
    func dockerImages(choice: RemovalConfirmationChoice) async throws {
        let metadata = DockerImage(
            imageID: "sha256:" + String(repeating: "a", count: 64), context: "fixture",
            tags: ["fixture:latest", "fixture:stable"], containerCount: 0
        )
        let image = FileEntry(
            url: URL(string: "docker://images/fixture/\(metadata.imageID)")!,
            displayName: "fixture:latest, fixture:stable", kind: .diskImage, allocatedBytes: 200, dockerImage: metadata
        )
        let fixture = try CleanupFixture()
        var file = try fixture.entry("file")
        file.allocatedBytes = 100
        let untouched = try fixture.entry("untouched")
        let removal = HeldCleanupRemoval()
        let operations = OperationCoordinator()
        var refreshCount = 0
        let cleanup = CleanupModel(
            operations: operations, remover: removal,
            preferences: { CleanupModel.Preferences(confirmBeforeCleanup: choice.isEnabled) },
            scanDocker: { _ in
                #expect(operations.isBusy)
                refreshCount += 1
                return .empty(.docker)
            },
            measureSaving: { urls in
                Issue.record("A mixed Docker plan must not report filesystem savings: \(urls)")
                return nil
            }
        )
        cleanup.scanFilter = .all
        cleanup.scanResults = ScanResults(categories: [
            ScanCategoryResult(categoryID: .docker, totalBytes: 200, entries: [image]),
            ScanCategoryResult(categoryID: .systemCaches, totalBytes: 200, entries: [file, untouched])
        ], startedAt: .now, finishedAt: .now)
        cleanup.scannerSelection = [image.id, file.id]
        var confirmed = false
        cleanup.onEvent = { if case .confirmationRequested = $0 { confirmed = true } }
        cleanup.requestCleanUp(in: .all)
        #expect(confirmed == choice.isEnabled)
        if choice.isEnabled {
            let plan = try #require(cleanup.pendingCleanUp)
            #expect(plan.dockerImageCount == 1)
            #expect(plan.dockerImageBytes == 200)
            #expect(plan.itemCount == 2)
            #expect(plan.totalBytes == 300)
            #expect(plan.freed == nil)
            if choice == .cancel {
                cleanup.cancelCleanUp()
                #expect(await removal.requestCount == 0)
                #expect(refreshCount == 0)
                #expect(cleanup.scannerSelection == [image.id, file.id])
                return
            }
            Task { await cleanup.performCleanUp() }
        }
        try await waitUntil { await removal.isPending }
        #expect(await removal.entries.map(\.id) == [image.id, file.id])
        await removal.finish(CleanupOutcome(removedBytes: 300, removedCount: 2, trashedCount: 1, deletedCount: 1))
        try await waitUntil { !cleanup.isRemoving }
        #expect(refreshCount == 1)
        #expect(cleanup.scanResults?.categories.first?.entries.isEmpty == true)
        #expect(cleanup.scanResults?.categories.first?.totalBytes == 0)
        #expect(cleanup.scanResults?.categories.last?.entries == [untouched])
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.scanFilter == .all)
    }

    @Test("A failed Docker removal updates dependencies and clears a locked selection")
    func dockerDependencyFailure() async throws {
        let imageID = "sha256:" + String(repeating: "b", count: 64)
        let image = FileEntry(
            url: URL(string: "docker://images/fixture/\(imageID)")!,
            displayName: "fixture:latest", kind: .diskImage, allocatedBytes: 200,
            dockerImage: DockerImage(imageID: imageID, context: "fixture", tags: ["fixture:latest"], containerCount: 0)
        )
        var used = image
        used.dockerImage = DockerImage(imageID: imageID, context: "fixture", tags: ["fixture:latest"], containerCount: 1)
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(
            operations: OperationCoordinator(), remover: removal,
            preferences: { CleanupModel.Preferences(confirmBeforeCleanup: false) },
            scanDocker: { _ in ScanCategoryResult(categoryID: .docker, totalBytes: 200, entries: [used]) }
        )
        cleanup.scanResults = ScanResults(categories: [
            ScanCategoryResult(categoryID: .docker, totalBytes: 200, entries: [image])
        ], startedAt: .now, finishedAt: .now)
        cleanup.scannerSelection = [image.id]
        cleanup.requestCleanUp(in: .all)
        try await waitUntil { await removal.isPending }
        await removal.finish(CleanupOutcome(failed: [image.id]))
        try await waitUntil { !cleanup.isRemoving }
        #expect(cleanup.scanResults?.categories.first?.entries == [used])
        #expect(cleanup.scanResults?.totalBytes == 200)
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.cleanupOutcome?.failed == [image.id])
    }

    @Test("Cleanup without confirmation captures the selection before its task starts")
    func immediateRemoval() async throws {
        let fixture = try CleanupFixture()
        let first = try fixture.entry("first")
        let later = try fixture.entry("later")
        let removal = HeldCleanupRemoval()
        let cleanup = CleanupModel(
            operations: OperationCoordinator(), remover: removal,
            preferences: { CleanupModel.Preferences(confirmBeforeCleanup: false) }
        )
        cleanup.scanResults = cleanupResults([first, later])
        cleanup.scannerSelection = [first.id]
        cleanup.requestCleanUp(in: .all)
        #expect(cleanup.isRemoving)
        #expect(cleanup.pendingCleanUp == nil)
        cleanup.scannerSelection = [later.id]
        cleanup.requestCleanUp(in: .all)
        try await waitUntil { await removal.isPending }
        #expect(await removal.entries.map(\.id) == [first.id])
        #expect(await removal.requestCount == 1)
        await removal.finish(CleanupOutcome(failed: [first.id]))
        try await waitUntil { !cleanup.isRemoving }
        #expect(cleanup.cleanupOutcome?.failed == [first.id])
        #expect(cleanup.scanResults != nil)
    }
}

private func cleanupEntry(_ name: String) -> FileEntry {
    FileEntry(url: URL(fileURLWithPath: "/cleanup-fixture/\(name)"), kind: .file, allocatedBytes: 100, isRegenerable: true)
}

private func safeWorktreeReview() -> GitWorktreeReview {
    var review = GitWorktreeReview()
    review.status = .clean
    review.pushStatus = .noUnpushedCommits
    review.filesChecked = true
    review.locks = .clear
    review.activity = .clear
    return review
}

private func cleanupResults(_ entries: [FileEntry]) -> ScanResults {
    ScanResults(categories: [ScanCategoryResult(
        categoryID: .systemCaches, totalBytes: entries.reduce(0) { $0 + $1.allocatedBytes }, entries: entries
    )], startedAt: .now, finishedAt: .now)
}


private actor HeldCleanupRemoval: CleanupRemoving {
    private(set) var requestCount = 0
    private(set) var entries: [FileEntry] = []
    private(set) var overrides: Set<FileEntry.ID> = []
    private(set) var keepReceipt = true
    private(set) var trashFirst = false
    private var continuation: CheckedContinuation<CleanupOutcome, Never>?
    var isPending: Bool { continuation != nil }
    func remove(
        entries: [FileEntry], trashFirst: Bool, keepReceipt: Bool,
        userDataRemovalOverrides: Set<FileEntry.ID>, appDataRemovalOverrides: Set<FileEntry.ID>,
        expectedIdentities: [FileEntry.ID: String]
    ) async throws -> CleanupOutcome {
        requestCount += 1
        self.entries = entries
        self.overrides = userDataRemovalOverrides
        self.keepReceipt = keepReceipt
        self.trashFirst = trashFirst
        return await withCheckedContinuation { continuation = $0 }
    }
    func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan, bundleIdentifiers: Set<String>, itemPaths: Set<String>?,
        registeredApplicationBundleIdentifiers: Set<String>, keepReceipt: Bool
    ) async throws -> CleanupOutcome {
        CleanupOutcome(failed: plan.items(for: bundleIdentifiers, itemPaths: itemPaths).map(\.id))
    }
    func finish(_ result: CleanupOutcome) { continuation?.resume(returning: result); continuation = nil }
}

private actor CleanupMeasurements {
    private var continuations: [Int: CheckedContinuation<PrivateSizeMeasurement?, Never>] = [:]
    private(set) var count = 0
    func measure(_ urls: [URL]) async -> PrivateSizeMeasurement? {
        let index = count
        count += 1
        return await withCheckedContinuation { continuations[index] = $0 }
    }
    func finish(_ index: Int, bytes: Int64) {
        continuations.removeValue(forKey: index)?.resume(returning: PrivateSizeMeasurement(privateBytes: bytes))
    }
}

private final class CleanupFixture {
    private let folder: TemporaryFolder
    var root: URL { folder.url }
    init() throws { folder = try TemporaryFolder(prefix: "moppo-cleanup") }
    func entry(_ name: String) throws -> FileEntry {
        let url = try folder.write("\(name)-\(root.lastPathComponent).txt", contents: "Disposable Cleanup fixture")
        return FileEntry(url: url, kind: .file, allocatedBytes: 4096, isRegenerable: true)
    }
}

private actor CleanupContextRecorder: CategoryScanner {
    nonisolated let id: CategoryID
    private(set) var context: ScanContext?
    init(id: CategoryID) { self.id = id }
    func scan(context: ScanContext) async throws -> ScanCategoryResult {
        self.context = context
        return ScanCategoryResult(categoryID: id, totalBytes: 0, entries: [])
    }
}
