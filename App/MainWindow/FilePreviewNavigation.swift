import AppKit
import QuickLookUI

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
