import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MoppoCore

@Suite("File duplicate feature ownership")
@MainActor
struct FileDuplicatesModelTests {
    @Test("Review navigation preserves row order and skips hidden copies")
    func reviewNavigation() throws {
        let small = try #require(fileResults("small").groups.first)
        let large = try #require(fileResults("large").groups.first)
        var review = FileDuplicateReviewState()
        review.reset(groups: [small, large])
        let originalOrder = review.files(in: small).map(\.id)
        review.moveHighlight(1, groups: [small, large])
        #expect(review.highlightedID == small.keeper.id)
        review.moveHighlight(1, groups: [small, large])
        let highlighted = try #require(review.highlightedID)
        let promoted = try #require(small.promoting(highlighted))
        review.update(groups: [promoted, large])
        #expect(review.files(in: promoted).map(\.id) == originalOrder)
        #expect(review.highlightedID == highlighted)

        review.toggleGroup(promoted)
        #expect(review.highlightedID == nil)
        #expect(review.visibleFiles(in: [promoted, large]).map(\.id) == large.files.map(\.id))
        review.moveHighlight(1, groups: [promoted, large])
        #expect(review.highlightedID == large.keeper.id)
        review.moveHighlight(-1, groups: [promoted, large])
        #expect(review.highlightedID == large.keeper.id)
        review.update(groups: [promoted])
        #expect(review.highlightedID == nil)
        review.reset(groups: [promoted])
        #expect(review.collapsedGroups.isEmpty)
        #expect(review.files(in: promoted).map(\.id) == promoted.files.map(\.id))
    }

    @Test("Matching filenames show distinct folder locations")
    func matchingFilenameLocations() throws {
        let keeper = DuplicateFile(url: URL(filePath: "/fixture/Project/out/movie.mov"), logicalBytes: 10, allocatedBytes: 10)
        let copy = DuplicateFile(url: URL(filePath: "/fixture/Export/movie.mov"), logicalBytes: 10, allocatedBytes: 10)
        let group = FileDuplicateGroup(id: "locations", keeper: keeper, removable: [copy], contentDigest: "test")
        #expect(group.sharedFilename == "movie.mov")
        #expect(group.locationLabel(for: keeper) == "Project/out")
        #expect(group.locationLabel(for: copy) == "Export")
        #expect(group.headerDetail == "2 identical files · keeping the oldest")
        let promoted = try #require(group.promoting(copy.id))
        #expect(promoted.headerDetail == "2 identical files · keeping your choice")
        let renamed = DuplicateFile(url: URL(filePath: "/fixture/Export/renamed.mov"), logicalBytes: 10, allocatedBytes: 10)
        let differentNames = FileDuplicateGroup(id: "names", keeper: keeper, removable: [renamed], contentDigest: "test")
        #expect(differentNames.sharedFilename == nil)
        #expect(differentNames.headerDetail == ".mov · keeping the oldest")
    }

    @Test("A stopped scan holds the guard and rejects late progress and results")
    func cancellationAndNavigation() async throws {
        let service = HeldFileScanner()
        let app = AppModel(fileDuplicateService: service)
        let files = app.fileDuplicates
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { await service.pendingCount == 1 }
        #expect(app.view == .duplicates)
        #expect(app.duplicateKind == .files)
        app.view = .history
        #expect(app.isBusyWithDisk)
        #expect(app.storageExplorer.isMeasurementBlocked)
        app.cleanup.startScan()
        #expect(!app.cleanup.isScanning)
        #expect(app.isBusyWithDisk)

        files.cancelScan()
        #expect(files.isInterrupting)
        files.startScan(roots: [URL(fileURLWithPath: "/blocked-fixture")])
        #expect(await service.requestCount == 1)
        #expect(app.isBusyWithDisk)
        await service.report(0, completed: 90)
        await service.finish(0, results: fileResults("cancelled"))
        try await waitUntil { !files.isScanning }
        #expect(files.results == nil)
        #expect(files.progress == nil)
        #expect(!files.isInterrupting)
        #expect(!app.isBusyWithDisk)
        #expect(app.view == .history)

        files.startScan(roots: [URL(fileURLWithPath: "/current-fixture")])
        try await waitUntil { await service.pendingCount == 1 }
        app.view = .dashboard
        await service.report(1, completed: 32)
        try await waitUntil { files.progress?.completed == 32 }
        await service.report(1, completed: 12)
        await service.report(0, completed: 99)
        await service.finish(1, results: fileResults("current"))
        try await waitUntil { !files.isScanning }
        #expect(files.groups.first?.id == "current")
        #expect(files.progress?.completed == 32)
        #expect(files.selection.isEmpty)
        #expect(app.view == .dashboard)
        #expect(!app.isBusyWithDisk)
    }

