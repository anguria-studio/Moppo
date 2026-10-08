import SwiftUI
import MoppoCore

/// Keeps navigation visible beside the page and its actions.
struct MainWindow: View {
    @Bindable var model: AppModel
    var settings: SettingsStore?
    @Environment(\.scenePhase) private var scenePhase
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
        .disabled(model.activity != nil || model.isDeletingPhotos)
        .background(PhotoPreviewWindowPresenter(item: model.photoPreview, model: model))
        .onChange(of: model.duplicateKind) { _, _ in model.photoPreview = nil }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.photoPreview = nil
        }
        .task {
            if scenePhase == .active { model.startInitialCleanupScan() }
            await model.loadDashboard()
        }
        .onChange(of: model.view) { _, view in
            model.photoPreview = nil
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
                model.pruneVanishedEntries()
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
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - Columns

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

    /// Aligns the page title and actions with the window controls.
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
        // The page's own gutter, so the title and the actions line up with the
        // cards under them rather than with the viewport's edge.
        .padding(.horizontal, Token.Size.pageGutter)
        .frame(height: Token.Size.headerBand)
        // Empty header space moves the window. Controls keep their own actions.
        .background(WindowDragHandle())
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            switch model.view {
            case .dashboard:
                DashboardView(model: model, settings: settings)
            case .scanner:
                ScannerView(model: model)
            case .storageExplorer:
                StorageExplorerView(
                    model: model.storageExplorer,
                    isMeasurementBlocked: model.isStorageExplorerMeasurementBlocked
                )
            case .uninstaller:
                AppUninstallerView(model: model)
            case .history:
                CleanupHistoryView(model: model)
            case .trash:
                TrashView(model: model)
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
        // The header contains the actions for the current page.
        // A real sheet, so macOS supplies the titlebar attachment, the entrance
        // animation, and Escape/Return handling.
        .sheet(item: $model.activeSheet) { sheet in
            switch sheet {
            case .cleanUp:
                ConfirmationSheet(
                    // Every figure from the captured plan, so the sheet describes
                    // the operation that will actually run.
                    variant: .cleanUp(
                        itemCount: model.pendingCleanUp?.itemCount ?? 0,
                        totalBytes: model.pendingCleanUp?.totalBytes ?? 0,
                        protectedDataCount: model.pendingCleanUp?.protectedDataCount ?? 0,
                        // Absent until the private-size reading lands, a moment
                        // after the sheet appears.
                        saving: model.pendingCleanUp?.freed.flatMap {
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
                    runningOwnerNames: model.pendingCleanUp?.runningOwners.map(\.name) ?? [],
                    onConfirm: { Task { await model.performCleanUp() } },
                    onQuitAndConfirm: {
                        Task { await model.performCleanUp(quittingOwners: true) }
                    },
                    onCancel: { model.cancelCleanUp() }
                )
            case .emptyTrash:
                ConfirmationSheet(
                    variant: .emptyTrash(
                        itemCount: model.trashSummary?.itemCount ?? 0,
                        totalBytes: model.trashSummary?.totalBytes ?? 0
                    ),
                    onConfirm: { Task { await model.emptyTrash() } },
                    onCancel: { model.activeSheet = nil }
                )
            }
        }
    }

    // MARK: - Page selection actions

    /// Review steps provide their own actions.
    private var hasRemovalAction: Bool {
        switch model.view {
        case .scanner, .duplicates, .storageExplorer, .trash: true
        // Only over the grid of applications. The review and done pages are steps
        // in a sequence and carry their own buttons.
        case .uninstaller: model.isShowingUninstallerLibrary
        case .dashboard, .history: false
        }
    }

    private var canRemove: Bool {
        guard !model.isBusyWithDisk else { return false }
        switch model.view {
        case .scanner:         return !model.cleanupSelection(in: .all).isEmpty
        case .duplicates:      return model.duplicateKind == .files
            ? !model.fileDuplicateSelection.isEmpty && !model.isScanningDuplicateFiles
            : model.canAccessPhotos && !model.photoSelection.isEmpty && !model.isRegroupingPhotos
        case .uninstaller:     return model.uninstallerTab == .installed
            ? !model.selectedApplicationIDs.isEmpty
            : !model.selectedLeftoverIdentifiers.isEmpty && !model.isLoadingApplicationLeftovers
        case .storageExplorer: return model.storageExplorer.canRemoveSelection
            && !model.storageExplorer.isMapSelectionPending
            && !model.isStorageExplorerMeasurementBlocked
        case .trash:           return (model.trashSummary?.itemCount ?? 0) > 0
        case .dashboard, .history: return false
        }
    }

    private func removeTapped() {
        switch model.view {
        case .scanner: model.requestCleanUp(in: .all)
        case .duplicates:
            if model.duplicateKind == .files {
                Task { await model.removeSelectedDuplicateFiles() }
            } else {
                Task { await model.deleteSelectedPhotos() }
            }
        case .uninstaller:
            if model.uninstallerTab == .installed {
                model.moveSelectedApplicationsToTrash()
            } else {
                Task { await model.requestLeftoverRemoval() }
            }
        case .storageExplorer: Task { await model.requestStorageExplorerRemoval() }
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
              ? "Moves selected items from all filters to the Trash."
              : model.view == .uninstaller && model.uninstallerTab == .installed
                ? "Moves selected apps and their related files to the Trash."
                : model.removeLabel)
    }

    /// Names the operation that blocks scans on the current page.
    @ViewBuilder
    private var headerCentre: some View {
        if model.isScanning, model.view != .scanner {
            backgroundWorkStatus(
                title: "Cleanup scan",
                detail: "\(model.scanProgress)% complete",
                progress: Double(model.scanProgress) / 100,
                isInterrupting: model.isInterruptingScan,
                onStop: { model.cancelScan() }
            )
        } else if model.storageExplorer.isLoading, model.view != .storageExplorer {
            backgroundWorkStatus(
                title: "Storage Explorer scan",
                detail: "\(model.storageExplorer.progress.fileCount.formatted()) files · "
                    + ByteFormatting.string(model.storageExplorer.progress.allocatedBytes),
                isInterrupting: model.storageExplorer.isInterrupting,
                onStop: { model.storageExplorer.cancel() }
            )
        } else if model.isScanningDuplicateFiles,
                  model.view != .duplicates || model.duplicateKind != .files {
            let progress = model.fileDuplicateProgress
            backgroundWorkStatus(
                title: "Duplicate file scan",
                detail: progress.map { "\($0.completed.formatted()) of \($0.total.formatted()) files" }
                    ?? "Preparing scan",
                progress: progress.flatMap { $0.total > 0 ? Double($0.completed) / Double($0.total) : nil },
                isInterrupting: model.isInterruptingFileDuplicateScan,
                onStop: { model.cancelFileDuplicateScan() }
            )
        } else if model.isSweepingPhotos,
                  model.view != .duplicates || model.duplicateKind != .photos {
            backgroundWorkStatus(
                title: "Duplicate photo scan",
                detail: "\(model.photoProgress?.percent ?? 0)% complete",
                progress: Double(model.photoProgress?.percent ?? 0) / 100,
                isInterrupting: model.isInterruptingPhotoSweep,
                onStop: { model.cancelPhotoSweep() }
            )
        } else if model.isPlanningAppUninstall, model.view != .uninstaller {
            backgroundWorkStatus(
                title: "Checking selected apps",
                detail: model.appUninstallPlanningDetail ?? "Finding related files",
                isInterrupting: model.isInterruptingAppUninstall,
                onStop: { model.resetAppUninstall() }
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
            Capsule().strokeBorder(Token.Fill.controlBorder, lineWidth: Token.hairline)
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
                if model.isScanning { model.cancelScan() } else { model.startScan() }
            } label: {
                if model.isInterruptingScan {
                    ScanInterruptionView()
                } else {
                    Label(
                        model.isScanning ? "Stop Scan" : "Scan",
                        systemImage: model.isScanning ? "stop.fill" : "magnifyingglass"
                    )
                }
            }
            .buttonStyle(PageActionButtonStyle())
            .controlSize(.large)
            .disabled(model.isInterruptingScan || (!model.isScanning && model.isBusyWithDisk))
        case .dashboard:
            Button { Task { await model.measureStorage() } } label: {
                Label("Refresh Overview", systemImage: "arrow.clockwise")
            }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk || model.isLoadingBreakdown)
        case .trash:
            Button { Task { await model.loadTrash() } } label: {
                Label("Refresh Trash", systemImage: "arrow.clockwise")
            }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk)
        case .uninstaller:
            if model.isShowingUninstallerLibrary {
                Button {
                    if model.uninstallerTab == .installed {
                        model.loadInstalledApplications()
                    } else {
                        model.loadApplicationLeftovers()
                    }
                } label: {
                    Label(model.uninstallerTab == .installed ? "Refresh Apps" : "Refresh Leftovers", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk || model.isLoadingApplicationLeftovers)
            }
        case .duplicates:
            if model.duplicateKind == .photos,
               model.canAccessPhotos, model.photoResults != nil, model.photoUnavailable == nil {
                Button { model.startPhotoSweep() } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PageActionButtonStyle())
                .disabled(model.isBusyWithDisk)
                .help("Scan the photo library again.")
            } else if model.duplicateKind == .files, model.fileDuplicateResults != nil {
                Button { model.startFileDuplicateScan() } label: {
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
            height: sizes.map(\.height).max() ?? 38
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
