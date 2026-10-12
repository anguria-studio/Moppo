import AppKit
import QuickLookUI
import QuickLook
import SwiftUI

extension View {
    func tableQuickLook<Item: Identifiable>(
        items: [Item], selection: Binding<Set<Item.ID>>, url: @escaping (Item) -> URL?
    ) -> some View {
        modifier(TableQuickLook(items: items, selection: selection, url: url))
    }
}

private struct TableQuickLook<Item: Identifiable>: ViewModifier {
    let items: [Item]
    @Binding var selection: Set<Item.ID>
    let url: (Item) -> URL?
    @State private var previewURL: URL?
    @State private var previewedID: Item.ID?
    @State private var navigation = FilePreviewNavigation()

    func body(content: Content) -> some View {
        content
            .quickLookPreview($previewURL)
            .background {
                Button("Quick Look") {
                    if previewURL != nil { previewURL = nil }
                    else { showSelection() }
                }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(selection.isEmpty)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
            }
            .onChange(of: selection) { _, ids in
                guard previewURL != nil else { return }
                if let previewedID, ids.contains(previewedID) { return }
                showSelection()
            }
            .onChange(of: items.map(\.id)) { _, _ in
                guard previewURL != nil else { return }
                showSelection()
            }
            .onChange(of: previewURL) { _, value in
                if value == nil {
                    navigation.stop()
                    previewedID = nil
                }
            }
            .onDisappear {
                navigation.stop()
                previewURL = nil
                previewedID = nil
            }
    }

    private func showSelection() {
        for item in items where selection.contains(item.id) {
            guard let candidate = availableURL(item) else { continue }
            navigation.start(onClose: { previewURL = nil }) { move($0) }
            previewedID = item.id
            previewURL = candidate
            return
        }
        previewURL = nil
    }

    private func move(_ direction: Int) {
        guard let index = items.firstIndex(where: { $0.id == previewedID }) else { return }
        var next = index + direction
        while items.indices.contains(next) {
            let item = items[next]
            if let candidate = availableURL(item) {
                previewedID = item.id
                selection = [item.id]
                previewURL = candidate
                navigation.scrollToRow(next)
                return
            }
            next += direction
        }
    }

    private func availableURL(_ item: Item) -> URL? {
        guard let candidate = url(item), FileManager.default.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}

/// Keeps native Quick Look navigation aligned with the source list.
@MainActor
final class FilePreviewNavigation {
    private var keyMonitor: Any?
    private weak var sourceTable: NSTableView?

    func start(onClose: (@MainActor () -> Void)? = nil, onMove: @escaping @MainActor (Int) -> Void) {
        if let table = NSApp.keyWindow?.firstResponder as? NSTableView {
            sourceTable = table
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard event.window is QLPreviewPanel,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
                else { return false }
                // Read-only text previews must still allow navigation between files.
                if let textView = event.window?.firstResponder as? NSTextView,
                   textView.isEditable || textView.isFieldEditor {
                    return false
                }
                switch event.keyCode {
                case 125: onMove(1)
                case 126: onMove(-1)
                case 49, 53:
                    guard let onClose else { return false }
                    onClose()
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    func scrollToRow(_ index: Int) {
        guard let sourceTable, index >= 0, index < sourceTable.numberOfRows else { return }
        sourceTable.scrollRowToVisible(index)
    }

    func stop() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        sourceTable = nil
    }
}
