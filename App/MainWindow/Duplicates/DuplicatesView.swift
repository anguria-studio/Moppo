import SwiftUI

/// Shows exact file duplicates and similar photos in one review area.
struct DuplicatesView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(AppModel.DuplicateKind.allCases) { kind in
                    PageTabPill(
                        title: kind.title,
                        symbol: kind == .files ? "doc.on.doc" : "photo.on.rectangle",
                        isSelected: model.duplicateKind == kind
                    ) { model.duplicateKind = kind }
                }
                if (model.duplicateKind == .photos && model.canAccessPhotos && model.photoUnavailable == nil)
                    || (model.duplicateKind == .files && model.fileDuplicateResults != nil) {
                    Rectangle()
                        .fill(Token.Fill.controlBorder)
                        .frame(width: Token.hairline, height: 22)
                        .padding(.horizontal, 8)
                    if model.duplicateKind == .photos {
                        PhotoSimilarityPicker(model: model)
                    } else {
                        FileDuplicateMinimumPicker(model: model)
                    }
                }
                Spacer(minLength: 0)
                if model.duplicateKind == .files, model.fileDuplicateResults != nil {
                    Button("Choose Other Folders") { model.chooseFileDuplicateFolders() }
                        .buttonStyle(PageActionButtonStyle())
                        .disabled(model.isBusyWithDisk)
                }
            }
            .disabled(model.activity != nil || model.isDeletingPhotos || model.removalCompletion?.destination == .duplicates)
            .frame(minHeight: 38)
            .padding(Token.Size.pageGutter)
            Divider()
            Group {
                switch model.duplicateKind {
                case .files: FileDuplicatesView(model: model)
                case .photos: PhotoDuplicatesView(model: model)
                }
            }
            .allowsHitTesting(model.removalCompletion?.destination != .duplicates)
            .accessibilityHidden(model.removalCompletion?.destination == .duplicates)
            .overlay {
                RemovalOperationSurface(model: model, fadesOnDismiss: true)
            }
        }
    }
}

/// Keeps duplicate review messages and actions at the same height.
struct DuplicatePageState<Actions: View>: View {
    let title: String
    let symbol: String
    let detail: String
    var iconColor: Color? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label {
                Text(title)
            } icon: {
                if let iconColor {
                    icon.foregroundStyle(iconColor)
                } else {
                    icon
                }
            }
        } description: {
            Text(detail)
                .frame(minHeight: 100, alignment: .top)
        } actions: {
            actions()
        }
        .pageStateLayout()
    }

    private var icon: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: 44, height: 44)
    }
}

/// Gives duplicate review actions the same width.
struct DuplicatePageActionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .lineLimit(1)
            .frame(width: 104)
            .padding(.horizontal, 8)
    }
}
