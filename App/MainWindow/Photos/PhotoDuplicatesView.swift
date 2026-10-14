import AppKit
import SwiftUI
import MoppoCore

/// Reviews photos with separate highlight, selection, and keeper states.
struct PhotoDuplicatesView: View {
    @Bindable var model: PhotoDuplicatesModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsAccessRecovery = false
    @State private var animateEmptyResult = false
    @State private var resultBeforeScan: Date?
    @State private var review = PhotoReviewState()
    @FocusState private var gridIsFocused: Bool
    @FocusState private var actionIsFocused: Bool
    private var thumbnails: PhotoThumbnailLoader { model.thumbnails }

    var body: some View {
        Group {
            if model.libraryAccess == .notDetermined {
                PageState(
                    title: "Allow Photos Access",
                    symbol: "photo",
                    detail: model.isRequestingAccess
                        ? "Complete the Photos permission choice in the macOS dialog. This does not start a scan."
                        : model.libraryAccess?.unavailableReason
                ) {
                    Button(model.isRequestingAccess ? "Waiting for macOS…" : "Allow") {
                        Task { await model.requestAccess() }
                    }
                    .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
                    .focused($actionIsFocused)
                }
            } else if model.libraryAccess == nil {
                PageProgressView(title: "Checking Photos access")
            } else if let reason = model.libraryAccess?.unavailableReason {
                accessUnavailable(reason)
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
            model.refreshAccess(PhotoKitLibrary.currentAccess)
        }
        .onChange(of: model.libraryAccess) { _, _ in
            actionIsFocused = true
        }
        .sheet(isPresented: $showsAccessRecovery, onDismiss: { actionIsFocused = true }) {
            PhotoAccessRecoveryView()
        }
        .onChange(of: model.isScanning, initial: true) { wasRunning, isRunning in
            if isRunning {
                model.preview = nil
                resultBeforeScan = model.results?.finishedAt
                animateEmptyResult = false
            } else if wasRunning {
                animateEmptyResult = model.results?.finishedAt != nil
                    && model.results?.finishedAt != resultBeforeScan
            }
        }
        .onChange(of: model.results?.finishedAt) { _, _ in
            review.highlightedID = nil
            model.preview = nil
        }
        .onChange(of: model.groups) { _, groups in
            review.update(groups: groups)
            if let preview = model.preview,
               !groups.contains(where: { $0.id == preview.groupID && $0.assets.contains(where: { $0.id == preview.id }) }) {
                model.preview = nil
            }
        }
        .onChange(of: model.preview?.id) { _, id in
            if let id { review.highlightedID = id }
            else { gridIsFocused = true }
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
            .focused($actionIsFocused)
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

    private func accessUnavailable(_ reason: String) -> some View {
        PageState(
            title: model.libraryAccess == .restricted ? "Photos access is restricted" : "Photos access is unavailable",
            symbol: "exclamationmark.triangle",
            detail: reason,
            iconColor: Token.textColor(.orange)
        ) {
            if model.libraryAccess?.canOpenSettings == true {
                VStack(spacing: 16) {
                    Text("If Moppo is missing from the Photos list, select Recover Photos Access.")
                        .font(.system(size: 13))
                        .foregroundStyle(Token.Text.secondary)
                    PageStateActions {
                        Button("Open Settings") { PhotoAccessRecoveryView.openSettings() }
                            .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
                            .focused($actionIsFocused)
                        Button("Recover Photos Access") { showsAccessRecovery = true }
                    }
                }
            }
        }
    }

    private func unavailable(_ reason: String) -> some View {
        PageState(
            title: "Photos are unavailable",
            symbol: "exclamationmark.triangle",
            detail: reason,
            iconColor: Token.textColor(.orange)
        ) {
            Button("Try Again") { model.startScan() }
            .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
            .controlSize(.large)
            .disabled(!model.canAccessPhotos || model.isBusyWithDisk)
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
                HStack(spacing: 5) {
                    Text("space")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Token.Fill.control, in: RoundedRectangle(cornerRadius: 4))
                    Text("Quick Look").font(.mcCaption)
                }
                .foregroundStyle(Token.Text.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Press Space to preview the highlighted photo")
            }
            .padding(.horizontal, Token.Size.pageGutter + 15)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .background { clearHighlightBackground }

            if let results = model.results, results.skippedCount > 0 {
                Text(summary(results))
                    .pageHeaderSummary()
                    .padding(.horizontal, Token.Size.pageGutter)
            }
            GeometryReader { geometry in
                let columns = max(1, Int((geometry.size.width - 2 * Token.Size.pageGutter - 24 + 12) / 144))
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(model.groups) { group in
                                groupCard(group, columns: columns)
                            }
                        }
                        .padding(.horizontal, Token.Size.pageGutter)
                        .padding(.top, 2)
                        .padding(.bottom, Token.Size.pageGutter)
                        .frame(minHeight: geometry.size.height, alignment: .top)
                        .background { clearHighlightBackground }
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($gridIsFocused)
                    .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { key in
                        let direction: PhotoReviewState.Direction = switch key.key {
                        case .leftArrow: .left
                        case .rightArrow: .right
                        case .upArrow: .up
                        default: .down
                        }
                        review.moveHighlight(direction, groups: model.groups, columns: columns)
                        return .handled
                    }
                    .onKeyPress(.space) {
                        guard let id = review.highlightedID,
                              let group = model.groups.first(where: { $0.assets.contains(where: { $0.id == id }) }),
                              let asset = group.assets.first(where: { $0.id == id }) else { return .ignored }
                        showPreview(asset, in: group)
                        return .handled
                    }
                    .onChange(of: review.highlightedID) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
        }
    }

    private func groupCard(_ group: DuplicateGroup, columns: Int) -> some View {
        let selectedCount = group.removable.filter { model.selection.contains($0.id) }.count
        return GroupedBox(fill: Token.Fill.cardContent) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.reviewTitle)
                            .font(.mcRowTitle)
                            .foregroundStyle(Token.Text.primary)
                        HStack(spacing: 4) {
                            Text(kindLabel(group.kind))
                            if let distance = group.maximumDistance {
                                Text("· \(String(format: "%.2f", distance)) match")
                            }
                            if let date = group.assets.first?.creationDate {
                                Text("·")
                                Text(date, format: .dateTime.day().month().year())
                            }
                        }
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                        .help(badgeExplanation(group.kind))
                    }
                    Spacer(minLength: 4)
                    Text(selectedCount > 0
                         ? "\(selectedCount) \(selectedCount == 1 ? "photo" : "photos") selected"
                         : "\(group.removable.count) \(group.removable.count == 1 ? "photo" : "photos") available")
                        .font(.mcControlLabel)
                        .foregroundStyle(selectedCount > 0 ? Token.color(.accent) : Token.Text.duplicateAvailableStorage)
                    Button(selectedCount == group.removable.count ? "Deselect" : "Select Copies") {
                        model.toggleGroup(group.id)
                    }
                    .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                    .disabled(model.isBusyWithDisk || model.isRegrouping)
                }
                .padding(12)
                .background(Token.Fill.groupHeader, in: Rectangle())
                Rectangle().fill(Token.Fill.boxBorder).frame(height: Token.hairline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(132), spacing: 12), count: columns), alignment: .leading, spacing: 12) {
                    ForEach(group.assets) { asset in
                        tile(asset, in: group).id(asset.id)
                    }
                }
                .padding(12)
            }
            .background { clearHighlightBackground }
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
        }
    }

    private var clearHighlightBackground: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { review.highlightedID = nil }
            .accessibilityHidden(true)
    }

    private func highlight(_ asset: PhotoAsset) {
        review.highlightedID = asset.id
        gridIsFocused = true
    }

    private func showPreview(_ asset: PhotoAsset, in group: DuplicateGroup) {
        highlight(asset)
        model.preview = .init(groupID: group.id, asset: asset)
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
        let highlighted = review.highlightedID == asset.id
        return PhotoReviewThumbnail(
            asset: asset, thumbnails: thumbnails, size: 132,
            isKeeper: isKeeper, isSelected: selected, isHighlighted: highlighted
        )
        .overlay {
            PreviewClickTarget(
                onClick: { highlight(asset) },
                onPreview: { showPreview(asset, in: group) }
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(asset.filename ?? "Photo")
        .accessibilityValue(isKeeper ? "Kept photo" : (selected ? "Selected for deletion" : "Not selected for deletion"))
        .accessibilityAddTraits(highlighted ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { highlight(asset) }
        .accessibilityAction(named: "Quick Look") { showPreview(asset, in: group) }
        .overlay(alignment: .top) {
            if !isKeeper {
                HStack(spacing: 4) {
                    Button("Keep instead") {
                        model.keepInstead(groupID: group.id, assetID: asset.id)
                    }
                    .buttonStyle(PhotoKeepButtonStyle())
                    .accessibilityLabel("Keep this photo instead")
                    Spacer(minLength: 0)
                    Button { model.toggle(asset.id) } label: {
                        ZStack {
                            Circle().fill(selected ? Token.color(.accent) : Color.black.opacity(0.3))
                            Circle().strokeBorder(.white, lineWidth: 1.5)
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selected ? "Deselect photo" : "Select photo for deletion")
                    .accessibilityValue(selected ? "Selected" : "Not selected")
                }
                .padding(7)
                .disabled(model.isBusyWithDisk || model.isRegrouping)
            }
        }
        .help("Click to highlight. Double-click or press Space to preview.")
    }
}

/// Shows the same state rings in the grid and the preview strip.
struct PhotoReviewThumbnail: View {
    let asset: PhotoAsset
    let thumbnails: PhotoThumbnailLoader
    let size: CGFloat
    let isKeeper: Bool
    let isSelected: Bool
    let isHighlighted: Bool

    var body: some View {
        Group {
            if let image = thumbnails.image(for: asset.id) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Token.Fill.well.overlay {
                    Image(systemName: "photo").foregroundStyle(Token.Text.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.well))
        .overlay {
            RoundedRectangle(cornerRadius: Token.Radius.well)
                .strokeBorder(isKeeper ? Token.color(.green) : (isSelected ? Token.color(.accent) : .clear), lineWidth: 2)
        }
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: Token.Radius.well + 3)
                    .strokeBorder(Token.ink(light: 0.35, dark: 0.5), lineWidth: 2)
                    .padding(-4)
            }
        }
        .onAppear { thumbnails.retain(asset.id) }
        .onDisappear { thumbnails.release(asset.id) }
    }
}

private struct PhotoKeepButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PhotoKeepButtonSurface(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct PhotoKeepButtonSurface<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovering = false

    var body: some View {
        label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(Color.black.opacity(isPressed ? 0.9 : (isHovering ? 0.8 : 0.6)), in: Capsule())
            .contentShape(Capsule())
            .onHover { isHovering = $0 }
    }
}

struct PhotoReviewState {
    enum Direction { case left, right, up, down }
    var highlightedID: String?

    mutating func update(groups: [DuplicateGroup]) {
        if let highlightedID, !groups.contains(where: { $0.assets.contains(where: { $0.id == highlightedID }) }) {
            self.highlightedID = nil
        }
    }

    mutating func moveHighlight(_ direction: Direction, groups: [DuplicateGroup], columns: Int) {
        let columns = max(1, columns)
        let rows = groups.flatMap { group in
            stride(from: 0, to: group.assets.count, by: columns).map {
                Array(group.assets[$0..<min($0 + columns, group.assets.count)])
            }
        }
        let assets = rows.flatMap { $0 }
        guard !assets.isEmpty else { highlightedID = nil; return }
        guard let index = assets.firstIndex(where: { $0.id == highlightedID }) else {
            highlightedID = (direction == .left || direction == .up) ? assets.last?.id : assets.first?.id
            return
        }
        if direction == .left || direction == .right {
            highlightedID = assets[min(max(index + (direction == .left ? -1 : 1), 0), assets.count - 1)].id
        } else if let row = rows.firstIndex(where: { $0.contains(where: { $0.id == highlightedID }) }),
                  let column = rows[row].firstIndex(where: { $0.id == highlightedID }) {
            let target = min(max(row + (direction == .up ? -1 : 1), 0), rows.count - 1)
            highlightedID = rows[target][min(column, rows[target].count - 1)].id
        }
    }
}

extension DuplicateGroup {
    var reviewTitle: String {
        let kindText = switch kind {
        case .burst: "photos in a burst"
        case .exact: "identical photos"
        case .similar: "similar photos"
        }
        let reason = switch keeperReason {
        case .favorite: "a favorite"
        case .burstPick: "your burst pick"
        case .edited: "the edited photo"
        case .resolution: "the highest resolution"
        case .earliest: "the original"
        case .chosenByYou: "your choice"
        }
        return "\(count) \(kindText) · keeping \(reason)"
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
            .buttonStyle(PageActionButtonStyle(size: .small))
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
