import SwiftUI
import MoppoCore

/// Keeps the cleanup filters above the file list.
struct ScannerView: View {
    @Bindable var model: CleanupModel
    let activity: AppModel.Activity?
    let cleanupCompletion: AppModel.CleanupCompletion?
    let onViewDashboard: (UUID) -> Void
    let onUninstallApplication: (FileEntry) -> Void
    @State private var animateEmptyResult = false
    @State private var resultBeforeScan: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var resultsVisible = true
    @State private var worktreeReviewEntry: FileEntry?

    var body: some View {
        Group {
            if case .cleaningUp(let itemCount, let totalBytes) = activity {
                CleanupOperationView(itemCount: itemCount, totalBytes: totalBytes)
                    .transition(.opacity)
            } else if let completion = cleanupCompletion {
                CleanupOperationView(
                    itemCount: completion.outcome.removedCount,
                    totalBytes: completion.outcome.removedBytes,
                    isComplete: true,
                    canScan: !model.isBusyWithDisk,
                    onScanAgain: { model.startScan() },
                    onViewDashboard: { onViewDashboard(completion.id) }
                )
                .id(completion.id)
                .transition(.opacity)
            } else if model.isScanning {
                scanProgress
                    .transition(.opacity)
            } else if let results = model.scanResults {
                VStack(spacing: 0) {
                    VStack(spacing: 12) {
                        if let outcome = model.cleanupOutcome {
                            completion(outcome).modifier(resultEntrance(index: 0))
                        }
                        filterPicker(results)
                            .modifier(resultEntrance(index: 0))
                        listControls(results)
                            .padding(.top, 8)
                            .modifier(resultEntrance(index: 1))
                    }
                    .padding(Token.Size.pageGutter)
                    Divider()
                        .opacity(resultsVisible ? 1 : 0)
                    let visibleCategories = categories(of: results, for: model.scanFilter)
                    let showsRunningApps = model.scanFilter == .safeToRemove
                        && !model.runningAppCaches.isEmpty && !model.isRunningAppsNoticeDismissed
                    let showsEmptyState = hasNoCleanupItems(visibleCategories) && !showsRunningApps
                    GeometryReader { geometry in
                        ScrollView {
                            VStack(spacing: 12) {
                                if showsRunningApps {
                                    runningAppsNotice
                                        .modifier(resultEntrance(index: 2))
                                }
                                categoryOutline(visibleCategories)
                            }
                            .frame(minHeight: showsEmptyState ? geometry.size.height : 0, alignment: .top)
                            .padding(showsEmptyState ? 0 : Token.Size.pageGutter)
                        }
                    }
                }
                .transition(.opacity)
            } else {
                PageState(
                    title: "Ready to scan", symbol: "magnifyingglass",
                    detail: "Use Scan to find cleanup items."
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: $worktreeReviewEntry) { entry in
            WorktreeReviewSheet(entry: entry, onReview: { model.updateWorktreeReview($0, for: entry.id) }, onSelect: {
                model.selectWorktree(entry.id)
                worktreeReviewEntry = nil
            }, onClose: { worktreeReviewEntry = nil })
        }
        .onChange(of: model.isScanning, initial: true) { wasRunning, isRunning in
            if isRunning {
                resultBeforeScan = model.scanResults?.finishedAt
                animateEmptyResult = false
            } else if wasRunning {
                animateEmptyResult = model.scanResults?.finishedAt != nil
                    && model.scanResults?.finishedAt != resultBeforeScan
            }
        }
        .onChange(of: model.scanFilter) { _, _ in animateEmptyResult = false }
        .onDisappear { animateEmptyResult = false }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: showsOperation)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: cleanupCompletion?.id)
        .task {
            model.pruneVanishedEntries()
            model.refreshCleanupRunningOwners()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshCleanupRunningOwners()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            model.refreshCleanupRunningOwners()
        }
        .task(id: model.isScanning) {
            if model.isScanning {
                resultsVisible = false
                return
            }
            model.refreshCleanupRunningOwners()
            guard !resultsVisible else { return }
            if !reduceMotion {
                // Show the initial layout before the entrance animation starts.
                do { try await Task.sleep(for: .milliseconds(30)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            resultsVisible = true
        }
        .onDisappear { resultsVisible = true }
    }

    private var runningAppsNotice: some View {
        let names = ListFormatter.localizedString(byJoining: model.cleanupRunningOwners.map(\.name))
        let bytes = model.runningAppCaches.reduce(Int64(0)) { $0 + $1.allocatedBytes }
        return NoticeBanner(
            title: "Some apps are using cached files",
            dismiss: { model.dismissRunningAppsNotice() }
        ) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Some apps are using cached files")
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                Text("\(names) · \(ByteFormatting.string(bytes)) of caches")
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.secondary)
                    .lineLimit(2)
                    .help(names)
                Text("Save your work before you quit these apps. Their caches will appear in Safe to Remove.")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Quit Apps") {
                Task { await model.quitAppsForCleanup() }
            }
                .buttonStyle(PageActionButtonStyle(fill: Token.Fill.buttonOnCard))
                .fixedSize()
                .disabled(model.isBusyWithDisk)
        }
    }

