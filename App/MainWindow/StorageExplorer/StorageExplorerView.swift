import AppKit
import MoppoCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Browses measured folders with native macOS table and path controls.
struct StorageExplorerView: View {
    @Bindable var model: StorageExplorerModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animateEmptyResult = false
    @State private var resultBeforeScan: Date?
    private var isMeasurementBlocked: Bool { model.isMeasurementBlocked }
    @State private var previewURL: URL?
    @State private var previewNavigation = FilePreviewNavigation()
    @State private var presentation = StorageExplorerPresentation.list
    @State private var rowOrder = StorageExplorerRowOrder()
    @State private var partialResultsDirectory: URL?
    @State private var sortOrder = [
        KeyPathComparator(\StorageExplorerItem.allocatedBytes, order: .reverse)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let currentURL = model.currentURL {
                header
                pathBar(currentURL)
            }

            content
        }
        .task {
            model.prepareLocations()
            refreshIfNeeded()
        }
        .onChange(of: model.needsRefresh) { _, _ in refreshIfNeeded() }
        .onChange(of: isMeasurementBlocked) { _, _ in refreshIfNeeded() }
        .onChange(of: model.isLoading, initial: true) { wasRunning, isRunning in
            if isRunning {
                partialResultsDirectory = nil
                resultBeforeScan = model.snapshot?.measuredAt
                animateEmptyResult = false
            } else if wasRunning {
                refreshIfNeeded()
                animateEmptyResult = model.snapshot?.measuredAt != nil
                    && model.snapshot?.measuredAt != resultBeforeScan
            }
        }
        .onChange(of: model.currentURL) { _, _ in animateEmptyResult = false }
        .task(id: pendingDirectory) {
            partialResultsDirectory = nil
            guard let directory = pendingDirectory else { return }
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard !Task.isCancelled, pendingDirectory == directory else { return }
            partialResultsDirectory = directory
        }
        .onChange(of: displayedSnapshot, initial: true) { _, _ in updateRowOrder() }
        .onChange(of: sortOrder) { _, _ in updateRowOrder(forceSort: true) }
        .onDisappear { animateEmptyResult = false }
        .onChange(of: presentation) { _, _ in model.finishMapSelection() }
        .onDisappear {
            model.finishMapSelection()
            previewNavigation.stop()
            previewURL = nil
        }
        .quickLookPreview($previewURL, in: sortedItems.map(\.url))
        .onChange(of: previewURL) { _, url in
            guard let url else {
                previewNavigation.stop()
                return
            }
            guard let index = sortedItems.firstIndex(where: { $0.url == url }) else { return }
            let item = sortedItems[index]
            if !model.selection.contains(item.id) {
                model.selection = [item.id]
            }
            previewNavigation.scrollToRow(index)
        }
        .onChange(of: model.selection) { _, selection in
            guard previewURL != nil else { return }
            if let current = sortedItems.first(where: { $0.url == previewURL }),
               selection.contains(current.id) { return }
            previewURL = sortedItems.first(where: { selection.contains($0.id) })?.url
        }
        .onChange(of: model.currentURL) { _, _ in previewURL = nil }
        // Space previews the selection, as it does in Finder.
        //
        // `onKeyPress(.space)` cannot do this and did not: `NSTableView` consumes
        // space in `keyDown` for type-select, so the key never reached SwiftUI. A
        // keyboard shortcut is installed as a key equivalent instead, which is
        // offered the event before the responder chain ever sees it. Disabled with
        // no selection, so the shortcut does not fire on nothing.
        .background(alignment: .topLeading) {
            Button("Quick Look") { previewSelection() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(model.selectedItems.isEmpty)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
    }

    private func previewSelection() {
        guard let item = model.selectedItems.first else { return }
        showPreview(item)
    }

    private func refreshIfNeeded() {
        guard !isMeasurementBlocked else { return }
        model.refreshIfNeeded()
    }

    private func showPreview(_ item: StorageExplorerItem) {
        previewNavigation.start(onClose: { previewURL = nil }) { direction in
            let items = sortedItems
            guard let index = items.firstIndex(where: { $0.url == previewURL }) else { return }
            let next = index + direction
            guard items.indices.contains(next) else { return }
            model.selection = [items[next].id]
            previewURL = items[next].url
            previewNavigation.scrollToRow(next)
        }
        previewURL = item.url
    }

    @ViewBuilder
    private var content: some View {
        if model.currentURL == nil {
            startView
        } else if model.needsRefresh {
            PageState(
                title: "Waiting for the Current Operation", symbol: "hourglass",
                detail: "Finish or stop the current operation to measure this folder again."
            )
        } else if model.wasCancelled {
            cancelledView
        } else if let error = model.error {
            errorView(error)
        } else if !model.isLoading, model.snapshot?.items.isEmpty == true {
            emptyView
        } else if presentation == .map {
            treemap
        } else {
            table
        }
    }

    /// What this folder holds, and the controls that act on the page.
    ///
    /// The path used to sit in the leading slot here and it could not: a path
    /// control does not compress, so it took the width the trailing controls needed
    /// and drew straight over them. It has a row of its own below.
    ///
    /// There is no selection readout and no Deselect All: the highlighted rows say
    /// what is picked, the Remove button says what it would take, and clicking away
    /// from the rows clears them, as it does in any table on this platform.
    private var header: some View {
        PageHeader {
            PageSegmentedControl(selection: $presentation, segments:
                StorageExplorerPresentation.allCases.map { option in
                    .init(id: option, title: option.rawValue,
                          symbol: option == .list ? "list.bullet" : "square.grid.2x2")
                }
            )
        } trailing: {
            Button {
                model.refresh()
            } label: {
                Label("Measure Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(PageActionButtonStyle(size: .small))
            .fixedSize()
            .disabled(isMeasurementBlocked || model.isLoading)

            locationMenu
                .buttonStyle(PageActionButtonStyle(size: .small))
                .fixedSize()
        }
    }

    private var summaryText: String {
        guard let snapshot = model.snapshot else {
            return model.isLoading ? "Reading folder contents…"
                : model.currentURL?.lastPathComponent.nonEmpty ?? "This Mac"
        }
        let count = snapshot.items.count
        let noun = count == 1 ? "item" : "items"
        let prefix = snapshot.isComplete ? "" : "Measuring · "
        return "\(prefix)\(count) \(noun) · \(ByteFormatting.string(snapshot.allocatedBytes))"
    }

    /// Where you are, and the two ways back — a row of its own, because both are
    /// navigation and neither survives being squeezed.
    ///
    /// The arrows used to be the window's toolbar pair. Those meant pages everywhere
    /// else and folders here — one control with two meanings — so they went, and
    /// this is the half that was doing real work: the path control beside them only
    /// ever walks *up*, and returning to a folder seen earlier has no other route.
    private func pathBar(_ url: URL) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 2) {
                Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canGoBack || isMeasurementBlocked)
                    .help("Back to the last folder")
                Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canGoForward || isMeasurementBlocked)
                    .help("Forward")
            }
            .buttonStyle(.accessoryBar)
            .fixedSize()

