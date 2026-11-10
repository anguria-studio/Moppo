import AppKit
import MoppoCore
import SwiftUI
import Testing

@Suite("Cleanup presentation", .serialized)
@MainActor
struct CleanupPresentationTests {
    @Test("Checkbox selection keeps scrolled Cleanup rows in place with several expanded sections", arguments: [false, true])
    func selectionKeepsScrollPosition(grouped: Bool) async throws {
        _ = NSApplication.shared
        let folder = try TemporaryFolder()
        let categories: [ScanCategoryResult] = try [CategoryID.systemCaches, .packageManagers, .xcode, .hiddenSystemData].map { id in
            let entries = try (0..<80).map { index in
                let name = "Cache \(id.rawValue) \(index)"
                let directory = folder.url.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let url = directory.appendingPathComponent("node_modules")
                try Data("Fixture".utf8).write(to: url)
                let owners: [AIStorageSection.Owner] = [.codex, .claudeCode, .cursor, .ollama]
                return FileEntry(url: url, displayName: name,
                    kind: .cache, allocatedBytes: Int64(1000 - index), isRegenerable: true,
                    aiStorageSection: grouped ? .init(owner: owners[index / 20], title: name, summary: "") : nil)
            }
            return ScanCategoryResult(categoryID: id,
                totalBytes: entries.reduce(0) { $0 + $1.allocatedBytes }, entries: entries)
        }
        let cleanup = CleanupModel(operations: OperationCoordinator(), measureSaving: { _ in nil })
        cleanup.scanFilter = .all
        cleanup.openCategories = Set(categories.map(\.categoryID))
        cleanup.scanResults = ScanResults(categories: categories, startedAt: .now, finishedAt: .now)
        cleanup.dataTypeFilter = grouped ? .nodeModules : .all
        let host = NSHostingView(rootView: ScannerView(model: cleanup, activity: nil, cleanupCompletion: nil,
            onContinue: { _ in }, onViewDashboard: { _ in }, onUninstallApplication: { _ in },
            onShowInStorageExplorer: { _ in }).background(Token.pageBackground))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let scroll = try #require(scrollViews(in: host).first)
        for offset in [300.0, 1500, 4000, 1000, 7000, 2500, 9000, 5000] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let checkbox = try #require(nativeButtons(in: host).first {
                $0.accessibilityLabel()?.hasPrefix("Cache ") == true && $0.visibleRect.height > 0
            })
            let label = try #require(checkbox.accessibilityLabel())
            let entry = try #require(categories.flatMap(\.entries).first { $0.displayName == label })
            let origin = scroll.contentView.bounds.origin
            let frame = checkbox.convert(checkbox.bounds, to: host)
            for selected in [true, false] {
                let current = try #require(nativeButtons(in: host).first { $0.accessibilityLabel() == label })
                current.performClick(nil)
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                let updated = try #require(nativeButtons(in: host).first { $0.accessibilityLabel() == label })
                #expect(cleanup.scannerSelection.contains(entry.id) == selected)
                #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1,
                    "Selection changed the scroll position at \(offset).")
                #expect(abs(updated.convert(updated.bounds, to: host).minY - frame.minY) < 1,
                    "Selection moved the selected row at \(offset).")
            }
            #expect(cleanup.openCategories == Set(categories.map(\.categoryID)))
        }

        let category = try #require(categories.last)
        let header = try #require(nativeButtons(in: host).last {
            $0.accessibilityLabel() == "Select all items in this table"
        })
        let document = try #require(scroll.documentView)
        let headerY = header.convert(header.bounds, to: document).minY
        scroll.contentView.scroll(to: NSPoint(x: 0, y: headerY - 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        #expect(header.visibleRect.height > 0)
        let origin = scroll.contentView.bounds.origin
        let frame = header.convert(header.bounds, to: host)
        for selected in [true, false] {
            header.performClick(nil)
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            #expect(cleanup.selectedIDs(in: category) == (selected ? Set(category.entries.map(\.id)) : []))
            #expect(abs(scroll.contentView.bounds.origin.y - origin.y) < 1)
            #expect(abs(header.convert(header.bounds, to: host).minY - frame.minY) < 1)
        }
    }

    @Test("Sidebar input browses other views while Cleanup or Trash removal keeps its guard", arguments: [false, true])
    func removalNavigation(emptyTrash: Bool) async throws {
        _ = NSApplication.shared
        let folder = try TemporaryFolder()
        let settings = try RemovalSettingsFixture(confirm: true)
        let entry = FileEntry(url: try folder.write("Cache"), kind: .cache, allocatedBytes: 64, isRegenerable: true)
        let scanner = HeldCleanupScanner()
        let removal = HeldCleanupRemoval()
        let trash = HeldRecoveryTrash()
        let model = AppModel(settings: settings.settings, hasFullDiskAccess: { true },
            trashService: trash, historyReader: HeldRecoveryHistory(holdReads: false),
            cleanupScanner: scanner, cleanupRemover: removal)
        model.dashboard.canLoad = { false }
        model.cleanup.refreshAfterRemoval = {}
        model.recovery.refreshAfterMutation = { _ in }
        model.cleanup.scanFilter = .all
        model.cleanup.scanResults = ScanResults(
            categories: [.init(categoryID: .systemCaches, totalBytes: 64, entries: [entry])],
            startedAt: .now, finishedAt: .now
        )
        model.cleanup.scannerSelection = [entry.id]
        model.recovery.trashSummary = TrashSummary(totalBytes: 64, itemCount: 1, items: [recoveryItem("Saved")])
        let destination: AppModel.View = emptyTrash ? .trash : .scanner
        model.view = destination
        if !emptyTrash { model.cleanup.requestCleanUp() }
        let caller = Task {
            if emptyTrash { await model.recovery.emptyTrash() }
            else { await model.cleanup.performCleanUp() }
        }
        try await waitUntil { emptyTrash ? await trash.emptyRequests == 1 : await removal.isPending }
        let operation = try #require(model.operations.activeOperation)
        #expect(model.activityDestination == destination)
        #expect(model.showsActivityOnCurrentView)

        let host = NSHostingView(rootView: MainWindow(model: model)
            .environment(\.scenePhase, .inactive))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1120, height: 734),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        try click(NSPoint(x: 100, y: Token.Size.headerBand + 244), in: host, window: window)
        try await waitUntil { model.view == .dashboard }
        #expect(!model.showsActivityOnCurrentView)
        #expect(model.operations.activeOperation == operation)

        try await Task.sleep(for: .milliseconds(100))
        try sendKey("\u{F701}", code: 125, to: window)
        try await waitUntil { model.view == .history }
        #expect(model.canFind)
        model.requestFind()
        #expect(model.findRequest == 1)
        #expect(!model.showsActivityOnCurrentView)
        #expect(model.operations.activeOperation == operation)
        try await Task.sleep(for: .milliseconds(100))
        let bitmap = try capture(host)
        try bitmap.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/moppo-391-navigation-\(emptyTrash ? "trash" : "cleanup").png")
        )
        model.recovery.requestPutBack([recoveryItem("Saved")])
        #expect(model.operations.blockedAction?.operation == operation)
        #expect(await trash.restorations.isEmpty)
        model.cleanup.startScan()
        model.cleanup.requestCleanUp()
        #expect(await scanner.requestCount == 0)
        #expect(model.cleanup.pendingCleanUp == nil)
        #expect(!model.canEmptyTrash)
        for kind in OperationCoordinator.Kind.allCases {
            #expect(model.operations.begin(kind) == nil)
        }

        // Return focus from the search field to the selected sidebar row.
        try click(NSPoint(x: 100, y: Token.Size.headerBand + 280), in: host, window: window)
        try await Task.sleep(for: .milliseconds(100))
        try sendKey("\u{F701}", code: 125, to: window)
        try await waitUntil { model.view == .trash }
        #expect(model.showsActivityOnCurrentView == emptyTrash)
        #expect(model.operations.activeOperation == operation)
        if !emptyTrash {
            model.view = .scanner
            #expect(model.showsActivityOnCurrentView)
        }
        model.view = .history
        if emptyTrash { await trash.finishEmpty(freed: 64, skipped: 0) }
        else { await removal.finish(CleanupOutcome(removedBytes: 64, removedCount: 1, trashedCount: 1)) }
        await caller.value
        #expect(model.view == .history)
        #expect(model.activity == nil)
        #expect(!model.isBusyWithDisk)
        if emptyTrash { #expect(model.removalCompletion?.destination == .trash) }
        else { #expect(model.cleanupCompletion?.outcome.removedCount == 1) }
        model.view = .duplicates
        model.duplicateKind = .photos
        model.view = destination
        if emptyTrash { #expect(model.removalCompletion?.title == "Trash emptied") }
        else { #expect(model.cleanupCompletion != nil) }
        let next = try #require(model.operations.begin(.cleanupScan))
        model.operations.finish(next)
    }

    @Test("The notice about older results leaves the sidebar and header visible", arguments: [false, true])
    func outdatedOverlay(dark: Bool) async throws {
        _ = NSApplication.shared
        let folder = try TemporaryFolder()
        let entry = FileEntry(url: try folder.write("Cached item"), kind: .file, allocatedBytes: 100)
        let model = AppModel(hasFullDiskAccess: { false })
        model.dashboard.canLoad = { false }
        model.cleanup.scanFilter = .all
        model.cleanup.scanResults = ScanResults(
            categories: [.init(categoryID: .systemCaches, totalBytes: 100, entries: [entry])],
            startedAt: .now, finishedAt: .now
        )
        let host = NSHostingView(rootView: MainWindow(model: model)
            .environment(\.scenePhase, .inactive)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1120, height: 734),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let before = try capture(host)
        model.cleanup.markResultsOutdated()
        try await Task.sleep(for: .milliseconds(100))
        let after = try capture(host)
        let scale = CGFloat(after.pixelsWide) / host.bounds.width
        let sidebar = CGRect(x: 0, y: 0, width: Token.Size.sidebarWidth * scale,
                             height: CGFloat(after.pixelsHigh))
        let header = CGRect(x: sidebar.maxX, y: 0,
                            width: CGFloat(after.pixelsWide) - sidebar.width,
                            height: Token.Size.headerBand * scale)
        #expect(try pixels(before, in: sidebar) == pixels(after, in: sidebar))
        #expect(try pixels(before, in: header) == pixels(after, in: header))
        #expect(before.tiffRepresentation != after.tiffRepresentation)
        let name = dark ? "dark" : "light"
        try after.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/moppo-cleanup-overlay-\(name).png")
        )
    }

    private func capture(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func pixels(_ bitmap: NSBitmapImageRep, in rect: CGRect) throws -> Data {
        let bytes = try #require(bitmap.bitmapData)
        let pixelBytes = bitmap.bitsPerPixel / 8
        var data = Data()
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let offset = y * bitmap.bytesPerRow + Int(rect.minX) * pixelBytes
            data.append(bytes.advanced(by: offset), count: Int(rect.width) * pixelBytes)
        }
        return data
    }
}