    private var showsOperation: Bool {
        model.isScanning || model.isRemoving || cleanupCompletion != nil
    }

    private var scanProgress: some View {
        PageProgressView(
            title: "Scanning for cleanup items",
            detail: "\(model.scanProgress)%",
            progress: Double(model.scanProgress) / 100,
            isInterrupting: model.isInterruptingScan,
            icon: .mascot(.scanning)
        )
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: model.scanProgress)
    }

    private func resultEntrance(index: Int) -> ResultEntrance {
        ResultEntrance(isVisible: resultsVisible, index: index, reduceMotion: reduceMotion)
    }

    private func listControls(_ results: ScanResults) -> some View {
        let visible = categories(of: results, for: model.scanFilter)
        let count = visible.reduce(0) { $0 + $1.entries.count }
        return HStack(spacing: 12) {
            SelectionCheckbox(
                title: "Select All",
                detail: "\(count) \(count == 1 ? "item" : "items")",
                state: model.selectAllStateInCurrentView,
                isEnabled: !model.isBusyWithDisk
                    && (model.hasSelectableItemsInCurrentView || model.hasSelectionInCurrentView)
            ) { isOn in
                if isOn && model.canSelectAllInCurrentView { model.selectAllInCurrentView() }
                else { model.deselectAllInCurrentView() }
            }
            .fixedSize()
            Spacer()
        }
        .padding(.leading, 15)
    }

    private func completion(_ outcome: CleanupOutcome) -> some View {
        HStack(spacing: 12) {
            Text(outcome.deletedCount > 0
                ? "\(outcome.removedCount) \(outcome.removedCount == 1 ? "item removed" : "items removed")"
                : "\(ByteFormatting.string(outcome.removedBytes)) moved to Trash")
                .font(.mcRowTitle)
            if !outcome.failed.isEmpty {
                Text("\(outcome.failed.count) items could not be removed.")
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
            }
            Spacer()
        }
    }

    // MARK: - Filter

    /// Filters stay visible while the file list scrolls.
    private func filterPicker(_ results: ScanResults) -> some View {
        PageSegmentedControl(selection: $model.scanFilter, segments: [
            .init(id: .all, title: CleanupModel.ScanFilter.all.title, symbol: "square.grid.2x2",
                  detail: ByteFormatting.string(bytes(in: .all, results: results))),
            .init(id: .safeToRemove, title: CleanupModel.ScanFilter.safeToRemove.title, symbol: "checkmark.circle.fill",
                  detail: ByteFormatting.string(bytes(in: .safeToRemove, results: results)), tint: .green),
            .init(id: .needsReview, title: CleanupModel.ScanFilter.needsReview.title, symbol: "questionmark.circle",
                  detail: ByteFormatting.string(bytes(in: .needsReview, results: results)), tint: .amber)
        ])
        .frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.isBusyWithDisk)
    }

    private func bytes(in filter: CleanupModel.ScanFilter, results: ScanResults) -> Int64 {
        switch filter {
        case .all: results.totalBytes
        case .safeToRemove: results.safeToRemoveBytes
        case .needsReview: results.needsReviewBytes
        }
    }

    // MARK: - Sections

    /// The scan's categories as one tab shows them — see
    /// `ScanCategoryResult.filtered(safeToRemove:)`. `All` keeps every category,
    /// an empty or unavailable one included, because its message is the point there.
    private func categories(
        of results: ScanResults, for filter: CleanupModel.ScanFilter
    ) -> [ScanCategoryResult] {
        guard filter != .all else { return results.categories }
        return results.categories
            .map { $0.filtered(safeToRemove: filter == .safeToRemove) }
            .filter { !$0.entries.isEmpty }
    }

    private func hasNoCleanupItems(_ categories: [ScanCategoryResult]) -> Bool {
        categories.allSatisfy {
            $0.entries.isEmpty && $0.unreadableCount == 0
                && ($0.availability == .available || $0.availability == .empty)
        }
    }

    @ViewBuilder
    private func categoryOutline(_ categories: [ScanCategoryResult]) -> some View {
        if hasNoCleanupItems(categories) {
            ScanCompletionView(
                title: model.scanFilter == .safeToRemove ? "No safe cleanup items found" : "No cleanup items found",
                detail: "The scan found no items in this group.",
                animate: animateEmptyResult
            )
        } else {
            outline(categories)
        }
    }

    private func outline(_ categories: [ScanCategoryResult]) -> some View {
        VStack(spacing: 10) {
            ForEach(Array(categories.enumerated()), id: \.element.id) { index, category in
                GroupedBox(fill: Token.Fill.cardContent) {
                    categorySection(category)
                        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                }
                .modifier(resultEntrance(index: index + 2))
            }
        }
    }

    @ViewBuilder
    private func categorySection(_ category: ScanCategoryResult) -> some View {
        let isExpanded = model.openCategories.contains(category.categoryID)

        VStack(spacing: 0) {
            CategoryRow(
                result: category,
                isExpanded: isExpanded,
                selectedBytes: model.selectedBytes(in: category.categoryID, filter: model.scanFilter),
                onToggle: { toggle(category) }
            )

            if isExpanded, !category.entries.isEmpty {
                let selectableIDs = model.selectableIDs(in: category)
                let selectedIDs = model.selectedIDs(in: category)
                FileTable(
                    entries: category.entries,
                    isSafeToRemove: category.isCountedSafe,
                    showsSafeToRemoveBadges: model.scanFilter != .safeToRemove,
                    selection: $model.scannerSelection,
                    userDataRemovalOverrides: $model.userDataRemovalOverrides,
                    confirmBeforeCleanup: model.confirmBeforeCleanup,
                    onUninstallApplication: onUninstallApplication,
                    onReviewWorktree: { worktreeReviewEntry = $0 },
                    onUnlockChildren: { model.unlockChildren(in: $0) },
                    onToggleChildren: { model.setChildrenSelected($0, in: $1.id) },
                    selectAllState: model.selectAllState(in: category),
                    canToggleAll: !selectableIDs.isEmpty || !selectedIDs.isEmpty,
                    onToggleAll: { model.setSelected($0 && !selectableIDs.isSubset(of: selectedIDs), in: category) }
                )
                .id(model.scanFilter)
                .disabled(model.isBusyWithDisk)
            }
        }
    }

    private func toggle(_ category: ScanCategoryResult) {
        guard category.availability.isActionable, !category.entries.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.18)) {
            if model.openCategories.contains(category.categoryID) {
                model.openCategories.remove(category.categoryID)
            } else {
                model.openCategories.insert(category.categoryID)
            }
        }
    }

}

private struct ResultEntrance: ViewModifier {
    var isVisible: Bool
    var index: Int
    var reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible || reduceMotion ? 0 : 6)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.24).delay(Double(min(index, 7)) * 0.035),
                value: isVisible
            )
    }
}