            NativePathControl(url: url, onSelect: model.navigate)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 26, maxHeight: 26)
                .disabled(isMeasurementBlocked)

            if model.snapshot != nil || model.isLoading {
                Text(summaryText)
                    .pageHeaderSummary()
                    .monospacedDigit()
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .padding(.horizontal, Token.Size.pageGutter)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Token.separator)
                .frame(height: Token.hairline)
        }
    }

    private var startView: some View {
        PageState(
            title: "Explore storage", symbol: "internaldrive",
            detail: "Choose a folder or volume. Moppo will measure each item on disk."
        ) {
            locationMenu
                .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
        }
    }

    private func errorView(_ error: StorageExplorerError) -> some View {
        PageState(
            title: "The folder could not be read", symbol: "folder.badge.questionmark",
            detail: errorDescription(error)
        ) {
            PageStateActions {
                Button("Try Again") { model.refresh() }
                    .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
                Button { model.chooseFolder() } label: {
                    Label("Choose Another Folder", systemImage: "folder")
                }
                .buttonStyle(PageStateButtonStyle())
            }
        }
    }

    private var cancelledView: some View {
        PageState(
            title: "Measurement stopped", symbol: "stop.circle",
            detail: "Measure this folder again or choose another location."
        ) {
            PageStateActions {
                Button("Measure Again") { model.refresh() }
                    .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
                Button { model.chooseFolder() } label: {
                    Label("Choose Another Folder", systemImage: "folder")
                }
                .buttonStyle(PageStateButtonStyle())
            }
        }
    }

    private var emptyView: some View {
        PageCompletionView(title: "No files found", animate: animateEmptyResult) {
            Text("Choose another folder or return to the previous folder.")
        } actions: {
            locationMenu
                .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
        }
    }

    private var table: some View {
        CompactTable(
            items: sortedItems, selection: $model.selection, sortOrder: $sortOrder,
            columns: [
                CompactTableColumn("Name", width: 340, min: 200, sort: KeyPathComparator(\StorageExplorerItem.name)) { item, selected in
                    nameCell(item).foregroundStyle(selected ? Color.white : Token.Text.tableName)
                },
                CompactTableColumn("Kind", width: 90, min: 75, max: 160, sort: KeyPathComparator(\StorageExplorerItem.kindSortName)) { item, selected in
                    Text(item.kindTitle).foregroundStyle(selected ? Color.white : Token.Text.tableDetail)
                },
                CompactTableColumn("Files", width: 64, min: 50, max: 96, sort: KeyPathComparator(\StorageExplorerItem.fileCount)) { item, selected in
                    Text(item.fileCountLabel).monospacedDigit()
                        .foregroundStyle(selected ? Color.white : Token.Text.tableDetail)
                },
                CompactTableColumn("Modified", width: 110, min: 98, max: 150, sort: KeyPathComparator(\StorageExplorerItem.modificationSortValue)) { item, selected in
                    Text(item.modificationDate?.formatted(date: .abbreviated, time: .omitted) ?? "—")
                        .foregroundStyle(selected ? Color.white : Token.Text.tableDetail)
                },
                CompactTableColumn("Size", width: 90, min: 86, max: 124, sort: KeyPathComparator(\StorageExplorerItem.allocatedBytes)) { item, selected in
                    Text(model.snapshot?.isComplete == false && item.allocatedBytes == 0
                         ? "Measuring…" : ByteFormatting.string(item.allocatedBytes))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white : Token.Text.tableSize)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            ],
            itemName: { $0.name },
            allowsMultipleSelection: true,
            onOpen: { selection in
                guard selection.count == 1, let item = firstItem(in: selection) else { return }
                if item.opensAsDirectory {
                    if !isMeasurementBlocked { model.open(item) }
                } else { showPreview(item) }
            },
            menuActions: { selection in
                var actions: [CompactTableMenuAction] = []
                if selection.count == 1, let item = firstItem(in: selection) {
                    if item.opensAsDirectory {
                        actions.append(CompactTableMenuAction(title: "Open", isEnabled: !isMeasurementBlocked) { model.open(item) })
                    }
                    actions.append(CompactTableMenuAction(title: "Quick Look") { showPreview(item) })
                }
                if !selection.isEmpty {
                    actions.append(CompactTableMenuAction(title: "Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(urls(in: selection))
                    })
                }
                return actions
            }
        )
    }

    private var treemap: some View {
        StorageTreemapView(
            items: displayedSnapshot?.items ?? [],
            selection: Binding(
                get: { model.selection },
                set: { model.selectMapItems($0) }
            ),
            isMeasuring: model.isLoading,
            isNavigationDisabled: isMeasurementBlocked,
            onOpen: { model.open($0) },
            onPreview: { showPreview($0) }
        )
    }

    private var pendingDirectory: URL? {
        model.isLoading && model.snapshot?.isComplete != true ? model.currentURL : nil
    }

    private var displayedSnapshot: StorageExplorerSnapshot? {
        guard let snapshot = model.snapshot else { return nil }
        // Fast scans show completed results without an intermediate row order.
        // Breadcrumb URLs can differ from the resolved measurement URL.
        guard snapshot.isComplete || partialResultsDirectory == model.currentURL else { return nil }
        return snapshot
    }

    private var sortedItems: [StorageExplorerItem] {
        rowOrder.items(in: displayedSnapshot, sortOrder: sortOrder)
    }

    private func updateRowOrder(forceSort: Bool = false) {
        var next = rowOrder
        let didReorder = next.update(displayedSnapshot, sortOrder: sortOrder, forceSort: forceSort)
        withAnimation(didReorder && !reduceMotion ? .easeInOut(duration: 0.3) : nil) {
            rowOrder = next
        }
    }

    private func nameCell(_ item: StorageExplorerItem) -> some View {
        HStack(spacing: 8) {
            StorageItemIcon(item: item, size: 16)

            Text(item.name)
                .lineLimit(1)

            if item.isHidden {
                Image(systemName: "eye.slash")
                    .foregroundStyle(.tertiary)
                    .help("This item is hidden in Finder.")
            }

            if item.cloudState != .none {
                Image(systemName: item.cloudState.symbol)
                    .foregroundStyle(.secondary)
                    .help(item.cloudState.explanation)
            }

            if item.kind == .symbolicLink {
                Image(systemName: "info.circle")
                    .foregroundStyle(.tertiary)
                    .help("Moppo measures the link itself. Its target is not included.")
            }

            if let reason = item.protectionReason {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help(protectionDescription(reason))
            }
        }
    }

    private func firstItem(in selection: Set<StorageExplorerItem.ID>) -> StorageExplorerItem? {
        model.snapshot?.items.first { selection.contains($0.id) }
    }

    private func urls(in selection: Set<StorageExplorerItem.ID>) -> [URL] {
        model.snapshot?.items.compactMap { selection.contains($0.id) ? $0.url : nil } ?? []
    }

    private var locationMenu: some View {
        Menu {
            Button {
                model.selectHome()
            } label: {
                Label("Home Folder", systemImage: "house")
            }

            if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                Button {
                    model.selectLocation(downloads)
                } label: {
                    Label("Downloads", systemImage: "arrow.down.circle")
                }
            }

            if let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                Button {
                    model.selectLocation(documents)
                } label: {
                    Label("Documents", systemImage: "doc")
                }
            }

            if !model.locations.isEmpty { Divider() }
            ForEach(model.locations) { location in
                Button {
                    model.selectLocation(location.url)
                } label: {
                    Label(location.name, systemImage: location.symbol)
                }
            }

            Divider()
            Button {
                model.chooseFolder()
            } label: {
                Label("Choose Folder…", systemImage: "folder.badge.plus")
            }
        } label: {
            HStack(spacing: 7) {
                Label("Choose Location", systemImage: "folder")
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .disabled(isMeasurementBlocked || model.isLoading)
    }

    private func errorDescription(_ error: StorageExplorerError) -> String {
        switch error {
        case .unavailable:
            "Moppo cannot access this folder. Check its permissions and try again."
        case .notDirectory:
            "Choose a folder or mounted volume."
        }
    }

    private func protectionDescription(
        _ reason: StorageExplorerItem.ProtectionReason
    ) -> String {
        switch reason {
        case .excluded:
            "This item contains an excluded path."
        case .protectedContents:
            "This item contains protected data."
        case .unreadableContents:
            "Moppo could not read all contents."
        case .system:
            "Moppo protects this system location."
        case .library:
            "Library folders belong to the Scanner. Use Scanner to remove caches, logs and app data."
        case .trash:
            "This is the Trash. Use the Trash view to empty it or put items back."
        case .application:
            "Use App Uninstaller to remove this application."
        case .mediaLibrary:
            "Photos, Music or TV manages this library. Remove items in that app."
        case .volume:
            "Moppo measures this volume separately. Use macOS tools to eject or erase it."
        case .cloudOnly:
            "This item contains iCloud files that are not on this Mac. Moppo protects them from removal."
        case .unavailable:
            "Moppo cannot verify this item."
        }
    }
}

