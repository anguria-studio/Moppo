import SwiftUI

/// Shares the native progress bar between scans and removal operations.
struct OperationProgressBar: View {
    var progress: Double? = nil

    var body: some View {
        Group {
            if let progress {
                ProgressView(value: progress)
            } else {
                // Create a new indicator so a stopped percentage bar cannot keep its old state.
                ProgressView()
            }
        }
        .progressViewStyle(.linear)
        .tint(Token.Text.primary)
    }
}
