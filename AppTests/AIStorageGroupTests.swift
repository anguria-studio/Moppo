import AppKit
import SwiftUI
import Testing
import MoppoCore

@Suite("AI storage groups", .serialized)
@MainActor
struct AIStorageGroupTests {
    @Test("Groups retain row identities and count sessions and child storage once")
    func groupsAndTotals() throws {
        let rows = fixture()
        let groups = FileTableGroup.make(from: rows, sortKey: .size, ascending: false)
        #expect(groups.map(\.owner) == [.codex, .chatGPT, .claudeCode, .claude])
        let codex = try #require(groups.first)
        #expect(codex.totalBytes == 4_500_000_000)
        #expect(codex.entries.map(\.id) == [rows[0].id, rows[2].id, rows[4].id])
        #expect(groups.flatMap(\.entries).count == rows.count)
        #expect(Set(groups.flatMap(\.entries).map(\.id)) == Set(rows.map(\.id)))
        #expect(groups.reduce(0) { $0 + $1.totalBytes } == rows.reduce(0) { $0 + $1.displayBytes })
        #expect(groups.flatMap(\.entries) == [rows[0], rows[2], rows[4], rows[1], rows[3], rows[5]])
        #expect(codex.entries.allSatisfy { $0.isRemovalLocked })
        #expect(groups.flatMap { $0.visibleEntries(expandedOwners: []) }.isEmpty)
        #expect(groups.flatMap { $0.visibleEntries(expandedOwners: [.codex, .claude]) }.map(\.id)
            == [rows[0].id, rows[2].id, rows[4].id, rows[5].id])
    }

    @Test("Name and date sorting keep owners together in each direction", arguments: [false, true])
    func sorting(ascending: Bool) {
        let rows = fixture()
        let named = FileTableGroup.make(from: rows, sortKey: .name, ascending: ascending)
        let alphabetical: [AIStorageSection.Owner?] = [.chatGPT, .claude, .claudeCode, .codex]
        #expect(named.map(\.owner) == (ascending ? alphabetical : alphabetical.reversed()))
        let sized = FileTableGroup.make(from: rows, sortKey: .size, ascending: ascending)
        let increasingSize: [AIStorageSection.Owner?] = [.claude, .claudeCode, .chatGPT, .codex]
        #expect(sized.map(\.owner) == (ascending ? increasingSize : increasingSize.reversed()))
        let dated = FileTableGroup.make(from: rows, sortKey: .lastOpened, ascending: ascending)
        let chronological: [AIStorageSection.Owner?] = [.claude, .claudeCode, .chatGPT, .codex]
        #expect(dated.map(\.owner) == (ascending ? chronological : chronological.reversed()))
        #expect(dated.first { $0.owner == .codex }?.entries.map(\.id) == [rows[0].id, rows[2].id, rows[4].id])
    }

    @Test("Other tables keep their supplied row order and filters keep section ownership")
    func otherRowsAndFilters() {
        let rows = fixture()
        var ordinary = rows
        for index in ordinary.indices { ordinary[index].aiStorageSection = nil }
        let ordinaryGroups = FileTableGroup.make(from: ordinary, sortKey: .name, ascending: true)
        #expect(ordinaryGroups.flatMap(\.entries) == ordinary)
        #expect(ordinaryGroups.flatMap { $0.visibleEntries(expandedOwners: []) } == ordinary)
        let category = ScanCategoryResult(categoryID: .aiTools, entries: rows)
        let safe = category.filtered(safeToRemove: true)
        let groups = FileTableGroup.make(from: safe.entries, sortKey: .size, ascending: false)
        #expect(groups.map(\.owner) == [.chatGPT])
        #expect(groups.first?.totalBytes == 100_000_000)
        #expect(groups.first?.entries.first?.aiStorageSection?.title == "Cache")
    }

    @Test("T3 Code grouping and selection keep scanned storage protected")
    func t3Inventory() async throws {
        let folder = try TemporaryFolder()
        for path in ["userdata/state.db", "scratch/project/source.txt", "tools/codex", "caches/state.json", "worktrees/task/source.txt"] {
            let url = folder.url.appendingPathComponent(".t3/" + path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 4096).write(to: url)
        }
        let category = try await AIToolsScanner(home: folder.url).scan(context: ScanContext())
        let row = try #require(category.entries.first)
        let group = try #require(FileTableGroup.make(from: category.entries, sortKey: .size, ascending: false).first)
        #expect(group.owner == .t3Code)
        #expect(group.totalBytes == category.totalBytes)
        #expect(group.visibleEntries(expandedOwners: []).isEmpty)
        #expect(group.visibleEntries(expandedOwners: [.t3Code]) == [row])
        #expect(group.totalBytes == row.allocatedBytes + row.children.reduce(0) { $0 + $1.allocatedBytes })
        let cleanup = CleanupModel(operations: OperationCoordinator())
        cleanup.scanResults = .init(categories: [category], startedAt: .now, finishedAt: .now)
        cleanup.seedSafeToRemoveSelection()
        cleanup.scanFilter = .all
        cleanup.selectAllInCurrentView()
        cleanup.setSelected(true, in: category)
        cleanup.unlockChildren(in: row)
        cleanup.setChildrenSelected(true, in: row.id)
        #expect(cleanup.scannerSelection.isEmpty)
        #expect(cleanup.userDataRemovalOverrides.isEmpty)
        let ids = Set(([row] + row.children).map(\.id))
        cleanup.scannerSelection = ids
        cleanup.userDataRemovalOverrides = ids
        #expect(cleanup.selectedEntries.isEmpty)
        #expect(cleanup.cleanupSelection(in: .all).isEmpty)
        #expect(cleanup.cleanupSelectionBytes(in: .all) == 0)
        #expect(cleanup.cleanupSelection(in: .safeToRemove).isEmpty)

        for dark in [false, true] {
            var collapsedHeight = 0.0
            for expanded in [false, true] {
                let table = FileTable(entries: category.entries, selection: .constant([]), userDataRemovalOverrides: .constant([]),
                    expandedGroups: expanded ? [.t3Code] : [])
                let output = URL(fileURLWithPath: "/tmp/moppo-223-\(expanded ? "expanded" : "collapsed")-\(dark ? "dark" : "light").png")
                let size = try await renderTestView(table, width: 788, dark: dark, output: output)
                if expanded { #expect(size.height > collapsedHeight) }
                else { collapsedHeight = size.height }
            }
        }
    }

    @Test("Cleanup filters reveal matching AI child rows when selected again", arguments: [false, true])
    func filteredChildVisibility(dark: Bool) async throws {
        let folder = try TemporaryFolder()
        let root = folder.url.appendingPathComponent(".codex")
        let worktreeURL = root.appendingPathComponent("worktrees/Task")
        let nodeURL = root.appendingPathComponent("tools/node_modules")
        for url in [worktreeURL, nodeURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var worktree = FileEntry(url: worktreeURL, kind: .folder, allocatedBytes: 2_000_000)
        worktree.gitWorktreeReview = GitWorktreeReview()
        let node = FileEntry(url: nodeURL, kind: .cache, allocatedBytes: 1_000_000, isRegenerable: true)
        let parent = FileEntry(url: root, kind: .folder, allocatedBytes: 100,
            protectionReason: .inventory,
            aiStorageSection: .init(owner: .codex, title: "Task data", summary: "Settings and worktrees."),
            children: [worktree, node])
        let cleanup = CleanupModel(operations: OperationCoordinator(), measureSaving: { _ in nil })
        cleanup.scanResults = .init(categories: [.init(categoryID: .aiTools, totalBytes: parent.displayBytes, entries: [parent])],
            startedAt: .now, finishedAt: .now)
        cleanup.scanFilter = .all
        cleanup.openCategories = []
        let host = NSHostingView(rootView: ScannerView(model: cleanup, activity: nil, cleanupCompletion: nil,
            onViewDashboard: { _ in }, onUninstallApplication: { _ in }, onShowInStorageExplorer: { _ in })
            .background(Token.pageBackground)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Token.Size.minimumContentWidth, height: 580),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()

        for filter in [CleanupDataType.worktrees, .all, .nodeModules, .worktrees] {
            cleanup.dataTypeFilter = filter
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            let labels = nativeButtons(in: host).compactMap { $0.accessibilityLabel() }
            #expect(labels.contains(worktree.displayName) == (filter == .worktrees))
            #expect(labels.contains(node.displayName) == (filter == .nodeModules))
            #expect(cleanup.openCategories.contains(.aiTools))
            #expect(cleanup.scannerSelection.isEmpty)
            #expect(cleanup.userDataRemovalOverrides.isEmpty)
        }

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/moppo-207-worktree-expansion-\(dark ? "dark" : "light").png"))
    }

    @Test("Collapsed and expanded application groups render in both appearances", arguments: [false, true])
    func render(dark: Bool) async throws {
        let rows = fixture()
        #expect(ApplicationIcons.icon(for: .codex) != nil)
        for width in [788.0, 908.0] {
            var collapsedHeight = 0.0
            for expanded in [false, true] {
                let owners = Set(rows.compactMap { $0.aiStorageSection?.owner })
                let table = FileTable(entries: rows, selection: .constant([]), userDataRemovalOverrides: .constant([]),
                    expandedGroups: expanded ? owners : [])
                    .environment(\.colorScheme, dark ? .dark : .light)
                let host = NSHostingView(rootView: table)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 740),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                defer { window.contentView = nil }
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                if expanded { #expect(host.fittingSize.height > collapsedHeight + 200) }
                else { collapsedHeight = host.fittingSize.height }
                let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let state = expanded ? "expanded" : "collapsed"
                try png.write(to: URL(fileURLWithPath: "/tmp/moppo-144-accordion-\(state)-\(dark ? "dark" : "light")-\(Int(width)).png"))
            }
        }
    }

    private func fixture() -> [FileEntry] {
        func row(_ path: String, owner: AIStorageSection.Owner, title: String, summary: String,
                 bytes: Int64, day: Double, children: [FileEntry] = []) -> FileEntry {
            FileEntry(url: URL(fileURLWithPath: "/moppo-fixture/" + path), displayName: owner.rawValue + " " + title,
                kind: .folder, allocatedBytes: bytes, lastOpened: .now.addingTimeInterval(-(7 - day) * 86400),
                protectionReason: .inventory, aiTool: owner.tool,
                aiStorageSection: .init(owner: owner, title: title, summary: summary), children: children)
        }
        let cache = FileEntry(url: URL(fileURLWithPath: "/moppo-fixture/Library/Application Support/Codex/Cache"),
            kind: .cache, allocatedBytes: 100_000_000, isRegenerable: true)
        let attachment = FileEntry(url: URL(fileURLWithPath: "/moppo-fixture/.codex/attachments"),
            kind: .folder, allocatedBytes: 500_000_000, protectionReason: .inventory)
        return [
            row(".codex", owner: .codex, title: "Task data", summary: "Settings, attachments, plugins, and worktrees.",
                bytes: 2_500_000_000, day: 4, children: [attachment]),
            row("Library/Application Support/Codex", owner: .chatGPT, title: "Desktop data",
                summary: "Desktop profiles, settings, and caches.", bytes: 1_900_000_000, day: 3, children: [cache]),
            row(".cache/codex-runtimes", owner: .codex, title: "Downloaded tools",
                summary: "Downloaded runtimes used to run tasks.", bytes: 1_000_000_000, day: 2),
            row(".claude", owner: .claudeCode, title: "Task data",
                summary: "Conversations, memories, attachments, and recovery files.", bytes: 300_000_000, day: 2),
            row(".codex/archived_sessions", owner: .codex, title: "Archived sessions",
                summary: "Archived conversations and task history.", bytes: 500_000_000, day: 1),
            row("Library/Application Support/Claude", owner: .claude, title: "Desktop data",
                summary: "Desktop profiles, caches, virtual machines, and local tasks.", bytes: 200_000_000, day: 1)
        ]
    }
}
