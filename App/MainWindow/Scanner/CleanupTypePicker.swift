import SwiftUI
import MoppoCore

/// Shows the types found in the current safety view.
struct CleanupTypePicker: View {
    @Bindable var model: CleanupModel

    var body: some View {
        let options = model.dataTypeOptions
        let selected = options.first { $0.type == model.dataTypeFilter }
        Menu {
            Picker("Filter results", selection: $model.dataTypeFilter) {
                ForEach(options) { option in
                    if option.type == .all {
                        Text(option.type.title).tag(option.type)
                    } else {
                        Text("\(option.type.title) · \(option.count) · \(ByteFormatting.string(option.bytes))")
                            .tag(option.type)
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 7) {
                Text(model.dataTypeFilter.title)
                if let selected, selected.type != .all {
                    Text(selected.count.formatted())
                        .foregroundStyle(Token.Text.secondary)
                        .monospacedDigit()
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PageActionButtonStyle(size: .small))
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.isBusyWithDisk)
        .accessibilityLabel("Filter results")
        .accessibilityValue(model.dataTypeFilter == .all ? model.dataTypeFilter.title
            : "\(model.dataTypeFilter.title), \(selected?.count ?? 0) \(selected?.count == 1 ? "item" : "items")")
        .help("Filter items found by this scan.")
    }
}
