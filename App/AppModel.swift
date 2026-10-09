import SwiftUI
import AppKit
import Observation
import MoppoCore

/// Owns navigation, shared presentation, and features that do not yet have separate models.
@MainActor
@Observable
final class AppModel {

    /// The preferences the engine must obey. Injected at launch; optional only so
    /// previews and tests can build a model without a store.
    @ObservationIgnored var settings: SettingsStore?
    @ObservationIgnored private let hasFullDiskAccess: () -> Bool
    let operations: OperationCoordinator
    let photoDuplicates: PhotoDuplicatesModel
    let uninstaller: AppUninstallerModel
    let cleanup: CleanupModel
    @ObservationIgnored private let cleanupScheduler = CleanupScheduler()
    @ObservationIgnored private var cleanupDestination: View?
    let fileDuplicates: FileDuplicatesModel
    let storageExplorer: StorageExplorerModel
    private(set) var launchAccess: LaunchAccess
    var isShowingWelcome: Bool { launchAccess.requiresOnboarding }

    init(
        settings: SettingsStore? = nil,
        launchAccess: LaunchAccess = .ready,
        hasFullDiskAccess: @escaping () -> Bool = { FullDiskAccess.isGranted },
        trashService: TrashService = TrashService(),
        cleanupHistoryService: CleanupHistoryService = CleanupHistoryService(),
        appUninstallPlanner: AppUninstallPlanner = AppUninstallPlanner(),
        homebrewUninstallService: HomebrewUninstallService = HomebrewAuthentication.service(),
        cleanupService: CleanupService = CleanupService(),
        uninstallerScanner: (any AppUninstallerScanning)? = nil,
        uninstallerRemover: (any AppUninstallRemoving)? = nil,
        cleanupScanner: any CleanupScanning = CleanupScanService(),
        cleanupRemover: (any CleanupRemoving)? = nil,
        fileDuplicateService: any FileDuplicatesScanning = FileDuplicateService(),
        fileDuplicateRemovalService: any FileDuplicatesRemoving = FileDuplicateRemovalService(),
        makePhotoService: @escaping (Bool) -> any PhotoDuplicatesServicing = { allowsNetwork in
            PhotoDuplicateService(
                library: PhotoKitLibrary(allowsNetworkFetch: allowsNetwork),
                visionRevision: UInt32(PhotoKitLibrary.featurePrintRevision)
            )
        }
    ) {
        self.settings = settings
        self.launchAccess = launchAccess
        self.hasFullDiskAccess = hasFullDiskAccess
        let operations = OperationCoordinator()
        self.operations = operations
        self.cleanup = CleanupModel(
            operations: operations,
            scanner: cleanupScanner,
            remover: cleanupRemover ?? cleanupService,
            preferences: { [weak settings] in
                CleanupModel.Preferences(
                    enabledCategories: settings.map { store in
                        Set(CategoryID.allCases.filter { store.isEnabled($0) })
                    },
                    excludedPaths: settings?.excludedFolderPaths ?? [],
                    excludedPatterns: settings?.excludedPatterns ?? [],
                    confirmBeforeCleanup: settings?.confirmBeforeCleanup ?? SettingsStore.Defaults.confirmBeforeCleanup,
                    keepReceipt: settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt
                )
            }
        )
        self.photoDuplicates = PhotoDuplicatesModel(
            operations: operations,
            allowsNetworkFetch: { [weak settings] in
                settings?.allowPhotoDownloads ?? SettingsStore.Defaults.allowPhotoDownloads
            },
            makeService: makePhotoService
        )
        self.fileDuplicates = FileDuplicatesModel(
            operations: operations,
            service: fileDuplicateService,
            removalService: fileDuplicateRemovalService,
            preferences: { [weak settings] in
                FileDuplicatesModel.Preferences(
                    excludedPaths: settings?.excludedFolderPaths ?? [],
                    excludedPatterns: settings?.excludedPatterns ?? [],
                    keepReceipt: settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt
                )
            }
        )
        self.trashService = trashService
        self.cleanupHistoryService = cleanupHistoryService
        self.uninstaller = AppUninstallerModel(
            operations: operations,
            scanner: uninstallerScanner ?? AppUninstallerScanService(planner: appUninstallPlanner),
            remover: uninstallerRemover ?? cleanupService,
            homebrewRemover: homebrewUninstallService,
            preferences: { [weak settings] in
                AppUninstallerModel.Preferences(
                    excludedPaths: settings?.excludedFolderPaths ?? [],
                    excludedPatterns: settings?.excludedPatterns ?? [],
                    keepReceipt: settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt
                )
            }
        )
        self.storageExplorer = StorageExplorerModel(settings: settings)
        operations.hasOtherOperation = { [weak self] in
            guard let self else { return false }
            return self.storageExplorer.isLoading
                || self.activity != nil
        }
        photoDuplicates.canRequestAccess = { [weak self] in
            guard let self else { return false }
            return self.view == .duplicates && self.duplicateKind == .photos && !self.isShowingWelcome
        }
        photoDuplicates.onEvent = { [weak self] event in self?.handlePhotoEvent(event) }
        fileDuplicates.onEvent = { [weak self] event in self?.handleFileDuplicateEvent(event) }
        fileDuplicates.refreshAfterRemoval = { [weak self] in
            await self?.refreshAfterRemoval(invalidateFileDuplicates: false)
        }
        cleanup.canScan = { [weak self] automatic in
            self?.checkDiskAccess(automatic: automatic) ?? false
        }
        cleanup.onEvent = { [weak self] event in self?.handleCleanupEvent(event) }
        cleanup.refreshAfterRemoval = { [weak self] in
            await self?.refreshAfterRemoval(invalidateCleanup: false)
        }
        cleanup.refreshLeftovers = { [weak self] identifiers in
            await self?.uninstaller.refreshLeftovers(afterRemoving: identifiers)
        }
        uninstaller.canPlan = { [weak self] in self?.checkDiskAccess() ?? false }
        uninstaller.onEvent = { [weak self] event in self?.handleUninstallerEvent(event) }
        uninstaller.refreshAfterRemoval = { [weak self] in await self?.refreshAfterRemoval() }
        cleanupScheduler.canCheck = { [weak self] in
            self?.checkDiskAccess(automatic: true) ?? false
        }
        cleanupScheduler.refreshVolume = { [weak self] in await self?.refreshVolumeInfo() }
        cleanupScheduler.conditions = { [weak self, weak settings] in
            guard let self, let settings else { return nil }
            return AutomaticScanPolicy.Conditions(
                lastFinished: self.cleanup.lastScanFinishedAt,
                cadence: settings.scanSchedule.cadence,
                requiresIdleAndPower: settings.idleOnly,
                isOnACPower: CleanupScheduler.isOnACPower,
                secondsSinceUserInput: CleanupScheduler.secondsSinceUserInput,
                isScanning: self.isBusyWithDisk
            )
        }
        cleanupScheduler.startScan = { [weak cleanup] in cleanup?.startScan(automatic: true) }
        if settings != nil { cleanupScheduler.start() }
    }

