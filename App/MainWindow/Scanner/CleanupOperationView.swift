import SwiftUI
import MoppoCore

/// Shows removal progress and keeps the result visible until the user continues.
struct CleanupOperationView: View {
    let itemCount: Int
    let totalBytes: Int64
    var isComplete = false
    var canScan = true
    var onScanAgain: () -> Void = {}
    var onViewDashboard: () -> Void = {}

    var body: some View {
        if isComplete {
            PageCompletionView(title: "Moved to Trash") {
                Text(summary)
            } actions: {
                PageStateActions {
                    Button(action: onScanAgain) {
                        Label("Scan Again", systemImage: "magnifyingglass")
                    }
                    .buttonStyle(PageStateButtonStyle(tint: .white, foreground: .black))
                    .disabled(!canScan)
                    Button("View Dashboard", action: onViewDashboard)
                }
            }
        } else {
            PageProgressView(title: "Moving items to Trash", detail: summary)
        }
    }

    private var summary: String {
        "\(itemCount) \(itemCount == 1 ? "item" : "items") · \(ByteFormatting.string(totalBytes))"
    }
}

/// Shows a removal result without an additional dialog.
struct RemovalCompletionView: View {
    let title: String
    let detail: String
    var isSuccess = true
    var showsActions = true
    var canContinue = true
    let onContinue: () -> Void
    let onViewDashboard: () -> Void

    var body: some View {
        PageCompletionView(title: title, isSuccess: isSuccess) {
            Text(detail)
        } actions: {
            if showsActions {
                PageStateActions {
                    Button("Continue", action: onContinue)
                        .buttonStyle(PageStateButtonStyle(tint: .white, foreground: .black))
                        .disabled(!canContinue)
                    Button("View Dashboard", action: onViewDashboard)
                }
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

#Preview("Moving items") {
    CleanupOperationView(itemCount: 24, totalBytes: 4_620_000_000)
        .background(Token.shell)
        .frame(width: 760, height: 480)
}

#Preview("Cleanup complete") {
    CleanupOperationView(itemCount: 24, totalBytes: 4_620_000_000, isComplete: true)
        .background(Token.shell)
        .frame(width: 760, height: 480)
}
