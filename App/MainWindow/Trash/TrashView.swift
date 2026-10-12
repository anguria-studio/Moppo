import SwiftUI
import MoppoCore

/// The Trash: what is in it, how much it is holding, and the one destructive button
/// in the app.
///
/// Reading the Trash means measuring every item in it, which is disk work — so it runs
/// from a `.task` rather than on the model's launch path, and the view says it is
/// reading rather than showing an empty box while it does.
struct TrashView: View {
    @Bindable var model: RecoveryModel
    var findRequest = 0
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let summary = model.trashSummary {
                TrashContent(
                    summary: summary,
                    findRequest: findRequest,
                    isBusyWithDisk: model.isBusyWithDisk,
                    selectedItemIDs: $model.selectedTrashItemIDs,
                    onPutBack: { items in Task { await model.putBack(items) } }
                )
            } else if model.hasLoadedTrash {
                unreadableNote
            } else {
                loadingNote
            }
        }
        .operationResultAnimation(isRunning: !model.hasLoadedTrash && model.trashSummary == nil)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await model.loadTrash()
        }
    }

    private var loadingNote: some View {
        PageProgressView(title: "Reading the Trash")
    }

    private var unreadableNote: some View {
        PageState(
            title: "The Trash could not be read", symbol: "trash.slash",
            detail: "This is the same Trash Finder shows, but macOS only lets apps with "
                + "Full Disk Access look inside it. Grant access in System Settings "
                + "and come back."
        ) {
            Button("Open System Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
                NSWorkspace.shared.open(url)
            }
        }
    }
}

// MARK: - Card and list

/// Everything that renders from a loaded summary, split out so the previews can show
/// real states without a Trash on disk.
private struct TrashContent: View {
    let summary: TrashSummary
    /// `AppModel.findRequest`: ⌘F moves the focus to the search field.
    var findRequest = 0
    var isBusyWithDisk = false
    @Binding var selectedItemIDs: Set<TrashItem.ID>
    let onPutBack: ([TrashItem]) -> Void

    /// Narrows the rows and nothing else. The header's size and count stay the whole
    /// Trash's: they are what Empty Trash will remove, whatever is typed here.
    @State private var searchText = ""
    @State private var sortOrder = [TrashItemComparator(key: .date, order: .reverse)]

    private var query: String {
        searchText.trimmingCharacters(in: .whitespaces)
    }

