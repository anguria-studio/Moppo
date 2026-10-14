import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MoppoCore

private enum CompactTableMetrics {
    static let outerCellPadding: CGFloat = 8
}

/// Owns native table geometry before the first layout.
struct CompactTable<Item: Identifiable, Comparator: SortComparator>: NSViewRepresentable where Comparator.Compared == Item {
    var items: [Item]
    @Binding var selection: Set<Item.ID>
    @Binding var sortOrder: [Comparator]
    var columns: [CompactTableColumn<Item, Comparator>]
    var itemName: (Item) -> String
    var allowsMultipleSelection = false
    var onOpen: (Set<Item.ID>) -> Void = { _ in }
    var menuActions: (Set<Item.ID>) -> [CompactTableMenuAction] = { _ in [] }
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = CompactNativeTable()
        table.style = .inset
        table.rowHeight = 22
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.backgroundColor = .clear
        table.headerView = CompactTableHeader(frame: NSRect(x: 0, y: 0, width: 0, height: 24))
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = allowsMultipleSelection
        table.allowsEmptySelection = true
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openRow)
        table.contextActions = { [weak coordinator = context.coordinator] ids in
            guard let coordinator, coordinator.parent.isEnabled else { return [] }
            return coordinator.parent.menuActions(Set(ids.compactMap {
                coordinator.parent.items.indices.contains($0) ? coordinator.parent.items[$0].id : nil
            }))
        }
        for (index, definition) in columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            let edgePadding = (index == 0 ? CompactTableMetrics.outerCellPadding : 0)
                + (index == columns.count - 1 ? CompactTableMetrics.outerCellPadding : 0)
            column.title = definition.title
            column.minWidth = definition.minimumWidth + edgePadding
            column.maxWidth = definition.maximumWidth + edgePadding
            column.width = definition.width + edgePadding
            column.resizingMask = index == 0 ? [.autoresizingMask, .userResizingMask] : [.userResizingMask]
            if let comparator = definition.sort {
                column.sortDescriptorPrototype = NSSortDescriptor(key: String(index), ascending: comparator.order == .forward)
            }
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = table
        context.coordinator.table = table
        updateNSView(scroll, context: context)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let oldIDs = coordinator.parent.items.map(\.id)
        coordinator.parent = self
        guard let table = coordinator.table else { return }
        coordinator.isUpdating = true
        defer { coordinator.isUpdating = false }
        scroll.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        scroll.backgroundColor = NSColor(Token.pageBackground)
        if table.numberOfRows != items.count || oldIDs != items.map(\.id) {
            table.reloadData()
        }
        let selectedRows = IndexSet(items.indices.filter { selection.contains(items[$0].id) })
        if table.selectedRowIndexes != selectedRows {
            table.selectRowIndexes(selectedRows, byExtendingSelection: false)
            if let row = selectedRows.first { table.scrollRowToVisible(row) }
        }
        if let comparator = sortOrder.first,
           let index = columns.firstIndex(where: { column in
               guard var candidate = column.sort else { return false }
               candidate.order = comparator.order
               return candidate == comparator
           }) {
            let descriptor = NSSortDescriptor(key: String(index), ascending: comparator.order == .forward)
            if table.sortDescriptors != [descriptor] { table.sortDescriptors = [descriptor] }
        }
        coordinator.refreshVisibleCells()
        table.headerView?.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: CompactTable
        weak var table: NSTableView?
        var isUpdating = false
        init(_ parent: CompactTable) { self.parent = parent }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.items.count }

        func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
            parent.items.indices.contains(row) ? parent.itemName(parent.items[row]) : nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let key = tableColumn?.identifier, let column = Int(key.rawValue), parent.items.indices.contains(row) else { return nil }
            let cell = tableView.makeView(withIdentifier: key, owner: self) as? NSHostingView<AnyView>
                ?? NSHostingView(rootView: AnyView(EmptyView()))
            cell.identifier = key
            cell.rootView = content(row: row, column: column)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = CompactTableRow()
            view.alternates = row.isMultiple(of: 2) == false
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdating, let table else { return }
            parent.selection = Set(table.selectedRowIndexes.compactMap {
                parent.items.indices.contains($0) ? parent.items[$0].id : nil
            })
            refreshVisibleCells()
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !isUpdating, let descriptor = tableView.sortDescriptors.first,
                  let key = descriptor.key, let index = Int(key),
                  var comparator = parent.columns[index].sort else { return }
            comparator.order = descriptor.ascending ? .forward : .reverse
            parent.sortOrder = [comparator]
            tableView.headerView?.needsDisplay = true
        }

        @objc func openRow() {
            guard let table, table.clickedRow >= 0 else { return }
            parent.onOpen(parent.selection)
        }

        func refreshVisibleCells() {
            guard let table else { return }
            let visible = table.rows(in: table.visibleRect)
            guard visible.location != NSNotFound else { return }
            for row in visible.location..<NSMaxRange(visible) where parent.items.indices.contains(row) {
                for column in parent.columns.indices {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: false) as? NSHostingView<AnyView> {
                        cell.rootView = content(row: row, column: column)
                    }
                }
                table.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            }
        }

        private func content(row: Int, column: Int) -> AnyView {
            let selected = table?.selectedRowIndexes.contains(row) == true
            return AnyView(parent.columns[column].cell(parent.items[row], selected)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.white : Token.Text.tableName)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .padding(.leading, column == 0 ? CompactTableMetrics.outerCellPadding : 0)
                .padding(.trailing, column == parent.columns.count - 1 ? CompactTableMetrics.outerCellPadding : 0)
                .environment(\.colorScheme, parent.colorScheme)
                .disabled(!parent.isEnabled))
        }
    }
}