    func showWelcomeGuide() {
        launchAccess = .welcome
    }

    func finishWelcomeGuide() {
        launchAccess.finishOnboarding(hasFullDiskAccess: hasFullDiskAccess())
    }

    /// Keeps automatic scans off when the user continues with limited access.
    func checkDiskAccess(automatic: Bool = false) -> Bool {
        launchAccess.authorizeScan(hasFullDiskAccess: hasFullDiskAccess(), automatic: automatic)
    }

    enum View: String, CaseIterable, Identifiable {
        case dashboard, scanner, storageExplorer, uninstaller, history, trash, duplicates
        var id: String { rawValue }

        struct SidebarSection: Identifiable {
            let title: String
            let views: [View]
            var id: String { title }
        }

        /// Cleanup comes first. Tools and storage information follow it.
        static let sidebarSections: [SidebarSection] = [
            SidebarSection(title: "", views: [.scanner]),
            SidebarSection(title: "Tools", views: [.storageExplorer, .uninstaller, .duplicates]),
            SidebarSection(title: "Overview", views: [.dashboard, .history, .trash])
        ]

        static var sidebarViews: [View] { sidebarSections.flatMap(\.views) }

        var title: String {
            switch self {
            case .dashboard:    "Dashboard"
            case .scanner:      "Cleanup"
            case .storageExplorer: "Storage Explorer"
            case .uninstaller:  "App Uninstaller"
            case .history:      "History"
            case .trash:        "Trash"
            case .duplicates:   "Duplicates"
            }
        }

        /// Symbols for the sidebar views.
        var symbol: String {
            switch self {
            case .dashboard:    "gauge.with.needle"
            case .scanner:      "sparkles"
            case .storageExplorer: "externaldrive"
            case .uninstaller:  "xmark.app"
            case .history:      "clock"
            case .trash:        "trash"
            case .duplicates:   "square.on.square"
            }
        }

        /// Sparkles uses the same symbol in both selection states.
        var selectedSymbol: String {
            self == .scanner ? symbol : symbol + ".fill"
        }
    }

    enum Sheet: String, Identifiable {
        case cleanUp, emptyTrash
        var id: String { rawValue }
    }

    enum DuplicateKind: String, CaseIterable, Identifiable {
        case files, photos
        var id: String { rawValue }

        var title: String {
            switch self {
            case .files:  "Files"
            case .photos: "Photos"
            }
        }
    }

    // MARK: - Navigation

    /// The section on screen. There is no history behind it: the sidebar shows
    /// every section at once and never collapses, so "back" would only ever mean
    /// "the row above or below the one you can already see". The toolbar's arrows
    /// are gone with it — they also meant folders in the Storage Explorer, which
    /// is two things for one control, and those now live in that view's own bar.
    var view: View = .scanner {
        didSet {
            if oldValue != view { removalCompletion = nil }
            if oldValue == .scanner, view != .scanner {
                cleanupCompletion = nil
            }
        }
    }
    var duplicateKind: DuplicateKind = .files {
        didSet {
            if oldValue != duplicateKind { removalCompletion = nil }
        }
    }

    /// Edit › Find (⌘F) bumps this; the view on screen moves focus to its search
    /// field when it changes. A counter and not a flag, so a second ⌘F after the
    /// user has clicked away focuses again with nothing to reset in between.
    private(set) var findRequest = 0

    /// The views with a list to search. Find is disabled everywhere else, not left
    /// as a key that does nothing.
    var canFind: Bool {
        switch view {
        case .trash, .history, .uninstaller: activity == nil
        case .dashboard, .scanner, .storageExplorer, .duplicates: false
        }
    }

    func requestFind() {
        guard canFind else { return }
        findRequest += 1
    }

    struct CleanupCompletion: Identifiable {
        let id = UUID()
        let outcome: CleanupOutcome
    }
    private(set) var cleanupCompletion: CleanupCompletion?

