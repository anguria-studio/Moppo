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
