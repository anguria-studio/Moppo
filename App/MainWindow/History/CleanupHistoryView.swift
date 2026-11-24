import SwiftUI
import MoppoCore

/// Shows a record of Moppo removal results.
struct CleanupHistoryView: View {
    @Bindable var model: RecoveryModel
    var findRequest = 0
    @Environment(\.scenePhase) private var scenePhase

    /// Filters the rows and their size total.
    @State private var searchText = ""
    @State private var filter: HistoryFilter = .all

    @State private var selection: CleanupHistoryItem.ID?
    @State private var sortOrder = [KeyPathComparator(\CleanupHistoryItem.timestamp, order: .reverse)]

    var body: some View {
        VStack(spacing: 0) {
            header

            if model.isLoadingCleanupHistory && model.cleanupHistory == nil {
                loadingState
            } else if items.isEmpty {
                emptyState
            } else if visibleItems.isEmpty {
                PageState(
                    title: query.isEmpty ? String(localized: "No matching items") : String(localized: "No Results for “\(query)”"),
                    symbol: query.isEmpty ? filter.symbol : "magnifyingglass",
                    detail: query.isEmpty ? String(localized: "No history items match this filter.") : String(localized: "No history items match this search.")
                )
            } else {
                historyTable
            }
        }
        .task { await model.loadCleanupHistory() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await model.loadCleanupHistory() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            filterMenu
            if let summary = model.cleanupHistory {
                let visible = visibleItems
                let bytes = visible.reduce(Int64(0)) { $0 + $1.bytes }
                Text("\(visible.count) item · \(ByteFormatting.localizedString(bytes))")
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.secondary)
                    .lineLimit(1)
                    .help(summaryText(summary))
            }
            Spacer(minLength: 0)
            Button("Restore Items") { model.requestPutBack(selectedRunItems) }
                .buttonStyle(PageActionButtonStyle(size: .small))
                .disabled(selectedRunItems.isEmpty)
                .help(model.isBusyWithDisk
                      ? String(localized: "Explain why Put Back must wait for the current operation.")
                      : String(localized: "Restore all available items from the selected cleanup or uninstall."))
            FindField(text: $searchText, findRequest: findRequest)
                .frame(width: 180)
                .disabled(items.isEmpty)
        }
        .padding(.horizontal, Token.Size.pageGutter)
        .padding(.top, Token.Size.pageGutter)
        .padding(.bottom, 12)
    }

    private var filterMenu: some View {
        Menu {
            Picker("Result", selection: $filter) {
                ForEach(HistoryFilter.allCases) { choice in
                    Text("\(choice.title) (\(items.filter { choice.includes($0.state) }.count))")
                        .tag(choice)
                        .help(choice.helpText)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 7) {
                Text(filter.title)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PageActionButtonStyle(size: .small))
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Select a history filter")
        .accessibilityLabel("History filter")
        .accessibilityValue(filter.title)
    }

    private var historyTable: some View {
        let putBackWidth = CompactTableActionStyle.minimumColumnWidth(for: String(localized: "Put Back"))
        return CompactTable(
            items: visibleItems,
            selection: tableSelection,
            sortOrder: $sortOrder,
            columns: [
                CompactTableColumn(String(localized: "Item"), width: 280, min: 150, sort: KeyPathComparator(\CleanupHistoryItem.name)) { item, selected in
                    CompactTableItem(
                        name: item.name,
                        path: item.originalURL.scheme == "docker" ? "Docker"
                            : FileEntry.abbreviate(item.originalURL.deletingLastPathComponent().path),
                        iconURL: item.trashedURL ?? item.originalURL,
                        isSelected: selected
                    )
                },
                CompactTableColumn(String(localized: "Result"), width: 160, min: 120, max: 200, sort: KeyPathComparator(\CleanupHistoryItem.resultSortRank)) { item, selected in
                    ResultLabel(state: item.state, isSelected: selected, toolCommandResult: item.toolCommandResult)
                },
                CompactTableColumn(String(localized: "Date"), width: 105, min: 95, max: 145, sort: KeyPathComparator(\CleanupHistoryItem.timestamp)) { item, selected in
                    CompactTableDate(date: item.timestamp, isSelected: selected)
                },
                CompactTableColumn(String(localized: "Size"), width: 78, min: 65, max: 100, sort: KeyPathComparator(\CleanupHistoryItem.bytes)) { item, selected in
                    Text(item.bytes > 0 ? ByteFormatting.localizedString(item.bytes) : "—")
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white : Token.Text.tableSize)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                },
                CompactTableColumn("", width: putBackWidth, min: putBackWidth, max: putBackWidth) { item, selected in
                    if let trashItem = item.trashItem {
                        Button("Put Back") { model.requestPutBack([trashItem]) }
                            .buttonStyle(CompactTableActionStyle(isSelected: selected))
                            .help(model.isBusyWithDisk
                                  ? String(localized: "Explain why Put Back must wait for the current operation.")
                                  : String(localized: "Restore this item to its original folder."))
                    }
                }
            ],
            itemName: { $0.name },
            menuActions: { ids in
                guard let item = visibleItems.first(where: { ids.contains($0.id) }) else { return [] }
                var actions: [CompactTableMenuAction] = []
                if let trashItem = item.trashItem {
                    actions.append(CompactTableMenuAction(title: String(localized: "Put Back")) { model.requestPutBack([trashItem]) })
                }
                let runItems = model.restorableItems(inRunOf: item)
                if !runItems.isEmpty {
                    let title = String(localized: "Restore \(runItems.count) Item",
                        bundle: MoppoResources.bundle, locale: MoppoResources.locale)
                    actions.append(CompactTableMenuAction(title: title) {
                        model.requestPutBack(runItems)
                    })
                }
                if item.state == .availableInTrash, item.trashedURL != nil {
                    actions.append(CompactTableMenuAction(title: String(localized: "Show in Trash")) { model.showInTrash(item) })
                }
                return actions
            }
        )
        .tableQuickLook(items: visibleItems, selection: tableSelection, url: { $0.quickLookURL })
        .onChange(of: visibleItems.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
    }

    private var tableSelection: Binding<Set<CleanupHistoryItem.ID>> {
        Binding(get: { Set(selection.map { [$0] } ?? []) }, set: { selection = $0.first })
    }

    private var selectedRunItems: [TrashItem] {
        guard let item = items.first(where: { $0.id == selection }) else { return [] }
        return model.restorableItems(inRunOf: item)
    }

    private var loadingState: some View {
        PageProgressView(title: String(localized: "Reading cleanup history"))
    }

    private var emptyState: some View {
        PageState(
            title: String(localized: "No cleanup history"), symbol: "clock",
            detail: String(localized: "Enable Put Back receipts in Settings to record Trash removals. Tool command results are always recorded.")
        )
    }

    private var items: [CleanupHistoryItem] {
        model.cleanupHistory?.items ?? []
    }

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Name or original folder: "where did that file from Downloads go" is asked by
    /// place as often as by name, and the row shows both.
    private var visibleItems: [CleanupHistoryItem] {
        let matching = items.filter {
            filter.includes($0.state)
                && (query.isEmpty || $0.originalURL.path.localizedCaseInsensitiveContains(query)
                    || $0.name.localizedCaseInsensitiveContains(query))
        }
        return sorted(matching)
    }

    private func sorted(_ items: [CleanupHistoryItem]) -> [CleanupHistoryItem] {
        items.sorted(using: sortOrder + [
            KeyPathComparator(\.timestamp, order: .reverse), KeyPathComparator(\.id)
        ])
    }

    private func summaryText(_ summary: CleanupHistorySummary) -> String {
        var parts = [
            String(localized: "\(summary.removedCount) item removed", bundle: MoppoResources.bundle, locale: MoppoResources.locale),
            String(localized: "Removed size \(ByteFormatting.localizedString(summary.removedBytes))"),
        ]
        // Only when the two figures actually part company. They agree for every
        // ordinary removal, and repeating one number twice would read as a defect;
        // they diverge when APFS was sharing the removed files' blocks with copies
        // that are still on the disk, and then the second number is the true one.
        if summary.freedBytes != summary.removedBytes {
            parts.append(String(localized: "Freed \(ByteFormatting.localizedString(summary.freedBytes))"))
        }
        parts.append(String(localized: "\(summary.availableInTrashCount) available in Trash"))
        if summary.permanentlyRemovedCount > 0 {
            parts.append(String(localized: "\(summary.permanentlyRemovedCount) permanent"))
        }
        if summary.failedCount > 0 {
            parts.append(String(localized: "\(summary.failedCount) failed"))
        }
        return parts.joined(separator: " · ")
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case inTrash = "In Trash"
    case restored = "Restored"
    case failed = "Failed"

    var title: String {
        switch self {
        case .all: String(localized: "All")
        case .inTrash: String(localized: "In Trash")
        case .restored: String(localized: "Restored")
        case .failed: String(localized: "Failed")
        }
    }

    var id: Self { self }

    var symbol: String {
        switch self {
        case .all: "square.grid.2x2"
        case .inTrash: "trash"
        case .restored: "arrow.uturn.backward"
        case .failed: "exclamationmark.circle"
        }
    }

    var helpText: String {
        switch self {
        case .all: String(localized: "All recorded removal results.")
        case .inTrash: String(localized: "Items that are still in the Trash.")
        case .restored: String(localized: "Items that Moppo restored from the Trash to their original locations.")
        case .failed: String(localized: "Items that Moppo could not remove.")
        }
    }

    func includes(_ state: CleanupHistoryState) -> Bool {
        switch self {
        case .all: true
        case .inTrash: state == .availableInTrash || state == .inTrash
        case .restored: state == .restored
        case .failed: state == .failed
        }
    }
}

private extension CleanupHistoryState {
    /// What can still be acted on first, then what went wrong, then the settled
    /// outcomes. Alphabetical by label would put "Available in Trash" and "In Trash"
    /// either side of "Could not remove".
    var sortRank: Int {
        switch self {
        case .availableInTrash:   0
        case .inTrash:            1
        case .failed, .skipped:   2
        case .restored:           3
        case .removedPermanently: 4
        case .noLongerInTrash:    5
        }
    }
}

private extension CleanupHistoryItem {
    var resultSortRank: Int { state.sortRank }

    var quickLookURL: URL? {
        guard originalURL.isFileURL else { return nil }
        switch state {
        case .availableInTrash, .inTrash:
            guard let trashedURL else { return nil }
            if let trashedIdentity, FileIdentity.of(trashedURL) != trashedIdentity { return nil }
            return trashedURL
        case .restored, .failed, .skipped:
            return originalURL
        case .removedPermanently, .noLongerInTrash:
            return nil
        }
    }
}

private struct ResultLabel: View {
    let state: CleanupHistoryState
    let isSelected: Bool
    var toolCommandResult: ToolCommandRemovalResult? = nil

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(isSelected ? Color.white : color)
            .lineLimit(1)
            .help(helpText)
    }

    private var title: String {
        switch state {
        case .availableInTrash: String(localized: "In Trash")
        case .inTrash: String(localized: "In Trash")
        case .restored: String(localized: "Restored")
        case .removedPermanently: String(localized: "Removed permanently")
        case .noLongerInTrash: String(localized: "No longer in Trash")
        case .failed: String(localized: "Could not remove")
        case .skipped: String(localized: "Skipped")
        }
    }

    private var symbol: String {
        switch state {
        case .availableInTrash: "trash"
        case .inTrash: "trash"
        case .restored: "checkmark.circle"
        case .removedPermanently: "trash.slash"
        case .noLongerInTrash: "xmark.circle"
        case .failed: "exclamationmark.triangle"
        case .skipped: "minus.circle"
        }
    }

    private var color: Color {
        switch state {
        case .availableInTrash: Token.Text.tableDetail
        case .failed, .skipped: Token.textColor(.orange)
        case .restored: Token.Text.tableDetail
        case .inTrash, .removedPermanently, .noLongerInTrash: Token.Text.tablePath
        }
    }

    private var helpText: String {
        if let toolCommandResult { return toolCommandResult.command + "\n" + toolCommandResult.localizedSummary }
        return switch state {
        case .availableInTrash:
            String(localized: "The receipt matches this item in the Trash. Use the Trash view to put it back.")
        case .inTrash:
            String(localized: "The Trash path exists, but the receipt cannot prove that it contains the same item.")
        case .restored:
            String(localized: "Moppo put this item back at its original location.")
        case .removedPermanently:
            String(localized: "This item did not move to the Trash, so it cannot be put back.")
        case .noLongerInTrash:
            String(localized: "This receipt no longer matches an item in the Trash.")
        case .failed:
            String(localized: "Moppo did not remove this item.")
        case .skipped:
            String(localized: "Moppo kept this item because removal checks did not pass. Inspect the saved plan outcome for the reason.")
        }
    }
}