    struct RemovalCompletion: Identifiable {
        let id = UUID()
        let destination: View
        let title: String
        let detail: String
        var isSuccess = true

        var dismissesAutomatically: Bool {
            isSuccess && (destination == .storageExplorer || destination == .uninstaller || destination == .duplicates)
        }
    }
    private(set) var removalCompletion: RemovalCompletion?

    func dismissRemovalCompletion() {
        removalCompletion = nil
    }

    func automaticallyDismissRemovalCompletion(_ id: UUID) async {
        guard let completion = removalCompletion,
              completion.id == id,
              completion.dismissesAutomatically else { return }
        let destination = completion.destination

        do {
            try await Task.sleep(for: .seconds(destination == .uninstaller ? 1 : 2))
            // Keep the result visible until the refreshed list is ready.
            while (destination == .storageExplorer && storageExplorer.isLoading)
                || (destination == .uninstaller && uninstaller.isLoadingApplicationLeftovers) {
                guard removalCompletion?.id == id, view == destination else { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        } catch {
            return
        }

        guard removalCompletion?.id == id, view == destination else { return }
        dismissRemovalCompletion()
    }

    private func completeTrashRemoval(_ outcome: CleanupOutcome, in destination: View, extraFailures: Int = 0) {
        let remaining = outcome.failed.count + extraFailures
        let success = remaining == 0 && outcome.removedCount > 0
        let count = outcome.removedCount
        var detail = "\(count) \(count == 1 ? "item" : "items") · \(ByteFormatting.string(outcome.removedBytes))"
        if remaining > 0 {
            detail += "\n\(remaining) \(remaining == 1 ? "item was" : "items were") not removed."
        }
        removalCompletion = RemovalCompletion(
            destination: destination,
            title: success ? "Moved to Trash" : (count > 0 ? "Some items were not removed" : "Nothing was removed"),
            detail: detail,
            isSuccess: success
        )
    }

    func showDashboardAfterCleanup(_ id: UUID) {
        guard cleanupCompletion?.id == id else { return }
        view = .dashboard
    }

    /// Starts the first Cleanup scan with the access the user chose.
    func startInitialCleanupScan() {
        guard checkDiskAccess() else { return }
        guard view == .scanner, cleanup.scanResults == nil, !cleanup.hasStartedInitialScan,
              cleanupCompletion == nil, !isBusyWithDisk else { return }
        cleanup.startScan(refreshOverview: false)
    }

    // MARK: - Data

    var volume: VolumeInfo?
    var breakdown: StorageBreakdown?
    var snapshots: [SnapshotInfo] = []

    var isLoadingBreakdown = false
    /// The first Dashboard task has finished its complete refresh. Cached figures
    /// may be restored before then, but they are only inputs to that refresh — not a
    /// finished state to flash on screen for a moment before measurement begins.
    private(set) var hasCompletedInitialDashboardLoad = false
    var isDashboardLoading: Bool {
        !hasCompletedInitialDashboardLoad || isLoadingBreakdown
    }

    var snapshotsExpanded = false

    // MARK: - Selection

    var activeSheet: Sheet?

    /// What is left to say when an operation did not simply do what it said.
    ///
    /// Two kinds of thing reach here: a failure or a partial failure, and a
    /// success that leaves the user something to do somewhere else — deleting
    /// photos frees nothing until Recently Deleted is emptied in Photos, and no
    /// part of this app could say so.
    ///
    /// Until 21 Sep 2026 all of these were a line in the window's footer, next to
    /// the ordinary reports of things going right. That made a failure look
    /// exactly like a success, and the next operation overwrote it before it had
    /// been read. The footer is gone, and the plain successes went with it: each
    /// view shows its own result — rows leave the list, figures change, a done
    /// page says what it did. What is here cannot show itself that way, so it
    /// waits to be dismissed.
    ///
    /// Never a cancellation: the user stopped it and knows.
    struct Notice: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var message: String
    }

    var notice: Notice?

    func report(_ title: String, _ message: String) {
        notice = Notice(title: title, message: message)
    }

    /// The disk operation in progress, if any. The window is covered while it
    /// runs. See `ActivityOverlay`.
    ///
    /// Cleared before the post-removal refresh. That disk walk has its own page
    /// state. Keeping the scrim visible made the cleanup appear frozen.
    private(set) var activity: Activity?

    enum Activity: Equatable {
        case cleaningUp(itemCount: Int, totalBytes: Int64)
        case emptyingTrash(itemCount: Int, totalBytes: Int64)
        case removingDuplicateFiles(itemCount: Int, totalBytes: Int64)
        case removingStorageItems(itemCount: Int, totalBytes: Int64)
        case reviewingStorageItems(itemCount: Int)
        case restoringTrashItem(name: String)
        case uninstalling(applicationName: String, applicationOnly: Bool, waitingToQuit: Bool, usingHomebrew: Bool = false)
        case waitingForApplicationsToQuit(names: [String])

        var title: String {
            switch self {
            case .cleaningUp(let count, _):
                let items = count == 1 ? "item" : "items"
                return "Moving \(count) \(items) to the Trash"
            case .emptyingTrash:
                return "Emptying the Trash"
            case .removingDuplicateFiles(let count, _):
                let files = count == 1 ? "file" : "files"
                return "Moving \(count) duplicate \(files) to the Trash"
            case .removingStorageItems(let count, _):
                let items = count == 1 ? "item" : "items"
                return "Moving \(count) \(items) to the Trash"
            case .reviewingStorageItems(let count):
                let items = count == 1 ? "item" : "items"
                return "Reviewing \(count) \(items)"
            case .restoringTrashItem(let name):
                return "Putting Back \(name)"
            case .uninstalling(let name, _, let waiting, _):
                return waiting ? "Waiting for \(name) to quit" : "Uninstalling \(name)"
            case .waitingForApplicationsToQuit(let names):
                return "Waiting for \(ListFormatter.localizedString(byJoining: names)) to quit"
            }
        }

        /// Explains why the current disk operation can take time.
        var detail: String {
            switch self {
            case .cleaningUp(_, let bytes),
                 .emptyingTrash(_, let bytes),
                 .removingStorageItems(_, let bytes):
                return "\(ByteFormatting.string(bytes)). Each item is measured on disk "
                    + "before it goes, so large folders take a moment."
            case .removingDuplicateFiles(_, let bytes):
                // Not measured: re-hashed. The keeper and every chosen copy are read
                // in full again, which is what makes a set of large videos slow.
                return "\(ByteFormatting.string(bytes)). Each copy and its keeper are "
                    + "verified byte for byte before it goes, so large files take a moment."
            case .waitingForApplicationsToQuit:
                return "Save your work if an app asks. Moppo waits for the apps to close."
            case .reviewingStorageItems:
                return "Moppo is checking the selected items before moving them to the Trash."
            case .restoringTrashItem:
                return "Moving the item to its original location."
            case .uninstalling(_, let applicationOnly, let waiting, let usingHomebrew):
                if waiting {
                    return "The application and its helpers are asked to quit. "
                        + "Nothing is removed until they are gone."
                }
                if usingHomebrew {
                    return "Homebrew removes the package. Moppo then moves its related data to the Trash."
                }
                return applicationOnly
                    ? "Related files stay on disk."
                    : "The application moves first. Related data stays if that move fails."
            }
        }
    }

    var isCleaningUp: Bool {
        if case .cleaningUp? = activity { return true }
        return false
    }
    var isRemovingDuplicateFiles: Bool {
        if case .removingDuplicateFiles? = activity { return true }
        return false
    }
    var isRemovingStorageItems: Bool {
        if case .removingStorageItems? = activity { return true }
        return false
    }
    var isShowingAppDataAccessAlert = false

    var isStorageExplorerMeasurementBlocked: Bool {
        operations.activeOperation != nil
            || activity != nil
    }

    /// Share the operation guard with extracted feature models.
    var isBusyWithDisk: Bool { operations.isBusy }

    var storageExplorerRemoveLabel: String {
        guard !storageExplorer.isMapSelectionPending else { return "Move to Trash" }
        let count = storageExplorer.selectedItems.count
        guard count > 0 else { return "Move to Trash" }
        return "Move to Trash (\(ByteFormatting.string(storageExplorer.selectedBytes)))"
    }

    func requestStorageExplorerRemoval() async {
        guard storageExplorer.canRemoveSelection, !isBusyWithDisk else { return }
        let selectedItems = storageExplorer.selectedItems
        removalCompletion = nil
        let presentation = OperationPresentationDuration()
        activity = .reviewingStorageItems(itemCount: selectedItems.count)

        do {
            let review = try await storageExplorer.reviewSelectionForRemoval(selectedItems)
            guard let review else {
                activity = nil
                return
            }
            // Show why removal stopped when the selection fails validation.
            guard review.isReady else {
                activity = nil
                if !review.changedPaths.isEmpty {
                    report(
                        "The Selection Changed",
                        "Some of those items are not what they were when you picked them. "
                            + "Review the updated list and try again."
                    )
                } else if !review.protectedPaths.isEmpty {
                    report(
                        "Some Items Are Protected",
                        "Moppo will not remove some of the selected items. "
                            + "Review the list and try again."
                    )
                } else {
                    // The third way a review is not ready: nothing selected is
                    // still there to remove.
                    report(
                        "Nothing Left to Remove",
                        "The selected items are no longer in this folder."
                    )
                }
                return
            }
            await performStorageExplorerRemoval(review.items, presentation: presentation)
        } catch is CancellationError {
            activity = nil
        } catch {
            activity = nil
            report(
                "The Selection Could Not Be Checked",
                "Moppo could not check the selected items. Nothing was removed."
            )
        }
    }

    private func performStorageExplorerRemoval(
        _ items: [StorageExplorerItem],
        presentation: OperationPresentationDuration
    ) async {
        guard !items.isEmpty else {
            activity = nil
            return
        }
        let removal = Activity.removingStorageItems(
            itemCount: items.count,
            totalBytes: items.reduce(0) { $0 + $1.allocatedBytes }
        )
        activity = removal
        var presentation = presentation
        presentation.extend(toShow: removal.progressIcon)

        do {
            let outcome = try await storageExplorer.remove(items, keepReceipt: keepReceipt)
            try? await presentation.wait()
            completeTrashRemoval(outcome, in: .storageExplorer)
        } catch is CancellationError {
            // The user stopped it.
        } catch {
            report(
                "The Items Could Not Be Moved",
                "The selected items could not move to the Trash. Nothing was removed."
            )
        }

        activity = nil
        await refreshAfterRemoval()
    }

    // MARK: - Derived

    /// Names the action for the current page.
    var removeLabel: String {
        switch view {
        case .scanner:
            "Move to Trash (\(ByteFormatting.string(cleanup.cleanupSelectionBytes(in: .all))))"
        case .duplicates:
            duplicateKind == .files ? fileDuplicates.removeLabel : photoDuplicates.removeLabel
        case .uninstaller:
            uninstaller.uninstallerRemoveLabel
        case .storageExplorer:
            storageExplorerRemoveLabel
        case .trash:
            "Empty Trash"
        case .dashboard, .history:
            "Remove"
        }
    }

    var boot: SnapshotInfo? { snapshots.first(where: \.isBootSnapshot) }
    var removableSnapshots: [SnapshotInfo] { snapshots.filter { !$0.isBootSnapshot } }

    /// Opens the Scanner on one of its filtered lists.
    ///
    /// The order matters: the filter is set before the view, so the Scanner draws
    /// the requested list on its first frame instead of showing the whole outline
    /// for a frame and then replacing it.
    func showScanner(filtered filter: CleanupModel.ScanFilter) {
        cleanup.scanFilter = filter
        view = .scanner
    }

    /// All removal actions use the saved receipt setting.
    var keepReceipt: Bool { settings?.keepReceipt ?? SettingsStore.Defaults.keepReceipt }

    /// The disk changed, so the cached breakdown and the Trash summary are both
    /// wrong. They run together: the Trash read is usually quick and feeds the
    /// sidebar count, and it should not queue behind a 20-second walk.
    private func refreshAfterRemoval(invalidateCleanup: Bool = true, invalidateFileDuplicates: Bool = true) async {
        if invalidateFileDuplicates { fileDuplicates.invalidateResults() }
        if invalidateCleanup { cleanup.invalidateResults() }
        // Every cached Explorer level is stale too: a folder measured before a
        // Scanner clean-up came back from the cache with its old figure.
        storageExplorer.invalidateCache()
        if view == .storageExplorer, !isStorageExplorerMeasurementBlocked {
            storageExplorer.refreshIfNeeded()
        }
        cleanup.pruneVanishedEntries()
        async let trash: Void = loadTrash()
        // `removal` marks this measurement as the post-clean-up baseline, which is
        // what "since the last clean-up" reads and what the ring never thins away.
        await measureStorage(trigger: .removal)
        await trash
    }

    /// What is left to say once a clean-up has finished, or nil when it did what
    /// it said it would.
    ///
    /// Nothing is reported for a clean run. The figures were on the confirmation
    /// sheet before the user agreed — the size, and how much of it APFS will
    /// actually give back — and the result is the rows leaving the list and the
    /// Dashboard being measured again. A partial failure is different in kind:
    /// silent partial failure is how a cleaner loses trust.
    private static func cleanUpNotice(_ outcome: CleanupOutcome) -> Notice? {
        guard !outcome.failed.isEmpty else { return nil }
        let count = outcome.failed.count
        let one = count == 1
        if outcome.removedCount == 0 {
            return Notice(
                title: "Nothing Was Removed",
                message: one
                    ? "The selected item could not be removed. It is where it was."
                    : "None of the \(count) selected items could be removed. "
                        + "They are where they were."
            )
        }
        return Notice(
            title: "Some Items Could Not Be Removed",
            message: "\(count) \(one ? "item" : "items") could not be removed; "
                + "the other \(outcome.removedCount) moved to the Trash."
        )
    }

    private static func isAppDataPath(_ path: String) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).path
        return path.hasPrefix(library + "/Containers/")
            || path.hasPrefix(library + "/Group Containers/")
    }

    // MARK: - Cleanup history

    private let cleanupHistoryService: CleanupHistoryService
    var cleanupHistory: CleanupHistorySummary?
    var isLoadingCleanupHistory = false

    func loadCleanupHistory() async {
        guard !isLoadingCleanupHistory else { return }
        isLoadingCleanupHistory = true
        let service = cleanupHistoryService
        cleanupHistory = await Task.detached {
            service.summary()
        }.value
        isLoadingCleanupHistory = false
    }

    // MARK: - Trash

    private let trashService: TrashService
    @ObservationIgnored private var trashLoadID: UUID?
    var trashSummary: TrashSummary?
    var selectedTrashItemID: TrashItem.ID?
    private var pendingTrashReveal: CleanupHistoryItem?

    func showInTrash(_ item: CleanupHistoryItem) {
        guard item.state == .availableInTrash, item.trashedURL != nil else { return }
        pendingTrashReveal = item
        selectedTrashItemID = nil
        trashSummary = nil
        view = .trash
    }

    func loadTrash() async {
        let loadID = UUID()
        trashLoadID = loadID
        // Load every item so sorting, search, and History links use the complete Trash.
        let summary = try? await trashService.summary(limit: Int.max)
        guard trashLoadID == loadID, !Task.isCancelled else { return }
        trashSummary = summary
        if let request = pendingTrashReveal, let url = request.trashedURL {
            pendingTrashReveal = nil
            if let item = trashSummary?.items.first(where: {
                $0.url.standardizedFileURL == url.standardizedFileURL
            }), let identity = request.trashedIdentity, FileIdentity.of(item.url) == identity {
                selectedTrashItemID = item.id
            } else if trashSummary != nil {
                report("Item Not Found", "This item is no longer available in the Trash.")
            }
        }
        if let selectedTrashItemID,
           trashSummary?.items.contains(where: { $0.id == selectedTrashItemID }) != true {
            self.selectedTrashItemID = nil
        }
    }

    /// Last measured size per category, for the Preferences › Categories rows.
    /// Absent until a scan has run — those rows show an em dash rather than `0 B`,
    /// which would claim a measurement that never happened.
    var categorySizes: [CategoryID: Int64] {
        guard let results = cleanup.scanResults else { return [:] }
        return Dictionary(uniqueKeysWithValues: results.categories.map { ($0.categoryID, $0.totalBytes) })
    }

    func emptyTrash() async {
        guard !isBusyWithDisk else { return }
        activeSheet = nil
        removalCompletion = nil
        var presentation = OperationPresentationDuration()
        let emptying = Activity.emptyingTrash(
            itemCount: trashSummary?.itemCount ?? 0,
            totalBytes: trashSummary?.totalBytes ?? 0
        )
        activity = emptying
        presentation.extend(toShow: emptying.progressIcon)
        do {
            let result = try await trashService.empty(privilegedFallback: true)
            try? await presentation.wait()
            removalCompletion = RemovalCompletion(
                destination: .trash,
                title: result.skipped == 0 ? "Trash emptied" : "Some items remain in Trash",
                detail: result.skipped == 0
                    ? "\(ByteFormatting.string(result.freedBytes)) recovered."
                    : "\(result.skipped) \(result.skipped == 1 ? "item could" : "items could") not be removed.",
                isSuccess: result.skipped == 0
            )
        } catch {
            // Do not pretend. Name the remedy: this is what a denied read looks
            // like, and the permission is the fix.
            report(
                "The Trash Could Not Be Read",
                "Grant Moppo Full Disk Access in System Settings, Privacy & Security, "
                    + "then try again."
            )
        }
        // Re-read under the scrim, so the Trash never lifts it over rows that are
        // gone. The disk walk runs after, on the Dashboard's own skeleton.
        await loadTrash()
        activity = nil
        // Emptying the Trash frees space, so this measurement is a clean-up
        // baseline like any other removal's.
        await measureStorage(trigger: .removal)
    }

    func putBack(_ item: TrashItem) async {
        guard !isBusyWithDisk else { return }
        activity = .restoringTrashItem(name: item.name)
        var restored = false
        do {
            // The row leaves the Trash list below, which is the whole report.
            try await trashService.putBack(item)
            restored = true
            fileDuplicates.invalidateResults()
            storageExplorer.invalidateCache()
            cleanup.invalidateResults()
        } catch TrashError.destinationOccupied {
            report(
                "\(item.name) Was Not Put Back",
                "Something is already at the place it came from. "
                    + "Move that aside, or drag this out of the Trash yourself."
            )
        } catch {
            report("\(item.name) Was Not Put Back", "It is still in the Trash.")
        }
        await loadTrash()
        await loadCleanupHistory()
        activity = nil
        if restored, checkDiskAccess(automatic: true) {
            await measureStorage()
        }
    }

    // MARK: - Loading

    // MARK: - iCloud

    private let iCloudService = ICloudStorageService()
    /// Nil until measured, and nil again if iCloud Drive is not signed in — the card
    /// disappears rather than rendering an empty account, which would read as "you
    /// have nothing in iCloud".
    var iCloudStorage: ICloudStorage?

    /// The plan size the user set in Preferences, if any. macOS reports no such
    /// figure, so without this the service infers it from the free space.
    var iCloudPlanBytes: Int64?

    func loadICloud() async {
        guard checkDiskAccess(automatic: true) else { return }
        iCloudStorage = try? await iCloudService.storage(planBytes: iCloudPlanBytes)
    }

    private let diskInfo = DiskInfoService()
    private let snapshotService = SnapshotService()
    /// Never follows symlinks. The card's contract is that every byte of capacity
    /// is accounted for exactly once, and a link's target already belongs to
    /// whichever category owns its real location — counting it again here put a
    /// 228 GB disk at 274 GB and pushed the bar off the card.
    private let breakdownService = StorageBreakdownService()
    @ObservationIgnored private lazy var lowDiskNotifications = LowDiskNotificationService()
    @ObservationIgnored private var needsPostCleanupMeasurement = false

    /// Last measured figures, shown immediately on launch.
    private(set) var measuredAt: Date?
    var breakdownIsStale: Bool {
        if launchAccess == .limited { return true }
        guard let measuredAt else { return true }
        return Date().timeIntervalSince(measuredAt) > BreakdownCache.freshnessWindow
    }

    /// Loads saved figures and storage history. Full Disk Access permits a new measurement at launch.
    func loadDashboard() async {
        guard !isShowingWelcome else { return }
        // A recreated main window runs this task again. Treat that refresh like the
        // first one too, rather than briefly presenting cached values as final.
        hasCompletedInitialDashboardLoad = false
        defer { hasCompletedInitialDashboardLoad = true }

        if let cached = BreakdownCache.load() {
            volume = cached.volume
            breakdown = cached.breakdown
            measuredAt = cached.measuredAt
        }

        // Snapshot listing touches no user files and is safe on every launch.
        // `measureStorage` refreshes volume totals and checks the low-space threshold.
        snapshots = (try? await snapshotService.listAll()) ?? []

        // The growth report is dated history, so the one the previous session left
        // is already true. Reading it first puts it on screen at once instead of
        // leaving the card blank for the length of a disk walk.
        await loadStorageHistory()

        if checkDiskAccess(automatic: true) {
            await measureStorage(trigger: .launch)
        } else {
            await refreshVolumeInfo(notifyLowSpace: false)
        }
    }

    /// Walks the disk. Only ever called deliberately.
    ///
    /// - Parameter trigger: what caused this measurement. It is stored with the
    ///   snapshot, and `removal` is the one "since the last clean-up" reads, so a
    ///   wrong trigger costs the user a baseline rather than a figure.
    func measureStorage(trigger: SnapshotTrigger = .manual) async {
        let automatic = trigger == .launch || trigger == .scheduled || trigger == .removal
        guard checkDiskAccess(automatic: automatic) else { return }
        guard !isLoadingBreakdown else {
            if trigger == .removal { needsPostCleanupMeasurement = true }
            return
        }
        isLoadingBreakdown = true
        let presentation = OperationPresentationDuration()
        defer {
            isLoadingBreakdown = false
            if needsPostCleanupMeasurement {
                needsPostCleanupMeasurement = false
                Task { await measureStorage(trigger: .removal) }
            }
        }

        // iCloud rides along with every measurement, so the account card stays in
        // step with the main card. Cheap enough to piggyback: one `brctl` call and
        // a walk of the ubiquity container, where evicted files are stubs on disk.
        Task { await self.loadICloud() }

        // `diskutil info` is cheap and not TCC-gated. Refreshing here keeps the menu
        // bar, Dashboard warning and system notification in step after cleanup too.
        await refreshVolumeInfo()

        // `measure` rather than `breakdown`: the same single walk, with the folder
        // tables it produced kept instead of thrown away. The growth report reads
        // those, and a second traversal to collect them would double the cost of
        // the most expensive measurement in the app.
        guard let measured = try? await breakdownService.measure() else {
            try? await presentation.wait()
            return
        }
        breakdown = measured.breakdown

        // The walk takes time. Read the volatile volume figures again, then put
        // Available, Free, and the sidebar on this one completed snapshot.
        await refreshVolumeInfo()
        measuredAt = Date()

        if let volume, let breakdown {
            BreakdownCache(volume: volume, breakdown: breakdown, measuredAt: Date()).save()
        }

        await recordSnapshot(of: measured, trigger: trigger)
        try? await presentation.wait()
    }

    // MARK: - What grew

    /// The ring of dated measurements the Dashboard compares. One JSON file per
    /// measurement; ``StorageSnapshotStore`` documents the retention rules.
    private let snapshotStore = StorageSnapshotStore()

    /// Every stored measurement, newest first. Held in memory so that changing the
    /// baseline is arithmetic over figures already read, not a second disk walk.
    @ObservationIgnored private var storageHistory: [StorageSnapshot] = []

    /// What changed since the chosen baseline.
    ///
    /// `nil` until the history has been read. The Dashboard draws no growth card at
    /// all until then, rather than announcing "first measurement" before it has
    /// looked at what is stored.
    private(set) var growth: GrowthComparison?

    private(set) var hasCleanupGrowthBaseline = false

    /// Keep explicit choices. Without a choice, use the latest cleanup when available.
    private var preferredGrowthBaseline: GrowthBaseline? = UserDefaults.standard.string(forKey: "growthBaseline")
        .flatMap(GrowthBaseline.init(rawValue:))
        .flatMap { $0 == .previousMeasurement ? nil : $0 }

    var growthBaseline: GrowthBaseline {
        get {
            preferredGrowthBaseline == .sevenDays || !hasCleanupGrowthBaseline
                ? .sevenDays : .lastCleanup
        }
        set {
            guard newValue != .previousMeasurement else { return }
            preferredGrowthBaseline = newValue
            UserDefaults.standard.set(newValue.rawValue, forKey: "growthBaseline")
            recomputeGrowth()
        }
    }

    /// Reads the stored measurements without walking anything.
    private func loadStorageHistory() async {
        let store = snapshotStore
        storageHistory = await Task.detached(priority: .utility) { store.load() }.value
        recomputeGrowth()
    }

    /// Stores one finished measurement, then recomputes the report.
    ///
    /// All of it runs off the main actor: ``SnapshotCapture`` reads one `device:inode`
    /// per recorded folder — a few hundred on this Mac — and the store then writes a
    /// file and prunes the ring. Only the finished history comes back.
    ///
    /// A measurement whose segments do not sum to capacity is never stored:
    /// ``SnapshotCapture/snapshot(from:trigger:now:id:minimumNodeBytes:maximumNodes:identity:)``
    /// returns nil for it. One dropped snapshot costs one comparison; a stored bad
    /// one would poison every future comparison.
    private func recordSnapshot(
        of measurement: StorageMeasurement,
        trigger: SnapshotTrigger
    ) async {
        let store = snapshotStore
        storageHistory = await Task.detached(priority: .utility) { () -> [StorageSnapshot] in
            if let snapshot = SnapshotCapture.snapshot(from: measurement, trigger: trigger) {
                try? store.save(snapshot)
            }
            return store.load()
        }.value
        recomputeGrowth()
    }

    private func recomputeGrowth() {
        hasCleanupGrowthBaseline = storageHistory.contains { $0.trigger == .removal }
        growth = StorageGrowth.comparison(growthBaseline, in: storageHistory)
    }

    /// Preferences › Advanced › "Clear measurement history".
    ///
    /// The breakdown cache is a different file and a different button: this one
    /// removes the dated measurements the Dashboard subtracts, and the next two
    /// measurements start a new history.
    func clearMeasurementHistory() {
        try? snapshotStore.clear()
        storageHistory = []
        recomputeGrowth()
    }

    /// Opens the Storage Explorer at the folder the growth report named.
    ///
    /// The Explorer measures the *parent*, because it lists a folder's children:
    /// opening the changed folder itself would show what is inside it and hide the
    /// row the user clicked. The row is selected once that measurement arrives —
    /// the Explorer clears its selection on every load, so the request travels with
    /// the navigation instead of being written afterwards.
    ///
    /// One disk walk at a time, like every other start button: during a scan or a
    /// removal the click is answered with a reason rather than starting a second
    /// measurement underneath the first.
    func revealGrowth(_ attribution: GrowthAttribution) {
        guard !isBusyWithDisk else {
            report(
                "Moppo Is Already Measuring",
                "Wait for the measurement in progress to finish, then open the folder."
            )
            return
        }
        let url = URL(fileURLWithPath: attribution.path)
        storageExplorer.selectLocation(url.deletingLastPathComponent(), revealing: url)
        view = .storageExplorer
    }

    /// Refreshes only the cheap volume totals, without walking user folders. This is
    /// safe to run periodically and is the observation point for low-space alerts.
    private func refreshVolumeInfo(notifyLowSpace: Bool = true) async {
        volume = (try? await diskInfo.volumeInfo()) ?? volume
        if let volume, let breakdown {
            self.breakdown = breakdown.reconcilingVolume(
                capacityBytes: volume.capacityBytes,
                freeBytes: volume.freeBytes
            )
        }
        guard notifyLowSpace, let volume, let settings else { return }
        await lowDiskNotifications.observe(
            freeBytes: volume.freeBytes,
            volumeName: volume.name,
            thresholdGB: settings.warnBelowGB
        )
    }

    // MARK: - Cleanup presentation

    private func handleCleanupEvent(_ event: CleanupModel.Event) {
        switch event {
        case .scanStarted(let automatic, let refreshOverview):
            cleanupCompletion = nil
            if !automatic { view = .scanner }
            if refreshOverview {
                Task { await measureStorage(trigger: automatic ? .scheduled : .scan) }
            }
        case .confirmationRequested:
            activeSheet = .cleanUp
        case .confirmationDismissed:
            if activeSheet == .cleanUp { activeSheet = nil }
        case .operationStarted:
            cleanupDestination = view
            cleanupCompletion = nil
            removalCompletion = nil
        case .waitingForApplications(let names):
            activity = .waitingForApplicationsToQuit(names: names)
        case .removalStarted(let count, let bytes):
            activity = .cleaningUp(itemCount: count, totalBytes: bytes)
        case .removed(let outcome):
            let destination = cleanupDestination ?? view
            if outcome.permissionDenied.contains(where: Self.isAppDataPath) {
                isShowingAppDataAccessAlert = true
            } else if destination == .scanner, let unfinished = Self.cleanUpNotice(outcome) {
                notice = unfinished
            }
            if destination != .scanner { completeTrashRemoval(outcome, in: destination) }
            if view == .scanner, outcome.failed.isEmpty, outcome.removedCount > 0,
               outcome.trashedCount == outcome.removedCount, outcome.deletedCount == 0 {
                cleanupCompletion = CleanupCompletion(outcome: outcome)
            }
        case .operationFinished:
            activity = nil
            cleanupDestination = nil
        case .failure(let title, let message):
            report(title, message)
        }
    }

    // MARK: - Uninstaller presentation

    private func handleUninstallerEvent(_ event: AppUninstallerModel.Event) {
        switch event {
        case .planningStarted:
            view = .uninstaller
        case .operationStarted:
            activeSheet = nil
            removalCompletion = nil
        case .uninstalling(let name, let applicationOnly, let waiting, let homebrew):
            activity = .uninstalling(
                applicationName: name, applicationOnly: applicationOnly,
                waitingToQuit: waiting, usingHomebrew: homebrew
            )
        case .leftoverRemovalStarted(let count, let bytes):
            activity = .cleaningUp(itemCount: count, totalBytes: bytes)
        case .leftoversRemoved(let outcome):
            if outcome.permissionDenied.contains(where: Self.isAppDataPath) {
                isShowingAppDataAccessAlert = true
            }
            completeTrashRemoval(outcome, in: .uninstaller)
        case .operationFinished:
            activity = nil
        case .failure(let title, let message):
            report(title, message)
        }
    }

    // MARK: - File duplicate presentation

    private func handleFileDuplicateEvent(_ event: FileDuplicatesModel.Event) {
        switch event {
        case .scanStarted:
            removalCompletion = nil
            view = .duplicates
            duplicateKind = .files
        case .removalStarted(let count, let bytes):
            removalCompletion = nil
            activity = .removingDuplicateFiles(itemCount: count, totalBytes: bytes)
        case .removed(let outcome, let extraFailures):
            completeTrashRemoval(outcome, in: .duplicates, extraFailures: extraFailures)
            if outcome.permissionDenied.contains(where: Self.isAppDataPath) {
                isShowingAppDataAccessAlert = true
            }
        case .removalFinished:
            activity = nil
        case .failure(let title, let message):
            report(title, message)
        }
    }

    // MARK: - Photo presentation

    private func handlePhotoEvent(_ event: PhotoDuplicatesModel.Event) {
        switch event {
        case .scanStarted:
            removalCompletion = nil
            view = .duplicates
            duplicateKind = .photos
        case .deletionStarted:
            removalCompletion = nil
        case .deleted(let count):
            removalCompletion = RemovalCompletion(
                destination: .duplicates,
                title: "Moved to Recently Deleted",
                detail: "\(count) \(count == 1 ? "photo" : "photos"). You can recover them in Photos for up to 30 days."
            )
        case .failure(let title, let message):
            report(title, message)
        }
    }

}