private extension StorageExplorerItem.CloudState {
    var explanation: String {
        switch self {
        case .none:
            ""
        case .downloaded:
            "This item is stored on this Mac and in iCloud. Moving it to the Trash removes it from other devices."
        case .cloudOnly:
            "This iCloud item is not stored on this Mac."
        case .containsCloudOnlyItems:
            "This item contains iCloud files that are not stored on this Mac."
        }
    }

    var symbol: String {
        switch self {
        case .none, .downloaded:
            "icloud"
        case .cloudOnly, .containsCloudOnlyItems:
            "icloud.and.arrow.down"
        }
    }
}

/// Keeps rows in place while their measured sizes increase.
struct StorageExplorerRowOrder {
    private(set) var directory: URL?
    private var ids: [StorageExplorerItem.ID] = []

    /// Returns true when existing rows change order within the same folder.
    mutating func update(
        _ snapshot: StorageExplorerSnapshot?,
        sortOrder: [KeyPathComparator<StorageExplorerItem>],
        forceSort: Bool = false
    ) -> Bool {
        let sameDirectory = directory != nil && directory == snapshot?.directory
        guard !sameDirectory || snapshot?.isComplete != false || forceSort else { return false }
        let previousIDs = ids
        ids = Self.sorted(snapshot?.items ?? [], using: sortOrder).map(\.id)
        directory = snapshot?.directory
        return sameDirectory && previousIDs != ids && Set(previousIDs) == Set(ids)
    }

