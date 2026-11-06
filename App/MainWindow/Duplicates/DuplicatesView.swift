import SwiftUI

/// Shows exact file duplicates and similar photos in one review area.
struct DuplicatesView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
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

    private var showsOptions: Bool {
        if model.duplicateKind == .files { return model.fileDuplicates.results != nil }
        return model.photoDuplicates.libraryAccess?.canSweep == true && model.photoDuplicates.unavailableReason == nil
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                kindPicker
                if showsOptions {
                    Rectangle()
                        .fill(Token.Fill.controlBorder)
                        .frame(width: Token.hairline, height: 22)
                        .padding(.horizontal, 8)
                    options
                }
                Spacer(minLength: 0)
                chooseFoldersButton
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    kindPicker
                    Spacer(minLength: 0)
                    chooseFoldersButton
                }
                if showsOptions {
                    HStack(spacing: 8) {
                        options
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .disabled(model.activity != nil || model.photoDuplicates.isDeleting || model.removalCompletion?.destination == .duplicates)
        .frame(minHeight: 38)
        .padding(Token.Size.pageGutter)
    }

    private var kindPicker: some View {
        PageSegmentedControl(selection: $model.duplicateKind, segments:
            AppModel.DuplicateKind.allCases.map { kind in
                .init(id: kind, title: kind.title,
                      symbol: kind == .files ? "doc.on.doc" : "photo.on.rectangle")
            }
        )
        .fixedSize()
    }

    @ViewBuilder
    private var options: some View {
        if model.duplicateKind == .photos {
            PhotoSimilarityPicker(model: model.photoDuplicates)
                .disabled(model.photoDuplicates.isRequestingAccess)
        } else {
            FileDuplicateMinimumPicker(model: model.fileDuplicates)
            FileDuplicateKeeperMenu(model: model.fileDuplicates)
        }
    }

    @ViewBuilder
    private var chooseFoldersButton: some View {
        if model.duplicateKind == .files, model.fileDuplicates.results != nil {
            Button("Choose Other Folders", systemImage: "folder") { model.fileDuplicates.chooseFolders() }
                .buttonStyle(PageActionButtonStyle(size: .small))
                .fixedSize()
                .disabled(model.isBusyWithDisk)
        }
    }
}