    @Test("Another operation blocks file scans and removal")
    func otherOperationsBlockFiles() async throws {
        let scanner = HeldFileScanner(results: fileResults("initial"))
        let removal = HeldFileRemoval()
        let app = AppModel(fileDuplicateService: scanner, fileDuplicateRemovalService: removal)
        let files = app.fileDuplicates
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        _ = app.operations.begin(.photoScan)
        files.startScan()
        await files.removeSelected()
        #expect(!files.isScanning)
        #expect(!files.isRemoving)
        #expect(await scanner.requestCount == 1)
        #expect(await removal.requestCount == 0)
        #expect(!files.selection.isEmpty)
    }

    @Test("Filters and keeper changes cannot select a keeper or a hidden file")
    func selectionOwnership() async throws {
        var results = fileResults("small", bytes: 10)
        results.groups += fileResults("large", bytes: 100).groups
        let scanner = HeldFileScanner(results: results)
        let files = FileDuplicatesModel(operations: OperationCoordinator(), service: scanner)
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.toggle("/small/keeper")
        files.toggle("/unknown")
        #expect(files.selection.isEmpty)
        files.toggleGroup("small")
        #expect(files.isGroupSelected("small"))
        files.keepInstead(groupID: "small", fileID: "/small/copy-1")
        #expect(files.groups.first?.keeper.id == "/small/copy-1")
        #expect(files.selection == ["/small/keeper", "/small/copy-2"])
        #expect(files.selectionBytes == 20)
        files.selectAll()
        files.minimumBytes = 50
        #expect(files.groups.map(\.id) == ["large"])
        #expect(files.selection == ["/large/copy-1", "/large/copy-2"])
        files.toggleGroup("small")
        files.toggle("/small/keeper")
        files.keepInstead(groupID: "small", fileID: "/small/copy-2")
        files.minimumBytes = 0
        #expect(!files.selection.contains("/small/keeper"))
        #expect(files.groups.first?.keeper.id == "/small/copy-1")
        #expect(await scanner.requestCount == 1)
        files.deselectAll()
        #expect(files.selection.isEmpty)
    }

    @Test("File removal follows confirmation settings and retains its operation", arguments: RemovalConfirmationChoice.allCases)
    func removalLifetime(_ choice: RemovalConfirmationChoice) async throws {
        let fixture = try RemovalSettingsFixture(confirm: choice.isEnabled)
        let scanner = HeldFileScanner(results: fileResults("initial"))
        let removal = HeldFileRemoval()
        let app = AppModel(settings: fixture.settings, fileDuplicateService: scanner, fileDuplicateRemovalService: removal)
        let files = app.fileDuplicates
        let refresh = TestGate()
        files.refreshAfterRemoval = {
            #expect(!app.isBusyWithDisk)
            #expect(app.activity == nil)
            #expect(app.removalCompletion?.title == "Some items were not removed")
            await refresh.wait()
        }
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        let reviewedSelection = files.selection
        let task = Task { await files.removeSelected() }
        if choice.isEnabled {
            try await waitUntil { app.pendingRemovalConfirmation != nil }
            #expect(app.activeSheet == .removal)
            #expect(app.pendingRemovalConfirmation == .trash(itemCount: 2, totalBytes: files.selectionBytes))
            #expect(await removal.requestCount == 0)
            app.finishRemovalConfirmation(choice == .confirm)
            if choice == .cancel {
                await task.value
                #expect(files.selection == reviewedSelection)
                #expect(!files.isBusyWithDisk)
                #expect(!files.isRemoving)
                #expect(app.pendingRemovalConfirmation == nil)
                #expect(app.activeSheet == nil)
                #expect(app.removalCompletion == nil)
                return
            }
        }
        try await waitUntil { await removal.isPending }
        #expect(app.pendingRemovalConfirmation == nil)
        #expect(files.isRemoving)
        #expect(app.isRemovingDuplicateFiles)
        #expect(app.storageExplorer.isMeasurementBlocked)
        #expect(app.removalCompletion == nil)
        let selected = files.selection
        files.keepInstead(groupID: "initial", fileID: "/initial/copy-1")
        files.deselectAll()
        files.toggleGroup("initial")
        #expect(files.selection == selected)
        #expect(files.groups.first?.keeper.id == "/initial/keeper")
        await files.removeSelected()
        files.startScan()
        #expect(await removal.requestCount == 1)
        #expect(await scanner.requestCount == 1)
        task.cancel()
        await removal.finish(FileDuplicateRemovalOutcome(cleanup: CleanupOutcome(
            removedBytes: 10, removedCount: 1,
            failed: ["/initial/copy-2"], permissionDenied: ["/initial/copy-2"], trashedCount: 1
        )))
        try await waitUntil { await refresh.isPending }
        #expect(!files.isRemoving)
        #expect(files.selection == ["/initial/copy-2"])
        #expect(files.groups.first?.removable.map(\.id) == ["/initial/copy-2"])
        #expect(app.removalCompletion?.destination == .duplicates)
        #expect(app.removalCompletion?.isSuccess == false)
        #expect(app.removalCompletion?.finderURLs == [URL(fileURLWithPath: "/initial/copy-2")])
        #expect(app.removalCompletion?.detail.contains("macOS denied access") == true)

        // A finished refresh cannot clear the operation started after removal.
        await scanner.hold()
        files.startScan()
        try await waitUntil { await scanner.pendingCount == 1 }
        await refresh.finish()
        await task.value
        #expect(files.isScanning)
        #expect(app.isBusyWithDisk)
        await scanner.finish(1, results: fileResults("later"))
        try await waitUntil { !files.isScanning }
        #expect(files.groups.first?.id == "later")
        #expect(!app.isBusyWithDisk)
    }