    /// Names only. A trashed item's path is `~/.Trash/<name>` for every row, so
    /// matching it would make "trash" match everything.
    private var visibleItems: [TrashItem] {
        let matching = query.isEmpty ? summary.items : summary.items.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
        return matching.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            summaryHeader
            if summary.items.isEmpty {
                emptyNote
            } else if visibleItems.isEmpty {
                PageState(
                    title: "No Results for “\(query)”", symbol: "magnifyingglass",
                    detail: "No item in the Trash has that in its name."
                )
            } else {
                trashTable
                if summary.itemCount > summary.items.count {
                    Text("Showing \(summary.items.count) of \(summary.itemCount) items. Finder lists them all.")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.tertiary)
                        .padding(8)
                }
            }
        }
        .onChange(of: visibleItems.map(\.id)) { _, ids in
            selectedItemIDs.formIntersection(ids)
        }
    }

    private var trashTable: some View {
        CompactTable(
            items: visibleItems,
            selection: $selectedItemIDs,
            sortOrder: $sortOrder,
            columns: [
                CompactTableColumn("Item", width: 400, min: 200, sort: TrashItemComparator(key: .name)) { item, selected in
                    CompactTableItem(
                        name: item.name,
                        path: item.originalURL.map { FileEntry.abbreviate($0.deletingLastPathComponent().path) }
                            ?? "Original location unknown",
                        iconURL: item.url,
                        isSelected: selected
                    )
                },
                CompactTableColumn("Deleted", width: 105, min: 95, max: 145, sort: TrashItemComparator(key: .date, order: .reverse)) { item, selected in
                    CompactTableDate(date: item.deletedAt, isSelected: selected)
                },
                CompactTableColumn("Size", width: 78, min: 65, max: 100, sort: TrashItemComparator(key: .size, order: .reverse)) { item, selected in
                    Text(ByteFormatting.string(item.bytes))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white : Token.Text.tableSize)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                },
                CompactTableColumn("", width: 80, min: 80, max: 80) { item, selected in
                    if item.canPutBack {
                        Button("Put Back") { onPutBack([item]) }
                            .buttonStyle(CompactTableActionStyle(isSelected: selected))
                            .disabled(isBusyWithDisk)
                            .help("Restore this item to its original folder.")
                    }
                }
            ],
            itemName: { $0.name },
            allowsMultipleSelection: true,
            menuActions: { selectedIDs in
                let selected = visibleItems.filter { selectedIDs.contains($0.id) }
                let restorable = selected.filter(\.canPutBack)
                let title = restorable.isEmpty || restorable.count == selected.count
                    ? "Put Back" : "Put Back \(restorable.count) \(restorable.count == 1 ? "Item" : "Items")"
                return [CompactTableMenuAction(title: title, isEnabled: !isBusyWithDisk && !restorable.isEmpty) {
                    onPutBack(restorable)
                }]
            }
        )
        .tableQuickLook(items: visibleItems, selection: $selectedItemIDs, url: { $0.url })
    }

    // MARK: Summary header

    private var summaryHeader: some View {
        PageHeader {
            summaryFigures
        } trailing: {
            // Disabled over an empty Trash: a field with nothing to search is a
            // control that answers every query with "no results".
            FindField(text: $searchText, findRequest: findRequest)
                .frame(minWidth: 90, idealWidth: 180, maxWidth: 180)
                .disabled(summary.items.isEmpty)
        }
    }

    private var summaryFigures: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(ByteFormatting.string(summary.totalBytes))
                    .animatedTotal(summary.totalBytes)
                    .font(.mcSecondaryHero)
                    .mcTracked(-0.26)   // -0.01em
                    .foregroundStyle(Token.Text.emphasis)
                    .lineLimit(1)

                Text("· \(summary.itemCount) \(summary.itemCount == 1 ? "item" : "items")")
                    .font(.trashItemCount)
                    .foregroundStyle(Token.Text.quaternary)
                    .lineLimit(1)
            }

            Label(
                hasICloudDrive
                    ? "Finder settings control how long items stay. iCloud Recently Deleted is not on this disk."
                    : "Finder settings control how long items stay.",
                systemImage: "info.circle"
            )
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.quaternary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    private var hasICloudDrive: Bool {
        FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/Mobile Documents/com~apple~CloudDocs"
        )
    }

    private var emptyNote: some View {
        PageState(
            title: "The Trash is empty", symbol: "trash",
            detail: "This is the system Trash, the same one Finder shows. Items this "
                + "app moves here record their original location. You can put "
                + "them back."
        )
    }
}

/// 15pt belongs to this card alone, so it is not in the shared ramp — but it carries a
/// figure, so it carries tabular digits.
private extension Font {
    static let trashItemCount = Font.system(size: 15).monospacedDigit()
}

// MARK: - Previews
//
// These render `TrashContent` rather than `TrashView`: the view's `.task` reads the
// real `~/.Trash`, which would replace any fixture the moment the preview appeared.

#Preview("Trash") {
    TrashContent(
        summary: PreviewTrash.populated,
        selectedItemIDs: .constant([]),
        onPutBack: { _ in }
    )
        .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

#Preview("Trash — empty") {
    TrashContent(summary: TrashSummary(), selectedItemIDs: .constant([]), onPutBack: { _ in })
        .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth, height: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}

/// The design's own sample rows. Only the first was trashed by this app, so it is the
/// only one whose Put Back is live — which is the state the real Trash is usually in.
private enum PreviewTrash {
    private static func trash(_ name: String) -> URL {
        URL(filePath: NSHomeDirectory()).appending(path: ".Trash/\(name)")
    }
    private static func daysAgo(_ days: Double) -> Date {
        Date.now.addingTimeInterval(-days * 86_400)
    }

    static let populated = TrashSummary(
        totalBytes: 9_040_162_816,
        itemCount: 214,
        items: [
            TrashItem(
                url: trash("Sketch 2019 Backups"),
                bytes: 4_402_341_478,
                deletedAt: daysAgo(2),
                canPutBack: true
            ),
            TrashItem(
                url: trash("iPhone 12 backup 2023-04-11"),
                bytes: 3_049_205_924,
                deletedAt: daysAgo(5)
            ),
            TrashItem(
                url: trash("Figma-export-final-v7.zip"),
                bytes: 1_034_140_058,
                deletedAt: daysAgo(11)
            ),
            // No date: `.addedToDirectoryDateKey` is missing on some items, and the row
            // simply carries no caption.
            TrashItem(url: trash("Zoom.pkg"), bytes: 536_870_912)
        ]
    )
}
