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

/// Explains a blocked action and provides a close button.
struct OperationBlockedToast: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .accessibilityHidden(true)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Token.Text.secondary)
            .accessibilityLabel("Dismiss explanation")
            .help("Dismiss explanation")
        }
        .font(.mcSubtitle)
        .foregroundStyle(Token.Text.primary)
        .padding(14)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Token.Fill.cardContent, in: RoundedRectangle(cornerRadius: Token.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: Token.Radius.card)
                .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
        }
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
        .accessibilityElement(children: .contain)
    }
}