    @Test("Changed groups and files leave the results and selection")
    func staleRemoval() async throws {
        var results = fileResults("changed-group")
        results.groups += fileResults("changed-copy").groups
        let removal = HeldFileRemoval()
        let files = FileDuplicatesModel(
            operations: OperationCoordinator(), service: HeldFileScanner(results: results), removalService: removal
        )
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        let task = Task { await files.removeSelected() }
        try await waitUntil { await removal.isPending }
        await removal.finish(FileDuplicateRemovalOutcome(
            cleanup: CleanupOutcome(failed: Array(files.selection)),
            staleFileIDs: ["/changed-copy/copy-1"], staleGroupIDs: ["changed-group"]
        ))
        await task.value
        #expect(files.groups.map(\.id) == ["changed-copy"])
        #expect(files.selection == ["/changed-copy/copy-2"])
        #expect(!files.isBusyWithDisk)
    }

    @Test("Failed scans and removals release the guard and permit retry")
    func serviceFailures() async throws {
        let scanner = HeldFileScanner(results: fileResults("initial"))
        let removal = HeldFileRemoval()
        let app = AppModel(fileDuplicateService: scanner, fileDuplicateRemovalService: removal)
        let files = app.fileDuplicates
        files.refreshAfterRemoval = {}
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        let selected = files.selection
        let task = Task { await files.removeSelected() }
        try await waitUntil { await removal.isPending }
        await removal.fail()
        await task.value
        #expect(files.selection == selected)
        #expect(app.notice?.title == "The Duplicates Could Not Be Moved")
        #expect(app.activity == nil)
        #expect(!app.isBusyWithDisk)

        await scanner.hold()
        files.startScan()
        try await waitUntil { await scanner.pendingCount == 1 }
        await scanner.fail(1)
        try await waitUntil { !files.isScanning }
        #expect(app.notice?.title == "The Duplicate Scan Did Not Finish")
        #expect(files.groups.first?.id == "initial")
        #expect(files.selection.isEmpty)
        #expect(!app.isBusyWithDisk)
        files.startScan()
        try await waitUntil { await scanner.pendingCount == 1 }
        await scanner.finish(2, results: fileResults("retry"))
        try await waitUntil { !files.isScanning }
        #expect(files.groups.first?.id == "retry")
    }

    @Test("Invalidation rejects an unfinished scan without releasing its guard early")
    func invalidateDuringScan() async throws {
        let scanner = HeldFileScanner()
        let files = FileDuplicatesModel(operations: OperationCoordinator(), service: scanner)
        files.minimumBytes = 0
        files.startScan(roots: [URL(fileURLWithPath: "/file-fixture")])
        try await waitUntil { await scanner.pendingCount == 1 }
        files.invalidateResults()
        #expect(files.isBusyWithDisk)
        #expect(files.isInterrupting)
        await scanner.finish(0, results: fileResults("obsolete"))
        try await waitUntil { !files.isScanning }
        #expect(files.results == nil)
        #expect(files.selection.isEmpty)
        #expect(!files.isBusyWithDisk)
    }