    func items(
        in snapshot: StorageExplorerSnapshot?, sortOrder: [KeyPathComparator<StorageExplorerItem>]
    ) -> [StorageExplorerItem] {
        let incoming = snapshot?.items ?? []
        guard directory == snapshot?.directory, !ids.isEmpty else {
            return Self.sorted(incoming, using: sortOrder)
        }
        let byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        let knownIDs = Set(ids)
        return ids.compactMap { byID[$0] }
            + Self.sorted(incoming.filter { !knownIDs.contains($0.id) }, using: sortOrder)
    }

    private static func sorted(
        _ items: [StorageExplorerItem], using sortOrder: [KeyPathComparator<StorageExplorerItem>]
    ) -> [StorageExplorerItem] {
        items.sorted(using: sortOrder + [
            KeyPathComparator(\StorageExplorerItem.name),
            KeyPathComparator(\StorageExplorerItem.id)
        ])
    }
}

/// Shows the cloud explanation in a popover anchored to the icon.
private struct StorageCloudIndicator: View {
    let state: StorageExplorerItem.CloudState
    let onSelect: () -> Void
    let onActivate: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Image(systemName: state.symbol)
                .font(.system(size: 11))
                .foregroundStyle(isHovered ? Token.Text.secondary : Token.Text.tertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onActivate() })
        .onHover { isHovered = $0 }
        .popover(isPresented: $isHovered, arrowEdge: .top) {
            Text(state.explanation)
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(width: 280)
                .presentationBackground(Token.chrome)
        }
        .accessibilityHidden(true)
    }
}

