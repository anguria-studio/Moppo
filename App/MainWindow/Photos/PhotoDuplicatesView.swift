import AppKit
import Photos
import SwiftUI
import MoppoCore

/// The duplicate review grid.
///
/// The grid is the feature, not a nicety. Bulk-deleting photographs on the strength
/// of a similarity score is only defensible if the user can see what is going and
/// what is being kept, side by side, before anything happens — so every group shows
/// its keeper next to its casualties at the same size, and the keeper is not
/// selectable from here at all.
struct PhotoDuplicatesView: View {
    @Bindable var model: PhotoDuplicatesModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var requiresAuthorization = false
    @State private var animateEmptyResult = false
    @State private var resultBeforeScan: Date?
    private var thumbnails: PhotoThumbnailLoader { model.thumbnails }

    var body: some View {
        Group {
            // Keep known content visible while a repeat access check runs.
            if requiresAuthorization {
                PageState(
                    title: "Allow Photos Access",
                    symbol: "photo",
                    detail: "Allow access to find duplicate and similar photos. This does not start a scan."
                ) {
                    Button("Allow") {
                        Task {
                            await model.requestAccess()
                            requiresAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
                        }
                    }
                    .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
                }
            } else if model.libraryAccess == nil {
                PageProgressView(title: "Checking Photos access")
            } else if let reason = model.libraryAccess?.unavailableReason {
                unavailable(reason, canRetryScan: false)
            } else if model.isScanning {
                sweeping
            } else if let reason = model.unavailableReason {
                unavailable(reason)
            } else if model.results == nil {
                intro
            } else if model.groups.isEmpty {
                nothingFound
            } else {
                groups
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .disabled(model.isDeleting || model.isRequestingAccess)
        .operationResultAnimation(isRunning: model.isScanning)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            requiresAuthorization = PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined
            model.refreshAccess(PhotoKitLibrary.currentAccess)
        }
        .onChange(of: model.isScanning, initial: true) { wasRunning, isRunning in
            if isRunning {
                resultBeforeScan = model.results?.finishedAt
                animateEmptyResult = false
            } else if wasRunning {
                animateEmptyResult = model.results?.finishedAt != nil
                    && model.results?.finishedAt != resultBeforeScan
            }
        }
        .onChange(of: model.similarity) { _, _ in animateEmptyResult = false }
        .onDisappear { animateEmptyResult = false }
    }

    // MARK: - States

    private var intro: some View {
        PageState(
            title: "Find duplicate photos",
            symbol: "photo.on.rectangle.angled",
            detail: "Compares photos by appearance. Scans can download missing previews when photo downloads are enabled in Settings > Advanced. "
                + "Opening a photo preview can download its original."
        ) {
            Button { model.startScan() } label: {
                Text("Find Duplicates")
            }
            .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
            .controlSize(.large)
            .disabled(!model.canAccessPhotos || model.isBusyWithDisk)
        }
    }

    private var sweeping: some View {
        PageProgressView(
            title: "Scanning for duplicate photos",
            detail: "\(progressLabel)\nThis may take a few minutes.",
            progress: Double(model.progress?.percent ?? 0) / 100,
            isInterrupting: model.isInterrupting,
            icon: .mascot(.photoScanning),
            onStop: { model.cancelScan() }
        )
    }

    private var progressLabel: String {
        guard let progress = model.progress else { return "Preparing…" }
        return switch progress.stage {
        case .fetching:      "Reading your photo library…"
        case .grouping:      "Grouping bursts…"
        case .comparing:     "Comparing \(progress.total.formatted()) photos to each other…"
        case .fingerprinting:
            "Comparing photos — \(progress.completed.formatted()) of \(progress.total.formatted())"
        case .finishing, .done: "Finishing…"
        }
    }

    private func unavailable(_ reason: String, canRetryScan: Bool = true) -> some View {
        PageState(
            title: canRetryScan ? "Photos are unavailable" : "Allow Photos access",
            symbol: "exclamationmark.triangle",
            detail: reason,
            iconColor: Token.textColor(.orange)
        ) {
            Button {
                if canRetryScan {
                    model.startScan()
                } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Text(canRetryScan ? "Try Again" : "Open Settings")
            }
            .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
            .controlSize(.large)
            .disabled(canRetryScan && (!model.canAccessPhotos || model.isBusyWithDisk))
        }
    }

    private var nothingFound: some View {
        ScanCompletionView(
            title: "No duplicate photos found",
            detail: model.results.map { summary($0) },
            animate: animateEmptyResult
        )
    }

    /// A skipped photo was never compared, so the result is a floor rather than a
    /// total. Saying so is the same rule the scanners follow with `unreadableCount`.
    private func summary(_ results: PhotoDuplicateResults) -> String {
        var text = "Compared \(results.examinedCount.formatted()) photos."
        if results.skippedCount > 0 {
            text += " \(results.skippedCount.formatted()) had no thumbnail available "
                + "and were not compared."
        }
        return text
    }

    private var groups: some View {
        let selectable = Set(model.groups.flatMap(\.removable).map(\.id))
        return VStack(spacing: 0) {
            HStack {
                SelectionCheckbox(
                    title: "Select All",
                    detail: "\(selectable.count) items",
                    state: !selectable.isEmpty && selectable.isSubset(of: model.selection) ? .on : .off,
                    isEnabled: !selectable.isEmpty && !model.isBusyWithDisk && !model.isRegrouping
                ) { isOn in
                    if isOn { model.selectAll() }
                    else { model.deselectAll() }
                }
                .fixedSize()
                Spacer()
                if let results = model.results, results.skippedCount > 0 {
                    Text(summary(results)).pageHeaderSummary()
                }
            }
            .padding(.horizontal, Token.Size.pageGutter + 15)
            .padding(.top, 18)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.groups) { group in
                        groupCard(group)
                    }
                }
                .padding(.horizontal, Token.Size.pageGutter)
                .padding(.vertical, 14)
            }
        }
    }

    private func groupCard(_ group: DuplicateGroup) -> some View {
        GroupedBox {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Badge(text: kindLabel(group.kind), style: group.kind == .similar ? .neutral : .safe)
                        // The badge names how the group was decided, not how sure
                        // Moppo is — a "Looks similar" group at 0.03 is the same
                        // photograph twice, and reads as a guess without this.
                        .help(badgeExplanation(group.kind))
                    // The number the threshold was compared against, on the groups
                    // a number decided. Without it "Looks similar" is the same
                    // sentence whether the match was tight or barely made, and the
                    // similarity setting is a dial with no readout.
                    if let distance = group.maximumDistance {
                        Text(String(format: "%.2f", distance))
                            .font(.mcCaption.monospacedDigit())
                            .foregroundStyle(Token.Text.tertiary)
                            .help("How far apart the two least alike photographs here are. "
                                  + "Lower is more alike; zero is the same image. "
                                  + "This group was formed at \(model.similarity.thresholdLabel) "
                                  + "or closer.")
                    }
                    Text("\(group.count) copies · keeping 1")
                        .font(.mcRowTitle)
                        .foregroundStyle(Token.Text.primary)
                    Text("(\(group.keeperReason.label))")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                    if let date = group.keeper.creationDate {
                        Text(date, format: .dateTime.day().month().year())
                            .font(.mcSubtitle)
                            .foregroundStyle(Token.Text.tertiary)
                    }
                    Spacer()
                    Button(model.isGroupSelected(group.id) ? "Deselect" : "Select \(group.removable.count)") {
                        model.toggleGroup(group.id)
                    }
                    .buttonStyle(SecondaryButtonStyle(fill: Token.Fill.buttonOnTint))
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 10)
                .background {
                    UnevenRoundedRectangle(
                        topLeadingRadius: Token.Radius.box,
                        bottomLeadingRadius: 0,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: Token.Radius.box
                    )
                    .fill(Token.Fill.duplicateGroupHeader)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(group.assets) { asset in
                            tile(asset, in: group)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
        }
    }

    private func badgeExplanation(_ kind: DuplicateGroup.Kind) -> String {
        switch kind {
        case .burst:
            "Photos itself recorded these as one burst."
        case .exact:
            "Same capture time, size and kind, and the pictures agree. "
                + "Moppo is as sure of this as it gets."
        case .similar:
            "Grouped because the pictures look alike, at the setting in the header — "
                + "the number beside this says how alike. A tight one is often the same "
                + "photograph re-saved, which misses Identical only because its capture "
                + "time or size changed. Choose Identical only to be shown none of these."
        }
    }

    private func kindLabel(_ kind: DuplicateGroup.Kind) -> String {
        switch kind {
        case .burst:   "Burst"
        case .exact:   "Identical"
        // Named for what it is. The certain tiers are visually confirmed matches;
        // this one is a judgement call, and the badge should not imply otherwise.
        case .similar: "Looks similar"
        }
    }

    private func tile(_ asset: PhotoAsset, in group: DuplicateGroup) -> some View {
        let isKeeper = asset.id == group.keeper.id
        let selected = model.selection.contains(asset.id)

        return VStack(spacing: 5) {
            thumbnail(asset)
                .overlay {
                    RoundedRectangle(cornerRadius: Token.Radius.well, style: .continuous)
                        .strokeBorder(
                            isKeeper ? Token.color(.green).opacity(0.7)
                                : (selected ? Token.color(.red) : Token.Fill.boxBorder),
                            lineWidth: isKeeper || selected ? 2 : 1
                        )
                        .allowsHitTesting(false)
                }
            Text(isKeeper ? "Keep" : (selected ? "Delete" : "Keeping"))
                .font(.mcBadge)
                .foregroundStyle(
                    isKeeper ? Token.textColor(.green)
                        : (selected ? Token.textColor(.red) : Token.Text.tertiary)
                )
        }
        .contentShape(Rectangle())
        .overlay {
            PhotoThumbnailClickTarget(
                isSelected: Binding(
                    get: { model.selection.contains(asset.id) },
                    set: { isSelected in
                        guard !isKeeper else { return }
                        model.setSelected(isSelected, assetID: asset.id)
                    }
                ),
                isSelectable: !isKeeper,
                onPreview: { model.preview = PhotoDuplicatesModel.Preview(groupID: group.id, asset: asset) }
            )
        }
        .help(isKeeper ? "Double-click to preview" : "Click to select. Double-click to preview.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isKeeper ? "Photo to keep" : "Photo")
        .accessibilityValue(selected ? "Selected for deletion" : "Not selected for deletion")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if !isKeeper { model.toggle(asset.id) }
        }
        .accessibilityAction(named: Text("Preview photo")) {
            model.preview = PhotoDuplicatesModel.Preview(groupID: group.id, asset: asset)
        }
        .overlay(alignment: .top) {
            if !isKeeper {
                HStack(spacing: 4) {
                    Button {
                        model.keepInstead(groupID: group.id, assetID: asset.id)
                    } label: {
                        Text("Keep")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .frame(height: 24)
                            .background(Color.black.opacity(0.65), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Keep this photo instead")
                    .help("Choose this photo as the copy to keep")
                    Spacer(minLength: 0)
                    Button {
                        model.toggle(asset.id)
                    } label: {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                selected ? Color.white : Color.white.opacity(0.9),
                                selected ? Token.color(.red) : Color.black.opacity(0.35)
                            )
                            .frame(width: 24, height: 24)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selected ? "Deselect photo" : "Select photo for deletion")
                    .help(selected ? "Deselect photo" : "Select photo for deletion")
                }
                .padding(5)
            }
        }
        .contextMenu {
            if !isKeeper {
                Button("Keep This One Instead") {
                    model.keepInstead(groupID: group.id, assetID: asset.id)
                }
            }
            Button("Open") { model.preview = PhotoDuplicatesModel.Preview(groupID: group.id, asset: asset) }
        }
    }

    private func thumbnail(_ asset: PhotoAsset) -> some View {
        Group {
            if let image = thumbnails.image(for: asset.id) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Token.Fill.well
            }
        }
        .frame(width: 108, height: 108)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.well, style: .continuous))
        .task { thumbnails.load(asset.id) }
    }
}