    @Test("Each operation reads current exclusions and receipt preferences")
    func preferences() async throws {
        let scanner = HeldFileScanner(results: fileResults("initial"))
        let removal = HeldFileRemoval()
        var preferences = FileDuplicatesModel.Preferences(excludedPaths: ["/excluded"], excludedPatterns: ["*.tmp"])
        let files = FileDuplicatesModel(
            operations: OperationCoordinator(), service: scanner, removalService: removal, preferences: { preferences }
        )
        files.minimumBytes = 0
        let roots = [URL(fileURLWithPath: "/file-fixture")]
        files.startScan(roots: roots)
        preferences.excludedPaths = ["/later"]
        try await waitUntil { !files.isScanning }
        let first = try #require(await scanner.requests.first)
        #expect(first.roots == roots)
        #expect(first.options.minimumLogicalBytes == 0)
        #expect(first.excludedPaths == ["/excluded"])
        #expect(first.excludedPatterns == ["*.tmp"])
        files.startScan()
        try await waitUntil { !files.isScanning }
        #expect(await scanner.requests.last?.excludedPaths == ["/later"])
        preferences.keepReceipt = false
        files.selectAll()
        let task = Task { await files.removeSelected() }
        try await waitUntil { await removal.isPending }
        #expect(await removal.keepsReceipt == false)
        await removal.finish(FileDuplicateRemovalOutcome(cleanup: CleanupOutcome(failed: Array(files.selection))))
        await task.value
    }

