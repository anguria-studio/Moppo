import AppKit
import MoppoCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// Reviews files that match by size, hashes, and a final byte comparison.
struct FileDuplicatesView: View {
    @Bindable var model: FileDuplicatesModel
    @State private var animateEmptyResult = false
    @State private var resultBeforeScan: Date?
    @State private var review = FileDuplicateReviewState()
    @State private var previewURL: URL?
    @State private var previewNavigation = FilePreviewNavigation()
    @FocusState private var listIsFocused: Bool

    private var visibleFiles: [DuplicateFile] { review.visibleFiles(in: model.groups) }

    var body: some View {
        Group {
            if model.isScanning {
                scanning
            } else if model.results == nil {
                intro
            } else if model.groups.isEmpty {
                nothingFound
            } else {
                groups
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .operationResultAnimation(isRunning: model.isScanning)
        .onChange(of: model.isScanning, initial: true) { wasRunning, isRunning in
            if isRunning {
                resultBeforeScan = model.results?.finishedAt
                animateEmptyResult = false
                previewURL = nil
            } else if wasRunning {
                animateEmptyResult = model.results?.finishedAt != nil
                    && model.results?.finishedAt != resultBeforeScan
            }
        }
        .onChange(of: model.minimumBytes) { _, _ in animateEmptyResult = false }
        .onChange(of: model.results?.finishedAt, initial: true) { _, _ in
            review.reset(groups: model.groups)
            previewURL = nil
        }
        .onChange(of: model.groups) { _, groups in
            review.update(groups: groups)
            if let previewURL, !visibleFiles.contains(where: { $0.url == previewURL }) {
                self.previewURL = nil
            }
        }
        .onDisappear {
            animateEmptyResult = false
            previewNavigation.stop()
            previewURL = nil
        }
        .quickLookPreview($previewURL, in: visibleFiles.map(\.url))
        .onChange(of: previewURL) { _, url in
            if let file = visibleFiles.first(where: { $0.url == url }) {
                review.highlightedID = file.id
            } else {
                previewNavigation.stop()
            }
        }
    }

    private var intro: some View {
        PageState(
            title: "Find duplicate files",
            symbol: "doc.on.doc",
            detail: "Select one or more folders. Moppo verifies file contents and keeps "
                + "one copy in each set. Hidden files, cloud-only files and documents saved "
                + "as packages, such as Pages and Keynote files, are not compared."
        ) {
            Button("Choose Folders", systemImage: "folder") { model.chooseFolders() }
                .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
                .disabled(model.isBusyWithDisk)
        }
    }

    private var scanning: some View {
        PageProgressView(
            title: "Scanning for duplicate files",
            detail: progressLabel,
            progress: model.progress?.fractionCompleted,
            isInterrupting: model.isInterrupting,
            onStop: { model.cancelScan() }
        )
    }

    private var progressLabel: String {
        guard let progress = model.progress else { return "Preparing…" }
        switch progress.stage {
        case .enumerating:
            return "Reading the selected folders…"
        case .sampling:
            return "Checking likely matches — \(progress.completed) of \(progress.total)"
        case .verifying:
            return "Verifying file contents — \(progress.completed) of \(progress.total)"
        case .done:
            return "Finishing…"
        }
    }

    @ViewBuilder
    private var nothingFound: some View {
        if hasFilteredResults {
            PageState(
                title: "No duplicates match this size",
                symbol: "line.3.horizontal.decrease",
                detail: "Choose a smaller minimum file size to show more results."
            )
        } else {
            ScanCompletionView(
                title: "No duplicate files found",
                detail: model.results.map { resultSummary($0) },
                animate: animateEmptyResult
            )
        }
    }

    private var hasFilteredResults: Bool {
        !(model.results?.groups.isEmpty ?? true)
    }

    private var groups: some View {
        let selectable = Set(model.groups.flatMap(\.removable).map(\.id))
        return VStack(spacing: 0) {
            HStack {
                SelectionCheckbox(
                    title: "Select All",
                    detail: "\(selectable.count) \(selectable.count == 1 ? "item" : "items")",
                    state: !selectable.isEmpty && selectable.isSubset(of: model.selection) ? .on : .off,
                    isEnabled: !selectable.isEmpty && !model.isBusyWithDisk
                ) { isOn in
                    if isOn { model.selectAll() }
                    else { model.deselectAll() }
                }
                .fixedSize()
                Spacer()
                HStack(spacing: 5) {
                    Text("space")
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Token.Fill.control, in: RoundedRectangle(cornerRadius: 4))
                    Text("Quick Look").font(.mcCaption)
                }
                .foregroundStyle(Token.Text.secondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Press Space to preview the highlighted file")
            }
            .padding(.horizontal, Token.Size.pageGutter + 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .help(model.results.map { resultSummary($0) } ?? "")

            scrollingGroups
        }
    }

    private var scrollingGroups: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.groups) { group in
                        groupCard(group)
                    }
                }
                .padding(.horizontal, Token.Size.pageGutter)
                .padding(.top, 2)
                .padding(.bottom, Token.Size.pageGutter)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listIsFocused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                moveHighlight(key.key == .downArrow ? 1 : -1)
                return .handled
            }
            .onKeyPress(.space) {
                guard review.highlightedID != nil else { return .ignored }
                togglePreview()
                return .handled
            }
            .onKeyPress(.escape) {
                guard previewURL != nil else { return .ignored }
                previewURL = nil
                return .handled
            }
            .onChange(of: review.highlightedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func highlight(_ file: DuplicateFile) {
        review.highlightedID = file.id
        listIsFocused = true
        if previewURL != nil { previewURL = file.url }
    }

    private func moveHighlight(_ direction: Int) {
        review.moveHighlight(direction, groups: model.groups)
        if previewURL != nil {
            previewURL = visibleFiles.first { $0.id == review.highlightedID }?.url
        }
    }

    private func togglePreview() {
        if previewURL != nil {
            previewURL = nil
            return
        }
        guard let file = visibleFiles.first(where: { $0.id == review.highlightedID }) else { return }
        showPreview(file)
    }

    private func showPreview(_ file: DuplicateFile) {
        highlight(file)
        previewNavigation.start(onClose: { previewURL = nil }) { moveHighlight($0) }
        previewURL = file.url
    }

    private func resultSummary(_ results: FileDuplicateResults) -> String {
        var text = "Checked \(results.examinedCount.formatted()) files. "
            + "\(results.eligibleCount.formatted()) were eligible for comparison."
        if !results.groups.isEmpty {
            text += " Found \(results.groups.count.formatted()) verified duplicate sets."
        }
        if results.skippedCount > 0 {
            text += " Skipped \(results.skippedCount.formatted()) unreadable, changed, or cloud-only items."
        }
        return text
    }

    private func groupCard(_ group: FileDuplicateGroup) -> some View {
        let selectedCopies = group.removable.filter { model.selection.contains($0.id) }
        let selectedBytes = selectedCopies.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let isCollapsed = review.collapsedGroups.contains(group.id)
        let files = review.files(in: group)

        return GroupedBox(fill: Token.Fill.cardContent) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Button {
                        review.toggleGroup(group)
                        if !isCollapsed, files.contains(where: { $0.url == previewURL }) {
                            previewURL = nil
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: group.fileSymbol)
                                .font(.system(size: 16))
                                .foregroundStyle(Token.Text.secondary)
                                .frame(width: 34, height: 34)
                                .background(Token.Fill.cardContent, in: RoundedRectangle(cornerRadius: 7))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7)
                                        .strokeBorder(Token.Fill.cardBorder, lineWidth: Token.hairline)
                                }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.sharedFilename ?? "\(group.count) identical files, different names")
                                    .font(.mcRowTitle)
                                    .foregroundStyle(Token.Text.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(group.headerDetail)
                                    .font(.mcCaption)
                                    .foregroundStyle(Token.Text.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                    .help(isCollapsed ? "Show copies" : "Hide copies")

                    Text(selectedCopies.isEmpty
                        ? "Up to \(ByteFormatting.string(group.reclaimableBytes)) available"
                        : "\(ByteFormatting.string(selectedBytes)) selected")
                        .font(.mcControlLabel.weight(.medium))
                        .foregroundStyle(selectedCopies.isEmpty
                            ? Token.Text.duplicateAvailableStorage : Token.color(.accent))
                        .fixedSize()
                    Button(model.isGroupSelected(group.id) ? "Deselect" : "Select Copies") {
                        model.toggleGroup(group.id)
                    }
                    .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                    .disabled(model.isBusyWithDisk)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Token.Fill.groupHeader, in: Rectangle())

                if !isCollapsed {
                    Divider()
                    ForEach(Array(files.enumerated()), id: \.element.id) { index, file in
                        fileRow(file, group: group)
                            .id(file.id)
                        if index < files.count - 1 {
                            Rectangle().fill(Token.Fill.boxBorder).frame(height: Token.hairline)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
        }
    }

    private func fileRow(_ file: DuplicateFile, group: FileDuplicateGroup) -> some View {
        let isKeeper = file.id == group.keeper.id
        let selected = model.selection.contains(file.id)
        let highlighted = review.highlightedID == file.id

        return HStack(spacing: 8) {
            if isKeeper {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Token.Fill.keepIndicator)
                    .frame(width: 24, height: 28)
                    .help("This copy will remain")
                    .onTapGesture(count: 2) { showPreview(file) }
                    .onTapGesture { highlight(file) }
            } else {
                SelectionCheckbox(
                    title: "Select \(file.url.lastPathComponent) in \(group.locationLabel(for: file))",
                    state: selected ? .on : .off,
                    isEnabled: !model.isBusyWithDisk,
                    showsTitle: false
                ) { _ in model.toggle(file.id) }
                .frame(width: 24, height: 28)
                .help(selected ? "Keep this copy" : "Move this copy to the Trash")
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(group.sharedFilename == nil ? file.url.lastPathComponent : group.locationLabel(for: file))
                        .font(.mcBody.weight(.medium))
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if isKeeper { Badge(text: "keep", style: .safe) }
                }
                Text((file.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                    .font(.mcMonoSmall)
                    .foregroundStyle(Token.Text.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 48)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { showPreview(file) }
            .onTapGesture { highlight(file) }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(highlighted ? [.isSelected, .isButton] : .isButton)
            .accessibilityAction { highlight(file) }
            .accessibilityAction(named: "Quick Look") { showPreview(file) }

            if !isKeeper {
                Button("Keep instead") {
                    model.keepInstead(groupID: group.id, fileID: file.id)
                }
                .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                .disabled(model.isBusyWithDisk)
            }

            Group {
                if let date = file.modificationDate {
                    Text(date, format: .dateTime.day().month().year())
                } else {
                    Text("—")
                }
            }
            .font(.mcCaption)
            .foregroundStyle(Token.Text.secondary)
            .frame(width: 80, alignment: .trailing)
            .frame(height: 48)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { showPreview(file) }
            .onTapGesture { highlight(file) }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .foregroundStyle(Token.Text.secondary)
                    .frame(width: 24, height: 28)
            }
            .buttonStyle(.borderless)
            .help("Show in Finder")
            .accessibilityLabel("Show \(file.url.lastPathComponent) in Finder")
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .contentShape(Rectangle())
        .hoverHighlight(
            fill: highlighted ? Token.Fill.rowSelection : Token.Fill.rowHover,
            restingFill: highlighted ? Token.Fill.rowSelection : .clear
        )
        .contextMenu {
            Button("Quick Look") { showPreview(file) }
            if !isKeeper {
                Button("Keep instead") { model.keepInstead(groupID: group.id, fileID: file.id) }
                    .disabled(model.isBusyWithDisk)
            }
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([file.url])
            }
        }
    }

}

/// Filters completed scan results by file size.
struct FileDuplicateMinimumPicker: View {
    @Bindable var model: FileDuplicatesModel

    private let minimumOptions: [(String, Int64)] = [
        ("All files (0 MB)", 0),
        ("At least 1 MB", 1_000_000),
        ("At least 10 MB", 10_000_000),
        ("At least 100 MB", 100_000_000)
    ]

    var body: some View {
        HStack(spacing: 8) {
            Text("Minimum file size")
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.secondary)
            Menu {
                Picker("Minimum file size", selection: $model.minimumBytes) {
                    ForEach(minimumOptions, id: \.1) { option in
                        Text(option.0).tag(option.1)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 7) {
                    Text(minimumOptions.first { $0.1 == model.minimumBytes }?.0
                         ?? ByteFormatting.string(model.minimumBytes))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .accessibilityHidden(true)
                }
            }
            .menuStyle(.button)
            .buttonStyle(PageActionButtonStyle(size: .small))
            .menuIndicator(.hidden)
            .disabled(model.isBusyWithDisk)
            .accessibilityLabel("Minimum file size")
            .accessibilityValue(minimumOptions.first { $0.1 == model.minimumBytes }?.0 ?? "")
        }
        .fixedSize()
        .help("Filter results by file size. The scan checks all eligible file sizes.")
    }

}

/// Keeps row navigation separate from the copies selected for removal.
struct FileDuplicateReviewState {
    var highlightedID: DuplicateFile.ID?
    private(set) var collapsedGroups: Set<FileDuplicateGroup.ID> = []
    private var rowOrder: [FileDuplicateGroup.ID: [DuplicateFile.ID]] = [:]

    mutating func reset(groups: [FileDuplicateGroup]) {
        self = Self()
        update(groups: groups)
    }

    mutating func update(groups: [FileDuplicateGroup]) {
        rowOrder = Dictionary(uniqueKeysWithValues: groups.map { group in
            let currentIDs = group.files.map(\.id)
            let current = Set(currentIDs)
            let retained = (rowOrder[group.id] ?? []).filter { current.contains($0) }
            let retainedIDs = Set(retained)
            return (group.id, retained + currentIDs.filter { !retainedIDs.contains($0) })
        })
        collapsedGroups.formIntersection(groups.map(\.id))
        if let highlightedID, !visibleFiles(in: groups).contains(where: { $0.id == highlightedID }) {
            self.highlightedID = nil
        }
    }

    func files(in group: FileDuplicateGroup) -> [DuplicateFile] {
        let files = Dictionary(uniqueKeysWithValues: group.files.map { ($0.id, $0) })
        return (rowOrder[group.id] ?? group.files.map(\.id)).compactMap { files[$0] }
    }

    func visibleFiles(in groups: [FileDuplicateGroup]) -> [DuplicateFile] {
        groups.filter { !collapsedGroups.contains($0.id) }.flatMap { files(in: $0) }
    }

    mutating func toggleGroup(_ group: FileDuplicateGroup) {
        if collapsedGroups.contains(group.id) {
            collapsedGroups.remove(group.id)
        } else {
            collapsedGroups.insert(group.id)
            if group.files.contains(where: { $0.id == highlightedID }) { highlightedID = nil }
        }
    }

    mutating func moveHighlight(_ direction: Int, groups: [FileDuplicateGroup]) {
        let files = visibleFiles(in: groups)
        guard !files.isEmpty else { highlightedID = nil; return }
        guard let index = files.firstIndex(where: { $0.id == highlightedID }) else {
            highlightedID = direction > 0 ? files.first?.id : files.last?.id
            return
        }
        let next = index + direction
        if files.indices.contains(next) { highlightedID = files[next].id }
    }
}

extension FileDuplicateGroup {
    var sharedFilename: String? {
        let name = keeper.url.lastPathComponent
        return removable.allSatisfy { $0.url.lastPathComponent == name } ? name : nil
    }

    var headerDetail: String {
        let reason: String
        switch keeperReason {
        case .oldestCopy: reason = "keeping the oldest"
        case .firstByName: reason = "keeping the first by name"
        case .chosenByUser: reason = "keeping your choice"
        }
        if sharedFilename != nil { return "\(count) identical files · \(reason)" }
        let extensions = Set(files.map { $0.url.pathExtension.lowercased() })
        let fileType = extensions.count == 1 && !keeper.url.pathExtension.isEmpty
            ? ".\(keeper.url.pathExtension.lowercased())" : "Multiple file types"
        return "\(fileType) · \(reason)"
    }

    func locationLabel(for file: DuplicateFile) -> String {
        let paths = files.map { $0.url.deletingLastPathComponent().pathComponents }
        var common = paths[0]
        for path in paths.dropFirst() {
            common = Array(zip(common, path).prefix { $0 == $1 }.map { $0.0 })
        }
        let parent = file.url.deletingLastPathComponent()
        let suffix = parent.pathComponents.dropFirst(common.count).joined(separator: "/")
        return suffix.isEmpty ? parent.lastPathComponent : suffix
    }

    var fileSymbol: String {
        let types = files.compactMap { UTType(filenameExtension: $0.url.pathExtension) }
        guard types.count == count else { return "doc" }
        if types.allSatisfy({ $0.conforms(to: .movie) || $0.conforms(to: .video) }) { return "video" }
        if types.allSatisfy({ $0.conforms(to: .image) }) { return "photo" }
        if types.allSatisfy({ $0.conforms(to: .audio) }) { return "waveform" }
        if types.allSatisfy({ $0.conforms(to: .archive) }) { return "doc.zipper" }
        return "doc"
    }
}