private enum StorageExplorerPresentation: String, CaseIterable, Identifiable {
    case list = "List"
    case map = "Map"

    var id: Self { self }
}

private struct StorageItemIcon: View {
    let item: StorageExplorerItem
    let size: CGFloat

    var body: some View {
        FileKindIcon(
            url: item.url,
            isDirectory: item.kind == .folder,
            usesFileType: item.kind == .file || item.kind == .package,
            size: size
        )
    }
}

/// Shows the current Storage Explorer level as proportional tiles.
private struct StorageTreemapView: View {
    let items: [StorageExplorerItem]
    @Binding var selection: Set<StorageExplorerItem.ID>
    let isMeasuring: Bool
    let isNavigationDisabled: Bool
    let onOpen: (StorageExplorerItem) -> Void
    let onPreview: (StorageExplorerItem) -> Void

    @State private var hoveredID: StorageExplorerItem.ID?
    @State private var hoverPoint: CGPoint?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let tileGap: CGFloat = 8
    private var outerPadding: CGFloat { Token.Size.pageGutter - tileGap / 2 }

    @ViewBuilder
    var body: some View {
        if isMeasuring || items.contains(where: { $0.allocatedBytes > 0 }) {
            GeometryReader { proxy in
                let cells = StorageTreemapLayout.cells(for: items.map {
                    .init(id: $0.id, bytes: $0.allocatedBytes)
                })
                let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

                ZStack(alignment: .topLeading) {
                    Token.pageBackground

                    ForEach(cells) { cell in
                        if let item = itemsByID[cell.id] {
                            let frame = tileFrame(cell, in: proxy.size)
                            tile(item, frame: frame)
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
                .coordinateSpace(name: "StorageExplorerTreemap")
                .overlay(alignment: .topLeading) {
                    tooltip(itemsByID: itemsByID)
                }
                .overlay(alignment: .bottomLeading) {
                    if !isMeasuring { zeroSizeNote }
                }
            }
        } else {
            PageState(
                title: "No allocated space to map", symbol: "square.grid.3x3",
                detail: "Switch to List to see items that use 0 B."
            )
        }
    }

    private func tile(_ item: StorageExplorerItem, frame: CGRect) -> some View {
        let gap = min(tileGap, min(frame.width, frame.height) * 0.12)
        let size = CGSize(width: max(0, frame.width - gap), height: max(0, frame.height - gap))
        let isSelected = selection.contains(item.id)
        let isHovered = hoveredID == item.id
        let isFullCard = size.width >= 150 && size.height >= 138
        let shape = RoundedRectangle(
            cornerRadius: min(Token.Radius.card, min(size.width, size.height) / 4),
            style: .continuous
        )

        return Button {
            select(item)
        } label: {
            ZStack {
                shape.fill(isSelected ? Token.color(.accent).opacity(0.10) : Token.Fill.box)
                if isHovered {
                    shape.fill(Token.Fill.controlHover.opacity(0.5))
                }
                if size.width >= 54, size.height >= 30 {
                    tileLabel(item, size: size)
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(CardPressButtonStyle(
            cornerRadius: min(Token.Radius.card, min(size.width, size.height) / 4)
        ))
        .simultaneousGesture(
            TapGesture(count: 2).onEnded { activate(item) }
        )
        .accessibilityLabel(item.name)
        .accessibilityValue(accessibilityValue(item))
        .accessibilityHint(
            item.opensAsDirectory
                ? "Double-click to open this folder."
                : "Double-click to preview this file."
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: item.opensAsDirectory ? "Open" : "Quick Look") {
            activate(item)
        }
        .overlay(alignment: .topLeading) {
            if isFullCard {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(isSelected ? Token.color(.accent) : Token.Text.disabled)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    if !item.isRemovable {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    if item.cloudState != .none {
                        StorageCloudIndicator(
                            state: item.cloudState,
                            onSelect: { select(item) },
                            onActivate: { activate(item) }
                        )
                    }
                }
                .foregroundStyle(Token.Text.tertiary)
                .padding(10)
            }
        }
        .overlay {
            shape.strokeBorder(
                isSelected ? Token.color(.accent) : Token.Fill.boxBorder,
                lineWidth: isSelected ? 1.5 : Token.hairline
            )
            .allowsHitTesting(false)
        }
        .overlay(alignment: .topTrailing) {
            if isFullCard {
                Button { activate(item) } label: {
                    Image(systemName: item.opensAsDirectory ? "chevron.right" : "eye")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Token.Text.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(item.opensAsDirectory && isNavigationDisabled)
                .padding(5)
                .help(item.opensAsDirectory ? "Open this folder" : "Preview this file")
                .accessibilityLabel("\(item.opensAsDirectory ? "Open" : "Preview") \(item.name)")
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isSelected)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovered)
        .padding(gap / 2)
        .onContinuousHover(coordinateSpace: .named("StorageExplorerTreemap")) { phase in
            switch phase {
            case let .active(location):
                hoveredID = item.id
                hoverPoint = needsTooltip(item, size: size) ? location : nil
            case .ended:
                if hoveredID == item.id {
                    hoveredID = nil
                    hoverPoint = nil
                }
            }
        }
        .onChange(of: size) { _, updatedSize in
            if hoveredID == item.id, !needsTooltip(item, size: updatedSize) {
                hoverPoint = nil
            }
        }
        .contextMenu {
            if item.opensAsDirectory {
                Button("Open") { open(item) }
                    .disabled(isNavigationDisabled)
            }
            Button("Quick Look") { onPreview(item) }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
        }
    }

    @ViewBuilder
    private func tileLabel(_ item: StorageExplorerItem, size: CGSize) -> some View {
        if size.width >= 110, size.height >= 110 {
            let iconSize: CGFloat = size.width >= 150 && size.height >= 138 ? 48 : 32
            VStack(spacing: 6) {
                StorageItemIcon(item: item, size: iconSize)
                    .padding(.bottom, 2)
                Text(item.name)
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                Text(ByteFormatting.string(item.allocatedBytes))
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.top, size.height >= 138 ? 12 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    if size.width >= 100 {
                        StorageItemIcon(item: item, size: 16)
                    }
                    Text(item.name)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if size.height >= 58 {
                    Text(ByteFormatting.string(item.allocatedBytes))
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// Match the label width, font, and line count before showing extra information.
    private func needsTooltip(_ item: StorageExplorerItem, size: CGSize) -> Bool {
        guard size.width >= 54, size.height >= 58 else { return true }
        let isCentered = size.width >= 110 && size.height >= 110
        let width = max(0, size.width - (isCentered ? 24 : 16))
        let nameWidth = max(0, width - (!isCentered && size.width >= 100 ? 23 : 0))
        let nameFont = NSFont.systemFont(ofSize: 13, weight: .medium)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        let name = item.name as NSString
        let value = ByteFormatting.string(item.allocatedBytes) as NSString
        if value.size(withAttributes: [.font: valueFont]).width > width { return true }
        if !isCentered {
            return name.size(withAttributes: [.font: nameFont]).width > nameWidth
        }
        let nameBounds = name.boundingRect(
            with: CGSize(width: nameWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: nameFont]
        )
        let lineHeight = NSLayoutManager().defaultLineHeight(for: nameFont)
        return ceil(nameBounds.height) > ceil(lineHeight * 2)
    }

    @ViewBuilder
    private func tooltip(
        itemsByID: [String: StorageExplorerItem]
    ) -> some View {
        if let hoveredID,
           let item = itemsByID[hoveredID],
           let hoverPoint {
            TreemapTooltipLayout(anchor: hoverPoint) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                    Text(treemapDetail(item))
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                }
                .frame(maxWidth: 320, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: Token.Radius.control)
                        .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
                }
                .shadow(color: Token.chipShadow, radius: 8, y: 2)
                .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder
    private var zeroSizeNote: some View {
        let count = items.filter { $0.allocatedBytes <= 0 }.count
        if count > 0 {
            let noun = count == 1 ? "item" : "items"
            let verb = count == 1 ? "is" : "are"
            Text("\(count) \(noun) using 0 B \(verb) not shown.")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(Token.Fill.box, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
                }
                .padding(Token.Size.pageGutter)
        }
    }

    private func tileFrame(
        _ cell: StorageTreemapLayout.Cell,
        in size: CGSize
    ) -> CGRect {
        let width = max(0, size.width - outerPadding * 2)
        let height = max(0, size.height - outerPadding * 2)
        return CGRect(
            x: outerPadding + width * cell.x,
            y: outerPadding + height * cell.y,
            width: width * cell.width,
            height: height * cell.height
        )
    }

    private func select(_ item: StorageExplorerItem) {
        if NSEvent.modifierFlags.contains(.command) {
            if selection.contains(item.id) { selection.remove(item.id) }
            else { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
    }

    private func activate(_ item: StorageExplorerItem) {
        if item.opensAsDirectory { open(item) }
        else { onPreview(item) }
    }

    private func open(_ item: StorageExplorerItem) {
        guard !isNavigationDisabled else { return }
        onOpen(item)
    }

    private func treemapDetail(_ item: StorageExplorerItem) -> String {
        let protection = item.protectionReason.map { " · " + protectionTitle($0) } ?? ""
        return "\(ByteFormatting.string(item.allocatedBytes)) · \(item.kindTitle)" + protection
    }

    private func protectionTitle(
        _ reason: StorageExplorerItem.ProtectionReason
    ) -> String {
        switch reason {
        case .excluded:           "Excluded"
        case .protectedContents:  "Contains protected data"
        case .unreadableContents: "Unreadable contents"
        case .system:             "System location"
        case .library:            "Use Scanner"
        case .trash:              "Use Trash"
        case .application:        "Use App Uninstaller"
        case .mediaLibrary:       "Managed media library"
        case .volume:             "Mounted volume"
        case .cloudOnly:          "Cloud-only contents"
        case .unavailable:        "Unavailable"
        }
    }

    private func accessibilityValue(_ item: StorageExplorerItem) -> String {
        let protection = item.isRemovable ? "" : ", protected"
        let cloud = item.cloudState == .none ? "" : ". " + item.cloudState.explanation
        return "\(ByteFormatting.string(item.allocatedBytes)), \(item.kindTitle)" + protection + cloud
    }
}

private struct TreemapTooltipLayout: Layout {
    let anchor: CGPoint

    private let margin: CGFloat = 8
    private let spacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let tooltip = subviews.first else { return }
        let size = tooltip.sizeThatFits(.unspecified)
        let anchorInBounds = CGPoint(
            x: bounds.minX + anchor.x,
            y: bounds.minY + anchor.y
        )
        let minimumX = bounds.minX + margin
        let maximumX = max(minimumX, bounds.maxX - size.width - margin)
        let right = anchorInBounds.x + spacing
        let left = anchorInBounds.x - size.width - spacing
        let x = right <= maximumX ? right : max(left, minimumX)

        let minimumY = bounds.minY + margin
        let maximumY = max(minimumY, bounds.maxY - size.height - margin)
        let below = anchorInBounds.y + spacing
        let above = anchorInBounds.y - size.height - spacing
        let y = below <= maximumY ? below : max(above, minimumY)

        tooltip.place(
            at: CGPoint(x: x, y: y),
            anchor: .topLeading,
            proposal: ProposedViewSize(size)
        )
    }
}

extension StorageExplorerItem {
    var kindTitle: String {
        switch kind {
        case .file:         "File"
        case .folder:       "Folder"
        // A symbolic link, which Finder shows as one; an alias is a different thing.
        case .symbolicLink: "Symbolic link"
        case .package:      "Package"
        case .application:  "Application"
        case .volume:       "Volume"
        }
    }

    var kindSortName: String { kindTitle }
    var fileCountLabel: String {
        switch kind {
        case .file, .symbolicLink:
            "—"
        case .folder, .package, .application, .volume:
            fileCount.formatted()
        }
    }
    var modificationSortValue: TimeInterval {
        modificationDate?.timeIntervalSinceReferenceDate ?? -.greatestFiniteMagnitude
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
