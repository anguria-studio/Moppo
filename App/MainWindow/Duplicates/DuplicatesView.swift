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
                    ) {
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { model.duplicateKind = kind }
                    }
                }
                if (model.duplicateKind == .photos && model.photoDuplicates.libraryAccess?.canSweep == true && model.photoDuplicates.unavailableReason == nil)
                    || (model.duplicateKind == .files && model.fileDuplicates.results != nil) {
                    Rectangle()
                        .fill(Token.Fill.controlBorder)
                        .frame(width: Token.hairline, height: 22)
                        .padding(.horizontal, 8)
                    if model.duplicateKind == .photos {
                        PhotoSimilarityPicker(model: model.photoDuplicates)
                            .disabled(model.photoDuplicates.isRequestingAccess)
                    } else {
                        FileDuplicateMinimumPicker(model: model.fileDuplicates)
                    }
                }
                Spacer(minLength: 0)
                if model.duplicateKind == .files, model.fileDuplicates.results != nil {
                    Button("Choose Other Folders", systemImage: "folder") { model.fileDuplicates.chooseFolders() }
                        .buttonStyle(PageActionButtonStyle(size: .small))
                        .disabled(model.isBusyWithDisk)
                }
            }
            .disabled(model.activity != nil || model.photoDuplicates.isDeleting || model.removalCompletion?.destination == .duplicates)
            .frame(minHeight: 38)
            .padding(Token.Size.pageGutter)
            Divider()
            Group {
                switch model.duplicateKind {
                case .files: FileDuplicatesView(model: model.fileDuplicates)
                case .photos: PhotoDuplicatesView(model: model.photoDuplicates)
                }
            }
            // Replace the whole tab so shared page states cannot retain text from the previous tab.
            .id(model.duplicateKind)
            .transition(.identity)
            .allowsHitTesting(model.removalCompletion?.destination != .duplicates)
            .accessibilityHidden(model.removalCompletion?.destination == .duplicates)
            .overlay {
                RemovalOperationSurface(model: model, fadesOnDismiss: true)
            }
        }
    }
}