    @Test("Partial removal preserves receipts and Put Back clears the file review")
    func partialRemovalAndRecovery() async throws {
        let fixture = try FileRemovalFixture()
        let log = MoppoCore.RemovalLog(directory: fixture.root.appendingPathComponent("logs"))
        defer { fixture.removeTrashedFixtures(log) }
        let app = AppModel(
            launchAccess: .limited, hasFullDiskAccess: { false },
            trashService: TrashService(home: fixture.root, log: log),
            cleanupHistoryService: CleanupHistoryService(log: log),
            fileDuplicateRemovalService: FileDuplicateRemovalService(cleanup: CleanupService(log: log))
        )
        let files = app.fileDuplicates
        files.minimumBytes = 0
        files.startScan(roots: [fixture.root])
        try await waitUntil { !files.isScanning }
        let group = try #require(files.groups.first)
        let changed = try #require(group.removable.first)
        try Data("Changed after the scan".utf8).write(to: changed.url)
        files.selectAll()
        app.cleanup.scanResults = ScanResults(categories: [], startedAt: .now, finishedAt: .now)
        app.storageExplorer.selectLocation(fixture.root)
        try await waitUntil { !app.storageExplorer.isLoading }
        await files.removeSelected()
        #expect(FileManager.default.fileExists(atPath: group.keeper.url.path))
        #expect(FileManager.default.fileExists(atPath: changed.url.path))
        #expect(files.groups.isEmpty)
        #expect(files.selection.isEmpty)
        #expect(app.removalCompletion?.title == "Some items were not removed")
        #expect(app.cleanup.scanResults == nil)
        #expect(app.storageExplorer.snapshot == nil)
        #expect(app.storageExplorer.needsRefresh)
        #expect(!app.isBusyWithDisk)
        let receipts = log.recentEntries(limit: 10).filter { $0.disposition == .trashed }
        #expect(receipts.count == 1)
        let receipt = try #require(receipts.first)
        let trashed = URL(fileURLWithPath: try #require(receipt.trashedPath))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        await app.recovery.loadCleanupHistory()
        #expect(app.recovery.cleanupHistory?.items.first?.state == .availableInTrash)

        // A later review must be discarded when a removed file returns.
        _ = try fixture.writeCopy("later")
        files.startScan(roots: [fixture.root])
        try await waitUntil { !files.isScanning }
        files.selectAll()
        #expect(!files.selection.isEmpty)
        await app.recovery.putBack(TrashItem(url: trashed, bytes: receipt.bytes, canPutBack: true))
        #expect(FileManager.default.fileExists(atPath: receipt.originalPath))
        #expect(files.results == nil)
        #expect(files.selection.isEmpty)
        #expect(app.recovery.cleanupHistory?.items.first?.state == .restored)
    }
}

@Suite("File duplicate row controls", .serialized)
@MainActor
struct FileDuplicateRowTests {
    @Test("Row clicks select once and leave preview and controls separate", arguments: [false, true])
    func rowInteraction(dark: Bool) async throws {
        let operations = OperationCoordinator()
        let model = FileDuplicatesModel(operations: operations, service: HeldFileScanner(results: fileResults("row", modificationDate: Date(timeIntervalSince1970: 1_700_000_000))))
        model.minimumBytes = 0
        model.startScan(roots: [URL(filePath: "/row")])
        try await waitUntil { !model.isScanning }
        let group = try #require(model.groups.first)
        let copy = try #require(group.removable.first)
        var highlights = 0
        var previews = 0
        var reveals = 0
        let row = FileDuplicateRow(model: model, file: copy, group: group, isHighlighted: false,
            onHighlight: { highlights += 1 }, onPreview: { previews += 1 }, onReveal: { reveals += 1 })
        let host = NSHostingView(rootView: row.background(Token.Fill.cardContent).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 48),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()

        // Check the name, path, date, margins, and spaces between controls.
        for point in [NSPoint(x: 80, y: 34), NSPoint(x: 80, y: 14), NSPoint(x: 700, y: 24),
                      NSPoint(x: 2, y: 24), NSPoint(x: 38, y: 24), NSPoint(x: 22, y: 3)] {
            let target = try #require(host.hitTest(point) as? PreviewClickTarget.ClickView)
            let event = try mouseEvent(in: target, window: window, clickCount: 1)
            let wasSelected = model.selection.contains(copy.id)
            target.mouseDown(with: event)
            #expect(model.selection.contains(copy.id) != wasSelected)
        }
        #expect(highlights == 6)
        #expect(previews == 0)

        let target = try #require(host.hitTest(NSPoint(x: 80, y: 24)) as? PreviewClickTarget.ClickView)
        target.mouseDown(with: try mouseEvent(in: target, window: window, clickCount: 1))
        #expect(model.selection == [copy.id])
        target.mouseDown(with: try mouseEvent(in: target, window: window, clickCount: 2))
        #expect(model.selection == [copy.id])
        #expect(highlights == 7)
        #expect(previews == 1)

        let checkbox = try #require(nativeButtons(in: host).first)
        #expect(checkbox.isEnabled)
        let center = host.convert(NSPoint(x: checkbox.bounds.midX, y: checkbox.bounds.midY), from: checkbox)
        #expect(host.hitTest(center) === checkbox)
        checkbox.performClick(nil)
        #expect(model.selection.isEmpty)
        #expect(highlights == 7)
        checkbox.performClick(nil)
        #expect(model.selection == [copy.id])

        // The nested action buttons must not hit the row click target.
        for x: CGFloat in [600, 756] {
            #expect(!(host.hitTest(NSPoint(x: x, y: 24)) is PreviewClickTarget.ClickView))
        }

        let operation = try #require(operations.begin(.cleanupScan))
        try await Task.sleep(for: .milliseconds(100))
        #expect(!checkbox.isEnabled)
        target.mouseDown(with: try mouseEvent(in: target, window: window, clickCount: 1))
        #expect(model.selection == [copy.id])
        #expect(highlights == 8)
        operations.finish(operation)
        target.mouseDown(with: try mouseEvent(in: target, window: window, clickCount: 1))
        #expect(model.selection.isEmpty)

        host.rootView = FileDuplicateRow(model: model, file: group.keeper, group: group, isHighlighted: true,
            onHighlight: { highlights += 1 }, onPreview: { previews += 1 }, onReveal: { reveals += 1 })
            .background(Token.Fill.cardContent).environment(\.colorScheme, dark ? .dark : .light)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let keeperTarget = try #require(host.hitTest(NSPoint(x: 80, y: 24)) as? PreviewClickTarget.ClickView)
        keeperTarget.mouseDown(with: try mouseEvent(in: keeperTarget, window: window, clickCount: 1))
        #expect(model.selection.isEmpty)
        #expect(highlights == 10)

        host.rootView = row.background(Token.Fill.cardContent).environment(\.colorScheme, dark ? .dark : .light)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(filePath: "/tmp/moppo-139-row-\(dark ? "dark" : "light").png"))
        window.makeKeyAndOrderFront(nil)
        for x: CGFloat in [756, 600] {
            let location = host.convert(NSPoint(x: x, y: 24), to: nil)
            let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
            let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            window.sendEvent(down)
            window.sendEvent(up)
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.selection.isEmpty)
            #expect(highlights == 10)
        }
        #expect(reveals == 1)
        #expect(model.groups.first?.keeper.id == copy.id)

    }

    private func mouseEvent(in view: NSView, window: NSWindow, clickCount: Int) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
    }
}