struct CompactTableColumn<Item, Comparator: SortComparator> where Comparator.Compared == Item {
    let title: String
    let width: CGFloat
    let minimumWidth: CGFloat
    let maximumWidth: CGFloat
    let sort: Comparator?
    let cell: (Item, Bool) -> AnyView

    init<Cell: View>(_ title: String, width: CGFloat, min: CGFloat, max: CGFloat = .greatestFiniteMagnitude,
                     sort: Comparator? = nil, @ViewBuilder cell: @escaping (Item, Bool) -> Cell) {
        self.title = title
        self.width = width
        minimumWidth = min
        maximumWidth = max
        self.sort = sort
        self.cell = { AnyView(cell($0, $1)) }
    }
}

struct CompactTableMenuAction {
    let title: String
    var isEnabled = true
    let perform: () -> Void
}

private final class CompactNativeTable: NSTableView {
    var contextActions: (IndexSet) -> [CompactTableMenuAction] = { _ in [] }
    private var actions: [CompactTableMenuAction] = []

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        actions = contextActions(selectedRowIndexes)
        guard !actions.isEmpty else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (index, action) in actions.enumerated() {
            let item = NSMenuItem(title: action.title, action: #selector(performMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.isEnabled = action.isEnabled
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performMenuAction(_ sender: NSMenuItem) { actions[sender.tag].perform() }
}

private final class CompactTableRow: NSTableRowView {
    var alternates = false
    override var isOpaque: Bool { true }
    override var allowsVibrancy: Bool { false }
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        NSColor(Token.pageBackground).setFill()
        bounds.fill()
        if alternates {
            NSColor(Token.Fill.control).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 0), xRadius: 6, yRadius: 6).fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let color = isDark ? NSColor.selectedContentBackgroundColor : NSColor.systemBlue
        color.setFill()
        let radius: CGFloat = 6
        var selectionRect = bounds.insetBy(dx: 6, dy: 0)
        if isPreviousRowSelected {
            selectionRect.size.height += radius
            if isFlipped { selectionRect.origin.y -= radius }
        }
        if isNextRowSelected {
            selectionRect.size.height += radius
            if !isFlipped { selectionRect.origin.y -= radius }
        }
        NSGraphicsContext.saveGraphicsState()
        bounds.clip()
        NSBezierPath(roundedRect: selectionRect, xRadius: radius, yRadius: radius).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Draws an opaque header while retaining native sorting and column resizing.
private final class CompactTableHeader: NSTableHeaderView {
    override var isOpaque: Bool { true }
    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Token.pageBackground).setFill()
        bounds.fill()
        guard let tableView else { return }
        let descriptor = tableView.sortDescriptors.first
        for (index, column) in tableView.tableColumns.enumerated() {
            let rect = headerRect(ofColumn: index)
            let sorted = descriptor?.key == column.identifier.rawValue
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: sorted ? .semibold : .regular),
                .foregroundColor: NSColor(Token.Text.secondary)
            ]
            let title = NSAttributedString(string: column.title, attributes: attributes)
            let leadingPadding = index == 0 ? CompactTableMetrics.outerCellPadding : 0
            let trailingPadding = index == tableView.tableColumns.count - 1 ? CompactTableMetrics.outerCellPadding : 0
            title.draw(in: NSRect(x: rect.minX + 4 + leadingPadding, y: rect.midY - 7,
                                 width: max(0, rect.width - 24 - leadingPadding - trailingPadding), height: 16))
            if sorted {
                let direction: CGFloat = descriptor?.ascending == true ? -1 : 1
                let arrow = NSBezierPath()
                arrow.move(to: NSPoint(x: rect.maxX - 16 - trailingPadding, y: rect.midY - 2 * direction))
                arrow.line(to: NSPoint(x: rect.maxX - 12 - trailingPadding, y: rect.midY + 2 * direction))
                arrow.line(to: NSPoint(x: rect.maxX - 8 - trailingPadding, y: rect.midY - 2 * direction))
                arrow.lineWidth = 1.2
                NSColor(Token.Text.secondary).setStroke()
                arrow.stroke()
            }
            NSColor(Token.separator).setFill()
            NSRect(x: rect.maxX - 1, y: rect.minY + 5, width: 1, height: rect.height - 10).fill()
        }
        NSColor(Token.separator).setFill()
        NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
    }
}

