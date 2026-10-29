import AppKit
import MoppoCore
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
        var cellSelection: [Int: Bool] = [:]
        let view = CompactTable(
            items: (0..<300).map(Item.init),
            selection: Binding(get: { selection }, set: { selection = $0 }),
            sortOrder: Binding(get: { order }, set: { order = $0 }),
            columns: [
                CompactTableColumn("Name", width: 300, min: 150, sort: KeyPathComparator(\Item.id)) { item, selected in
                    let _ = cellSelection.updateValue(selected, forKey: item.id)
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
        // Reproduce tracking before AppKit sends the final selection notification.
        let coordinator = try #require(table.delegate as? CompactTable<Item, KeyPathComparator<Item>>.Coordinator)
        coordinator.isUpdating = true
        table.selectRowIndexes(IndexSet(integer: 7), byExtendingSelection: false)
        coordinator.isUpdating = false
        #expect(cellSelection[1] == true)
        #expect(cellSelection[7] == false)
        table.delegate?.tableViewSelectionIsChanging?(
            Notification(name: NSTableView.selectionIsChangingNotification, object: table)
        )
        #expect(cellSelection[1] == false)
        #expect(cellSelection[7] == true)
        #expect(selection == [7])
        table.selectRowIndexes(IndexSet([1, 2, 3, 5]), byExtendingSelection: false)
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

    @Test("Clicking a selected Storage Explorer row transfers arrow navigation from the sidebar")
    func rowClickFocus() async throws {
        _ = NSApplication.shared
        let model = AppModel(hasFullDiskAccess: { false })
        model.view = .storageExplorer
        let folder = try TemporaryFolder()
        let items = try (0..<3).map { index in
            StorageExplorerItem(
                url: try folder.write("Item \(index).txt"), kind: .file,
                allocatedBytes: Int64(3 - index), identity: "fixture-\(index)"
            )
        }
        model.storageExplorer.currentURL = folder.url
        model.storageExplorer.snapshot = StorageExplorerSnapshot(
            directory: folder.url, items: items, allocatedBytes: 6,
            fileCount: 3, unreadableCount: 0
        )
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
        let table = try #require(findTable(in: host))
        // Select the row before sending pointer input to this background window.
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder !== table)

        try clickRow(1, in: table, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.storageExplorer.selection == [items[1].id])
        #expect(window.firstResponder === table)

        try sendKey("\u{F701}", code: 125, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.storageExplorer.selection == [items[2].id])
        #expect(model.view == .storageExplorer)
        #expect(window.firstResponder === table)
        #expect(try sidebarFocusRingPixels(in: host) == 0)

        try sendKey("\u{F700}", code: 126, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.storageExplorer.selection == [items[1].id])
        #expect(model.view == .storageExplorer)
    }

    private func clickRow(_ row: Int, in table: NSTableView, window: NSWindow) throws {
        let frame = table.rect(ofRow: row)
        let location = table.convert(NSPoint(x: frame.minX + 30, y: frame.midY), to: nil)
        let down = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
        let up = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0
        ))
        // Native tables track the pointer until they receive the release event.
        NSApp.postEvent(up, atStart: true)
        table.mouseDown(with: down)
        if let release = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) {
            NSApp.sendEvent(release)
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
