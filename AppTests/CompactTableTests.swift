import AppKit
import SwiftUI
import Testing

@Suite("Compact native tables", .serialized)
@MainActor
struct CompactTableTests {
    private struct Item: Identifiable {
        let id: Int
        var name: String { "Item \(id)" }
    }

    @Test("Selection and sorting update bindings without changing row geometry", arguments: [false, true])
    func tableInteraction(dark: Bool) async throws {
        var selection: Set<Int> = []
        var order = [KeyPathComparator(\Item.id)]
        var menuSelection: Set<Int> = []
        let view = CompactTable(
            items: (0..<300).map(Item.init),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            sortOrder: Binding(get: { order }, set: { order = $0 }),
            columns: [
                CompactTableColumn("Name", width: 300, min: 150, sort: KeyPathComparator(\Item.id)) { item, _ in
                    Text(item.name)
                },
                CompactTableColumn("Size", width: 90, min: 80, max: 120) { _, _ in Text("125 MB") }
            ],
            itemName: { $0.name },
            allowsMultipleSelection: true,
            menuActions: { ids in
                [CompactTableMenuAction(title: "Put Back") { menuSelection = ids }]
            }
        )
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 360),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let table = try #require(findTable(in: host))
        #expect(table.numberOfRows == 300)
        let firstFrame = table.rect(ofRow: 0)
        #expect(firstFrame.height == 22)
        #expect(table.headerView?.isOpaque == true)
        #expect(table.headerView?.allowsVibrancy == false)
        #expect(table.delegate?.tableView?(table, typeSelectStringFor: table.tableColumns.first, row: 12) == "Item 12")

        table.selectRowIndexes(IndexSet([1, 2, 3, 5]), byExtendingSelection: false)
        #expect(selection == [1, 2, 3, 5])
        #expect(table.rect(ofRow: 0) == firstFrame)
        table.sortDescriptors = [NSSortDescriptor(key: "0", ascending: false)]
        #expect(order.first?.order == .reverse)
        #expect(table.rect(ofRow: 0) == firstFrame)

        let row = try #require(table.rowView(atRow: 1, makeIfNecessary: true))
        row.isEmphasized = false
        let bitmap = try #require(row.bitmapImageRepForCachingDisplay(in: row.bounds))
        row.cacheDisplay(in: row.bounds, to: bitmap)
        let fill = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(fill.blueComponent > fill.redComponent + 0.3)
        #expect(fill.alphaComponent == 1)

        let frame = table.frame
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        #expect(table.frame == frame)
        #expect(table.rect(ofRow: 0) == firstFrame)
        let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: image)
        let png = try #require(image.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/moppo-compact-table-\(dark ? "dark" : "light").png"))

        for (rowIndex, expected) in [(2, Set([1, 2, 3, 5])), (7, Set([7]))] {
            let rect = table.rect(ofRow: rowIndex)
            let location = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = try #require(NSEvent.mouseEvent(
                with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
            let menu = try #require(table.menu(for: event))
            let action = try #require(menu.items.first)
            #expect(selection == expected)
            #expect(NSApp.sendAction(try #require(action.action), to: action.target, from: action))
            #expect(menuSelection == expected)
        }
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let table = findTable(in: child) { return table }
        }
        return nil
    }
}