struct CompactTableDate: View {
    let date: Date?
    var isSelected = false

    var body: some View {
        Text(date.map {
            $0.formatted(.dateTime.day().month(.abbreviated)) + " " + $0.formatted(.dateTime.hour().minute())
        } ?? "—")
        .foregroundStyle(isSelected ? Color.white : Token.Text.tableDetail)
        .lineLimit(1)
        .help(date?.formatted(date: .complete, time: .shortened) ?? "Date unknown")
    }
}

/// Keeps the item name and its original folder on one line.
struct CompactTableItem: View {
    let name: String
    let path: String
    let iconURL: URL
    var isSelected = false

    var body: some View {
        HStack(spacing: 7) {
            FileKindIcon(url: iconURL, size: 16)
            Text(name)
                .foregroundStyle(isSelected ? Color.white : Token.Text.tableName)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(path)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Token.Text.tablePath)
                .truncationMode(.middle)
        }
        .lineLimit(1)
        .frame(height: 18)
        .help(path.isEmpty ? name : "\(name) — \(path)")
    }
}

/// A small row action remains distinct from the selected row.
struct CompactTableActionStyle: ButtonStyle {
    var isSelected = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isEnabled && (isHovering || configuration.isPressed)
        return configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isSelected ? Color.white : Token.Text.primary)
            .padding(.horizontal, 9)
            .frame(height: 18)
            .background(
                isSelected ? Color.white.opacity(highlighted ? 0.36 : 0.22)
                    : (highlighted ? Token.Fill.buttonHover : Token.Fill.buttonOnCard),
                in: Capsule()
            )
            .overlay(Capsule().strokeBorder(isSelected || !isEnabled ? .clear : Token.Fill.buttonBorder, lineWidth: 1))
            .opacity(!isEnabled ? 0.5 : (configuration.isPressed ? 0.7 : 1))
            .contentShape(Capsule())
            .onHover { isHovering = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: highlighted)
    }
}

/// Gives known file types the same icon in the list and map.
struct FileKindIcon: View {
    let url: URL
    var isDirectory: Bool? = nil
    var usesFileType = true
    let size: CGFloat

    var body: some View {
        Group {
            if let appearance {
                Image(systemName: appearance.symbol)
                    .font(.system(size: size >= 32 ? size * 0.62 : size * 0.9, weight: .regular))
                    .foregroundStyle(appearance.color)
                    .frame(width: size, height: size)
                    .background {
                        if size >= 32 {
                            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                                .fill(appearance.color.opacity(0.10))
                        }
                    }
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    private var appearance: (symbol: String, color: Color)? {
        let values = isDirectory == nil ? try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) : nil
        if isDirectory ?? (values?.isDirectory == true && values?.isPackage != true) {
            return ("folder.fill", Token.color(.teal))
        }
        guard usesFileType else { return nil }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
            || ["mkv", "webm", "avi", "imovielibrary", "fcpbundle"].contains(ext) {
            return ("play.rectangle.fill", Token.textColor(.pink))
        }
        if type?.conforms(to: .image) == true || ["photoslibrary", "photolibrary", "raw"].contains(ext) {
            return ("photo.fill", Token.textColor(.orange))
        }
        if type?.conforms(to: .audio) == true || ["flac", "ogg", "opus"].contains(ext) {
            return ("waveform", Token.textColor(.pink))
        }
        if type?.conforms(to: .pdf) == true {
            return ("doc.richtext.fill", Token.textColor(.red))
        }
        if type?.conforms(to: .sourceCode) == true
            || ["js", "jsx", "ts", "tsx", "py", "rs", "go", "css", "json", "yaml", "yml"].contains(ext) {
            return ("chevron.left.forwardslash.chevron.right", Token.textColor(.purple))
        }
        if type?.conforms(to: .spreadsheet) == true || ["csv", "numbers", "xlsx", "xls"].contains(ext) {
            return ("tablecells.fill", Token.textColor(.green))
        }
        if type?.conforms(to: .presentation) == true || ["key", "pptx", "ppt"].contains(ext) {
            return ("rectangle.on.rectangle", Token.textColor(.orange))
        }
        if type?.conforms(to: .text) == true || ["pages", "doc", "docx", "odt"].contains(ext) {
            return ("doc.text.fill", Token.textColor(.accent))
        }
        if type?.conforms(to: .archive) == true || ["7z", "rar", "gz", "bz2", "xz"].contains(ext) {
            return ("doc.zipper", Token.textColor(.orange))
        }
        if type?.conforms(to: .diskImage) == true || ["dmg", "iso", "sparsebundle"].contains(ext) {
            return ("externaldrive.fill", Token.Text.secondary)
        }
        if ext == "pkg" {
            return ("shippingbox.fill", Token.textColor(.orange))
        }
        return nil
    }
}