/// Selects immediately and restores the prior selection when a double-click opens the preview.
private struct PhotoThumbnailClickTarget: NSViewRepresentable {
    @Binding var isSelected: Bool
    let isSelectable: Bool
    let onPreview: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.allowsSelection = isSelectable
        nsView.selection = $isSelected
        nsView.onPreview = onPreview
    }

    final class ClickView: NSView {
        var isEnabled = true
        var allowsSelection = true
        var selection: Binding<Bool>?
        var onPreview: (() -> Void)?
        private var selectionBeforeClick: Bool?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if event.clickCount == 1 {
                selectionBeforeClick = selection?.wrappedValue
                if allowsSelection, let selection {
                    selection.wrappedValue.toggle()
                }
            } else if event.clickCount == 2 {
                if allowsSelection, let selectionBeforeClick {
                    selection?.wrappedValue = selectionBeforeClick
                }
                selectionBeforeClick = nil
                onPreview?()
            }
        }
    }
}

/// Changes photo matching without another scan.
struct PhotoSimilarityPicker: View {
    @Bindable var model: PhotoDuplicatesModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isRegrouping {
                ProgressView().controlSize(.small)
            }
            Text("Match")
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.secondary)
            Menu {
                Picker("Match", selection: $model.similarity) {
                    ForEach(PhotoSimilarity.allCases) { similarity in
                        Text(similarityLabel(similarity)).tag(similarity)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 7) {
                    Text(similarityLabel(model.similarity))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .menuStyle(.button)
            .buttonStyle(PageActionButtonStyle())
            .menuIndicator(.hidden)
            .accessibilityLabel("Match")
            .accessibilityValue(similarityLabel(model.similarity))
            .fixedSize()
            .disabled(model.isBusyWithDisk)
            .help(model.similarity.detail
                  + " Bursts and identical copies are unaffected — neither is decided "
                  + "by this number.")
        }
    }

    private func similarityLabel(_ similarity: PhotoSimilarity) -> String {
        similarity.thresholdLabel.isEmpty
            ? similarity.title
            : "\(similarity.title) · \(similarity.thresholdLabel)"
    }

}