private func fileResults(_ id: String, bytes: Int64 = 10, modificationDate: Date? = nil) -> FileDuplicateResults {
    let file: (String) -> DuplicateFile = { name in
        DuplicateFile(url: URL(fileURLWithPath: "/\(id)/\(name)"), logicalBytes: bytes, allocatedBytes: bytes, modificationDate: modificationDate)
    }
    return FileDuplicateResults(groups: [FileDuplicateGroup(
        id: id, keeper: file("keeper"), removable: [file("copy-1"), file("copy-2")], contentDigest: "fixture"
    )], roots: [URL(fileURLWithPath: "/\(id)")])
}

private actor HeldFileScanner: FileDuplicatesScanning {
    struct Request: Sendable {
        let roots: [URL]
        let options: FileDuplicateService.Options
        let excludedPaths: [String]
        let excludedPatterns: [String]
    }
    private var results: FileDuplicateResults?
    private var scans: [Int: CheckedContinuation<FileDuplicateResults, any Error>] = [:]
    private var reports: [Int: @Sendable (FileDuplicateService.Progress) -> Void] = [:]
    private(set) var requests: [Request] = []
    var requestCount: Int { requests.count }
    var pendingCount: Int { scans.count }
    init(results: FileDuplicateResults? = nil) { self.results = results }
    func hold() { results = nil }

    func scan(
        roots: [URL], options: FileDuplicateService.Options,
        excludedPaths: [String], excludedPatterns: [String],
        onProgress: (@Sendable (FileDuplicateService.Progress) -> Void)?
    ) async throws -> FileDuplicateResults {
        let index = requests.count
        requests.append(Request(roots: roots, options: options, excludedPaths: excludedPaths, excludedPatterns: excludedPatterns))
        reports[index] = onProgress
        if let results { return results }
        return try await withCheckedThrowingContinuation { scans[index] = $0 }
    }
    func report(_ index: Int, completed: Int) {
        reports[index]?(.init(stage: .verifying, completed: completed, total: 100))
    }
    func finish(_ index: Int, results: FileDuplicateResults) {
        scans.removeValue(forKey: index)?.resume(returning: results)
    }
    func fail(_ index: Int) {
        scans.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadUnknown))
    }
}

private actor HeldFileRemoval: FileDuplicatesRemoving {
    private var continuation: CheckedContinuation<FileDuplicateRemovalOutcome, any Error>?
    private(set) var requestCount = 0
    private(set) var keepsReceipt = true
    var isPending: Bool { continuation != nil }
    func remove(
        selectedIDs: Set<DuplicateFile.ID>, from groups: [FileDuplicateGroup],
        keepReceipt: Bool
    ) async throws -> FileDuplicateRemovalOutcome {
        requestCount += 1
        keepsReceipt = keepReceipt
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ outcome: FileDuplicateRemovalOutcome) {
        continuation?.resume(returning: outcome)
        continuation = nil
    }
    func fail() {
        continuation?.resume(throwing: CocoaError(.fileWriteUnknown))
        continuation = nil
    }
}

private final class FileRemovalFixture {
    private let folder: TemporaryFolder
    private let suffix = UUID().uuidString
    var root: URL { folder.url }

    init() throws {
        folder = try TemporaryFolder(prefix: "moppo-file-model")
        for name in ["first", "second", "third"] { _ = try writeCopy(name) }
    }

    func writeCopy(_ name: String) throws -> URL {
        try folder.write("moppo-\(name)-\(suffix).txt", contents: "Verified fixture contents")
    }

    func removeTrashedFixtures(_ log: MoppoCore.RemovalLog) {
        for receipt in log.recentEntries(limit: 10) where receipt.disposition == .trashed {
            guard let path = receipt.trashedPath,
                  URL(fileURLWithPath: path).lastPathComponent.contains(suffix) else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
