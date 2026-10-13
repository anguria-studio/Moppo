import SwiftUI
import MoppoCore

/// Keeps navigation visible beside the page and its actions.
struct MainWindow: View {
    @Bindable var model: AppModel
    var settings: SettingsStore?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            contentColumn
        }
        // The sidebar extends behind the window controls.
        .ignoresSafeArea(.container, edges: .top)
        // Under everything, through the title bar: the shell is the window.
        .background(Token.shell.ignoresSafeArea())
        // Traffic-light geometry, and the window's drag turned off — see
        // `WindowChrome`, which explains why a nested opt-out cannot do it.
        .background(WindowChrome(headerBand: Token.Size.headerBand))
        .disabled(!showsAppUninstallDetail && (model.activity != nil
                  || model.photoDuplicates.isDeleting || model.photoDuplicates.preview != nil))
        // Keep the scroll view enabled so its scrollbar keeps the same width.
        .allowsHitTesting(!showsAppUninstallDetail)
        .accessibilityHidden(model.photoDuplicates.preview != nil || showsAppUninstallDetail)
        .overlay {
            if model.photoDuplicates.preview != nil || showsAppUninstallDetail {
                Token.Fill.previewBackdrop
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
        }
        .sheet(item: Binding(
            get: { showsAppUninstallDetail ? nil : model.activeSheet },
            set: { model.activeSheet = $0 }
        ), onDismiss: finishRemovalConfirmation) { sheet in
            confirmationSheet(sheet)
        }
        .background(PhotoPreviewWindowPresenter(item: model.photoDuplicates.preview, model: model.photoDuplicates))
        .background {
            FloatingDialogWindowPresenter(
                isPresented: showsAppUninstallDetail,
                title: "Application details",
                size: NSSize(width: 560, height: 720),
                minimumSize: NSSize(width: 520, height: 460),
                canClose: !model.uninstaller.isUninstallingApp,
                onClose: model.uninstaller.resetAppUninstall
            ) {
                appUninstallDialog
            }
        }
        .onChange(of: model.duplicateKind) { _, _ in model.photoDuplicates.preview = nil }
        .task {
            if scenePhase == .active { model.startInitialCleanupScan() }
            await model.dashboard.loadDashboard()
        }
        .onChange(of: model.view) { _, view in
            model.photoDuplicates.preview = nil
            if view == .scanner, scenePhase == .active { model.startInitialCleanupScan() }
        }
        .onChange(of: model.isBusyWithDisk) { _, isBusy in
            if !isBusy, scenePhase == .active { model.startInitialCleanupScan() }
        }
        // Coming back to the app is the moment stale rows show: the user was just
        // in Finder, doing things this snapshot cannot know about.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                guard model.checkDiskAccess() else { return }
                model.cleanup.pruneVanishedEntries()
                model.startInitialCleanupScan()
            }
        }
        .alert(
            "Allow Access to Other App Data",
            isPresented: $model.isShowingAppDataAccessAlert
        ) {
            Button("Open System Settings") {
                AppDataAccess.openSystemSettings()
            }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text(
                "Moppo could not move files from another app's container. "
                    + "Allow access to other application data. Then try again."
            )
        }
        // What the footer's status line used to carry, minus the routine
        // successes — see `AppModel.Notice`. An alert waits to be read; the
        // caption it replaces was overwritten by whatever happened next.
        .alert(
            model.notice?.title ?? "",
            isPresented: Binding(
                get: { model.notice != nil },
                set: { if !$0 { model.notice = nil } }
            ),
            presenting: model.notice
        ) { notice in
            if !notice.finderURLs.isEmpty {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting(notice.finderURLs)
                }
            }
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - Columns

    private var showsAppUninstallDetail: Bool {
        model.view == .uninstaller && model.uninstaller.isShowingAppUninstallDetail
    }

    private var appUninstallDialog: some View {
        AppUninstallDetailView(model: model.uninstaller)
            .disabled(model.uninstaller.isUninstallingApp)
            .overlay {
                if let activity = model.activity {
                    ActivityOverlay(activity: activity)
                }
            }
            .sheet(item: $model.activeSheet, onDismiss: finishRemovalConfirmation) { sheet in
                confirmationSheet(sheet)
            }
            .environment(\.colorScheme, colorScheme)
    }

    private func finishRemovalConfirmation() {
        if model.activeSheet == nil { model.finishRemovalConfirmation(false) }
    }

    private var sidebar: some View {
        SidebarView(model: model, headerBand: Token.Size.headerBand)
            .frame(width: Token.Size.sidebarWidth)
            .background(SidebarBackground())
    }

    private var contentColumn: some View {
        VStack(spacing: 0) {
            contentHeader
            detail
        }
    }

    /// Gives the page title and actions equal top and side margins.
    private var contentHeader: some View {
        CenteredHeaderLayout {
            Text(model.view.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
            HStack(spacing: 0) {
                headerCentre
            }
            HStack(spacing: 10) {
                if model.view == .duplicates || model.removalCompletion?.destination != model.view {
                    pageActions
                    if hasRemovalAction {
                        removeButton
                    }
                }
            }
            .disabled(model.removalCompletion?.destination == model.view)
        }
        // Use the same margin above the header and beside the page content.
        .padding(Token.Size.pageGutter)
        // Empty header space moves the window. Controls keep their own actions.
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.view {
            case .dashboard:
                DashboardView(
                    model: model.dashboard,
                    scanResults: model.cleanup.scanResults, lastScanAt: model.cleanup.lastScanFinishedAt,
                    onShowScanner: model.showScanner, onScan: { model.cleanup.startScan() },
                    onRevealGrowth: model.revealGrowth, settings: settings
                )
            case .scanner:
                ScannerView(
                    model: model.cleanup,
                    activity: model.activity,
                    cleanupCompletion: model.cleanupCompletion,
                    onViewDashboard: { model.showDashboardAfterCleanup($0) },
                    onUninstallApplication: { model.uninstaller.planAppUninstall($0.url) }
                )
            case .storageExplorer:
                StorageExplorerView(model: model.storageExplorer)
            case .uninstaller:
                AppUninstallerView(
                    model: model.uninstaller, findRequest: model.findRequest,
                    onViewDashboard: { model.view = .dashboard }
                )
            case .history:
                CleanupHistoryView(model: model.recovery, findRequest: model.findRequest)
            case .trash:
                TrashView(model: model.recovery, findRequest: model.findRequest)
            case .duplicates:
                DuplicatesView(model: model)
            }
        }
        .allowsHitTesting(model.view == .duplicates || model.removalCompletion?.destination != model.view)
        .accessibilityHidden(model.view != .duplicates && model.removalCompletion?.destination == model.view)
        .overlay {
            if model.view != .duplicates {
                RemovalOperationSurface(model: model)
            }
        }
        .frame(minWidth: Token.Size.minimumContentWidth)
        // The page fills the space beside the sidebar.
        .background(Token.pageBackground)
    }

    /// Keeps confirmation controls active above the detail dialog.
    @ViewBuilder
    private func confirmationSheet(_ sheet: AppModel.Sheet) -> some View {
        switch sheet {
        case .cleanUp:
            ConfirmationSheet(
                // Every figure from the captured plan, so the sheet describes
                // the operation that will actually run.
                variant: .cleanUp(
                    itemCount: model.cleanup.pendingCleanUp?.itemCount ?? 0,
                    totalBytes: model.cleanup.pendingCleanUp?.totalBytes ?? 0,
                    protectedDataCount: model.cleanup.pendingCleanUp?.protectedDataCount ?? 0,
                    // Absent until the private-size reading lands, a moment
                    // after the sheet appears.
                    saving: model.cleanup.pendingCleanUp?.freed.flatMap {
                        // A reading with gaps in it is no reading: an item the
                        // filesystem would not answer for could hold anything,
                        // so the sheet says nothing rather than a partial total.
                        $0.unreportedCount == 0
                            ? ConfirmationSheet.CleanupSaving(
                                freedBytes: $0.privateBytes,
                                isMinimum: $0.containsSharedGroups
                            )
                            : nil
                    }
                ),
                runningOwnerNames: model.cleanup.pendingCleanUp?.runningOwners.map(\.name) ?? [],
                includesSoundLibrary: model.cleanup.pendingCleanUp?.includesSoundLibrary ?? false,
                worktreeWarning: model.cleanup.pendingCleanUp?.worktreeWarning,
                dockerImageCount: model.cleanup.pendingCleanUp?.dockerImageCount ?? 0,
                dockerImageBytes: model.cleanup.pendingCleanUp?.dockerImageBytes ?? 0,
                codexSessionCount: model.cleanup.pendingCleanUp?.codexSessionCount ?? 0,
                codexSessionWarning: model.cleanup.pendingCleanUp?.codexSessionWarning,
                onConfirm: { Task { await model.cleanup.performCleanUp() } },
                onQuitAndConfirm: {
                    Task { await model.cleanup.performCleanUp(quittingOwners: true) }
                },
                onCancel: { model.cleanup.cancelCleanUp() }
            )
        case .removal:
            if let request = model.pendingRemovalConfirmation {
                ConfirmationSheet(
                    variant: removalVariant(request),
                    onConfirm: { model.finishRemovalConfirmation(true) },
                    onCancel: { model.finishRemovalConfirmation(false) }
                )
            }
        case .emptyTrash:
            ConfirmationSheet(
                variant: .emptyTrash(
                    itemCount: model.recovery.trashSummary?.itemCount ?? 0,
                    totalBytes: model.recovery.trashSummary?.totalBytes ?? 0
                ),
                onConfirm: { Task { await model.recovery.emptyTrash() } },
                onCancel: { model.activeSheet = nil }
            )
        }
    }

    private func removalVariant(_ request: RemovalConfirmation) -> ConfirmationSheet.Variant {
        switch request {
        case .trash(let count, let bytes, let protected):
            .cleanUp(itemCount: count, totalBytes: bytes, protectedDataCount: protected, saving: nil)
        case .photos(let count):
            .photos(itemCount: count)
        }
    }

    // MARK: - Page selection actions

    /// Review steps provide their own actions.
    private var hasRemovalAction: Bool {
        switch model.view {
        case .scanner, .duplicates, .storageExplorer, .trash: true
        // Only over the grid of applications. The review and done pages are steps
        // in a sequence and carry their own buttons.
        case .uninstaller: model.uninstaller.isShowingUninstallerLibrary
        case .dashboard, .history: false
        }
    }

    private var canRemove: Bool {
        guard !model.isBusyWithDisk else { return false }
        switch model.view {
        case .scanner:         return !model.cleanup.cleanupSelection(in: .all).isEmpty
        case .duplicates:      return model.duplicateKind == .files
            ? !model.fileDuplicates.selection.isEmpty && !model.fileDuplicates.isScanning
            : model.photoDuplicates.canAccessPhotos && !model.photoDuplicates.selection.isEmpty && !model.photoDuplicates.isRegrouping
        case .uninstaller:     return model.uninstaller.uninstallerTab == .installed
            ? !model.uninstaller.selectedApplicationIDs.isEmpty
            : !model.uninstaller.selectedLeftoverIdentifiers.isEmpty && !model.uninstaller.isLoadingApplicationLeftovers
        case .storageExplorer: return model.storageExplorer.canRemoveSelection
            && !model.storageExplorer.isMapSelectionPending
            && !model.storageExplorer.isMeasurementBlocked
        case .trash:           return (model.recovery.trashSummary?.itemCount ?? 0) > 0
        case .dashboard, .history: return false
        }
    }

    private func removeTapped() {
        switch model.view {
        case .scanner: model.cleanup.requestCleanUp(in: .all)
        case .duplicates:
            if model.duplicateKind == .files {
                Task { await model.fileDuplicates.removeSelected() }
            } else {
                Task { await model.photoDuplicates.deleteSelected() }
            }
        case .uninstaller:
            if model.uninstaller.uninstallerTab == .installed {
                model.uninstaller.moveSelectedApplicationsToTrash()
            } else {
                Task { await model.uninstaller.requestLeftoverRemoval() }
            }
        case .storageExplorer: Task { await model.storageExplorer.requestRemoval() }
        case .trash:      model.activeSheet = .emptyTrash
        case .dashboard, .history: break
        }
    }

    /// Names the next action for the current selection.
    private var removeButton: some View {
        Button(action: removeTapped) {
            HStack(spacing: 7) {
                if model.isCleaningUp || model.isRemovingDuplicateFiles {
                    ProgressView().controlSize(.small)
                }
                Text(model.removeLabel)
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
            .toolbarButtonLabel()
        }
        .controlSize(.large)
        .buttonStyle(HeaderRemovalButtonStyle(
            tint: Token.color(.red)
        ))
        .disabled(!canRemove)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: model.removeLabel)
        .help(model.view == .scanner
              ? model.cleanup.hasSelectedDockerImages
                ? "Docker permanently removes selected images. Other selected items move to the Trash."
                : "Moves selected items from all filters to the Trash."
              : model.view == .uninstaller && model.uninstaller.uninstallerTab == .installed
                ? "Checks each selected application before uninstall."
                : model.removeLabel)
    }

    /// Names the operation that blocks scans on the current page.
    @ViewBuilder
    private var headerCentre: some View {
        if model.cleanup.isScanning, model.view != .scanner {
            backgroundWorkStatus(
                title: "Cleanup scan",
                detail: "\(model.cleanup.scanProgress)% complete",
                progress: Double(model.cleanup.scanProgress) / 100,
                isInterrupting: model.cleanup.isInterruptingScan,
                onStop: { model.cleanup.cancelScan() }
            )
        } else if model.storageExplorer.isLoading {
            backgroundWorkStatus(
                title: "Storage Explorer scan",
                detail: "\(model.storageExplorer.progress.fileCount.formatted()) files · "
                    + ByteFormatting.string(model.storageExplorer.progress.allocatedBytes),
                isInterrupting: model.storageExplorer.isInterrupting,
                onStop: { model.storageExplorer.cancel() }
            )
        } else if model.fileDuplicates.isScanning,
                  model.view != .duplicates || model.duplicateKind != .files {
            let progress = model.fileDuplicates.progress
            backgroundWorkStatus(
                title: "Duplicate file scan",
                detail: progress.map { "\($0.completed.formatted()) of \($0.total.formatted()) files" }
                    ?? "Preparing scan",
                progress: progress?.fractionCompleted,
                isInterrupting: model.fileDuplicates.isInterrupting,
                onStop: { model.fileDuplicates.cancelScan() }
            )
        } else if model.photoDuplicates.isScanning,
                  model.view != .duplicates || model.duplicateKind != .photos {
            backgroundWorkStatus(
                title: "Duplicate photo scan",
                detail: "\(model.photoDuplicates.progress?.percent ?? 0)% complete",
                progress: Double(model.photoDuplicates.progress?.percent ?? 0) / 100,
                isInterrupting: model.photoDuplicates.isInterrupting,
                onStop: { model.photoDuplicates.cancelScan() }
            )
        } else if model.uninstaller.isPlanningAppUninstall, model.view != .uninstaller {
            backgroundWorkStatus(
                title: "Checking selected apps",
                detail: model.uninstaller.appUninstallPlanningDetail ?? "Finding related files",
                isInterrupting: model.uninstaller.isInterruptingAppUninstall,
                onStop: { model.uninstaller.resetAppUninstall() }
            )
        }
    }

    private func backgroundWorkStatus(
        title: String, detail: String, progress: Double? = nil,
        isInterrupting: Bool = false,
        onStop: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            if isInterrupting {
                ScanInterruptionView()
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.primary)
            } else {
                Text(title)
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                OperationProgressBar(progress: progress)
                    .frame(width: 60)
                    .accessibilityLabel(title)
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .frame(width: 24, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop \(title)")
                .help("Stop \(title)")
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, isInterrupting ? 14 : 6)
        .frame(height: 38)
        .background(Token.Fill.control, in: Capsule())
        .overlay {
            Capsule().strokeBorder(
                colorScheme == .light ? Token.Fill.boxBorder : Token.Fill.controlBorder,
                lineWidth: Token.hairline
            )
        }
        .help(isInterrupting ? ScanInterruptionView.title
              : "\(title): \(detail). Finish or stop this operation to start another scan.")
        .accessibilityElement(children: .contain)
    }

    /// Each page provides actions for its own content.
    @ViewBuilder
    private var pageActions: some View {
        switch model.view {
        case .scanner:
            Button {
                if model.cleanup.isScanning { model.cleanup.cancelScan() } else { model.cleanup.startScan() }
            } label: {
                if model.cleanup.isInterruptingScan {
                    ScanInterruptionView()
                } else {
                    Label(
                        model.cleanup.isScanning ? "Stop Scan" : "Scan",
                        systemImage: model.cleanup.isScanning ? "stop.fill" : "magnifyingglass"
                    )
                }
            }
            .buttonStyle(PageActionButtonStyle())
            .controlSize(.large)
            .disabled(model.cleanup.isInterruptingScan || (!model.cleanup.isScanning && model.isBusyWithDisk))
        case .dashboard:
            Button { Task { await model.dashboard.measureStorage() } } label: {
                Label("Refresh Dashboard", systemImage: "arrow.clockwise")
            }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk || model.dashboard.isLoadingBreakdown)
        case .trash:
            Button { Task { await model.recovery.loadTrash() } } label: {
                Label("Refresh Trash", systemImage: "arrow.clockwise")
            }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk)
        case .uninstaller:
            if model.uninstaller.isShowingUninstallerLibrary {
                Button {
                    if model.uninstaller.uninstallerTab == .installed {
                        model.uninstaller.loadInstalledApplications()
                    } else {
                        model.uninstaller.loadApplicationLeftovers()
                    }
                } label: {
                    Label(model.uninstaller.uninstallerTab == .installed ? "Refresh Apps" : "Refresh Leftovers", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk || model.uninstaller.isLoadingApplicationLeftovers)
            }
        case .duplicates:
            if model.duplicateKind == .photos,
               model.photoDuplicates.canAccessPhotos, model.photoDuplicates.results != nil, model.photoDuplicates.unavailableReason == nil {
                Button { model.photoDuplicates.startScan() } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk)
                .help("Scan the photo library again.")
            } else if model.duplicateKind == .files, model.fileDuplicates.results != nil {
                Button { model.fileDuplicates.startScan() } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk)
                .help("Scan the selected folders again.")
            }
        case .storageExplorer, .history:
            EmptyView()
        }
    }

}

/// Centers the status and keeps it clear of the title and actions.
private struct CenteredHeaderLayout: Layout {
    private let gap: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(
            width: proposal.width ?? sizes.reduce(2 * gap) { $0 + $1.width },
            height: max(38, sizes.map(\.height).max() ?? 0)
        )
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified)
        let trailing = subviews[2].sizeThatFits(.unspecified)
        let available = max(0, bounds.width - leading.width - trailing.width - 2 * gap)
        let centre = subviews[1].sizeThatFits(ProposedViewSize(width: available, height: bounds.height))
        let minimumX = bounds.minX + leading.width + gap + centre.width / 2
        let maximumX = bounds.maxX - trailing.width - gap - centre.width / 2
        // On narrow windows, the status moves only far enough to keep the actions clear.
        let centreX = max(minimumX, min(bounds.midX, maximumX))

        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[1].place(
            at: CGPoint(x: centreX, y: bounds.midY), anchor: .center,
            proposal: ProposedViewSize(width: centre.width, height: bounds.height)
        )
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
    }
}
