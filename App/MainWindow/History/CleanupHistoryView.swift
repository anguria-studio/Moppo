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
                    title: query.isEmpty ? "No matching items" : "No Results for “\(query)”",
                    symbol: query.isEmpty ? filter.symbol : "magnifyingglass",
                    detail: query.isEmpty ? "No history items match this filter." : "No history items match this search."
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
                Text("\(visible.count) \(visible.count == 1 ? "item" : "items") · \(ByteFormatting.string(bytes))")
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.secondary)
                    .lineLimit(1)
                    .help(summaryText(summary))
            }
            Spacer(minLength: 0)
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
                    Text("\(choice.rawValue) (\(items.filter { choice.includes($0.state) }.count))")
                        .tag(choice)
                        .help(choice.helpText)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 7) {
                Text(filter.rawValue)
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
        .accessibilityValue(filter.rawValue)
    }

    private var historyTable: some View {
        CompactTable(
            items: visibleItems,
            selection: tableSelection,
            sortOrder: $sortOrder,
            columns: [
                CompactTableColumn("Item", width: 280, min: 150, sort: KeyPathComparator(\CleanupHistoryItem.name)) { item, selected in
                    CompactTableItem(
                        name: item.name,
                        path: item.originalURL.scheme == "docker" ? "Docker"
                            : FileEntry.abbreviate(item.originalURL.deletingLastPathComponent().path),
                        iconURL: item.trashedURL ?? item.originalURL,
                        isSelected: selected
                    )
                },
                CompactTableColumn("Result", width: 160, min: 120, max: 200, sort: KeyPathComparator(\CleanupHistoryItem.resultSortRank)) { item, selected in
                    ResultLabel(state: item.state, isSelected: selected, toolCommandResult: item.toolCommandResult)
                },
                CompactTableColumn("Date", width: 105, min: 95, max: 145, sort: KeyPathComparator(\CleanupHistoryItem.timestamp)) { item, selected in
                    CompactTableDate(date: item.timestamp, isSelected: selected)
                },
                CompactTableColumn("Size", width: 78, min: 65, max: 100, sort: KeyPathComparator(\CleanupHistoryItem.bytes)) { item, selected in
                    Text(item.bytes > 0 ? ByteFormatting.string(item.bytes) : "—")
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white : Token.Text.tableSize)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            ],
            itemName: { $0.name },
            menuActions: { ids in
                guard let item = visibleItems.first(where: { ids.contains($0.id) }),
                      item.state == .availableInTrash, item.trashedURL != nil else { return [] }
                return [CompactTableMenuAction(title: "Show in Trash") { model.showInTrash(item) }]
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

    private var loadingState: some View {
        PageProgressView(title: "Reading cleanup history")
    }

    private var emptyState: some View {
        PageState(
            title: "No cleanup history", symbol: "clock",
            detail: "Enable Put Back receipts in Settings to record Trash removals. Tool command results are always recorded."
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
            "\(summary.removedCount) \(summary.removedCount == 1 ? "item" : "items") removed",
            "Removed size \(ByteFormatting.string(summary.removedBytes))",
        ]
        // Only when the two figures actually part company. They agree for every
        // ordinary removal, and repeating one number twice would read as a defect;
        // they diverge when APFS was sharing the removed files' blocks with copies
        // that are still on the disk, and then the second number is the true one.
        if summary.freedBytes != summary.removedBytes {
            parts.append("Freed \(ByteFormatting.string(summary.freedBytes))")
        }
        parts.append("\(summary.availableInTrashCount) available in Trash")
        if summary.permanentlyRemovedCount > 0 {
            parts.append("\(summary.permanentlyRemovedCount) permanent")
        }
        if summary.failedCount > 0 {
            parts.append("\(summary.failedCount) failed")
        }
        return parts.joined(separator: " · ")
    }
}

private enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case inTrash = "In Trash"
    case restored = "Restored"
    case failed = "Failed"

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
        case .all: "All recorded removal results."
        case .inTrash: "Items that are still in the Trash."
        case .restored: "Items that Moppo restored from the Trash to their original locations."
        case .failed: "Items that Moppo could not remove."
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
        case .failed:             2
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
        case .restored, .failed:
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
        case .availableInTrash: "In Trash"
        case .inTrash: "In Trash"
        case .restored: "Restored"
        case .removedPermanently: "Removed permanently"
        case .noLongerInTrash: "No longer in Trash"
        case .failed: "Could not remove"
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
        }
    }

    private var color: Color {
        switch state {
        case .availableInTrash: Token.Text.tableDetail
        case .failed: Token.textColor(.orange)
        case .restored: Token.Text.tableDetail
        case .inTrash, .removedPermanently, .noLongerInTrash: Token.Text.tablePath
        }
    }

    private var helpText: String {
        if let toolCommandResult { return toolCommandResult.command + "\n" + toolCommandResult.summary }
        return switch state {
        case .availableInTrash:
            "The receipt matches this item in the Trash. Use the Trash view to put it back."
        case .inTrash:
            "The Trash path exists, but the receipt cannot prove that it contains the same item."
        case .restored:
            "Moppo put this item back at its original location."
        case .removedPermanently:
            "This item did not move to the Trash, so it cannot be put back."
        case .noLongerInTrash:
            "This receipt no longer matches an item in the Trash."
        case .failed:
            "Moppo did not remove this item."
        }
    }
}
