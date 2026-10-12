import SwiftUI
import AppKit
import Observation
import MoppoCore

/// Creates feature models and owns navigation, onboarding, access checks, and shared presentation.
@MainActor
@Observable
final class AppModel {

    /// The preferences the engine must obey. Injected at launch; optional only so
    /// previews and tests can build a model without a store.
    @ObservationIgnored var settings: SettingsStore?
    @ObservationIgnored private let hasFullDiskAccess: () -> Bool
    let dashboard: DashboardModel
    let recovery: RecoveryModel
    @ObservationIgnored private lazy var lowDiskNotifications = LowDiskNotificationService()
    let operations: OperationCoordinator
    let photoDuplicates: PhotoDuplicatesModel
    let uninstaller: AppUninstallerModel
    let cleanup: CleanupModel
    @ObservationIgnored private let cleanupScheduler = CleanupScheduler()
    @ObservationIgnored private var cleanupDestination: View?
    let fileDuplicates: FileDuplicatesModel
    let storageExplorer: StorageExplorerModel
    private(set) var launchAccess: LaunchAccess
    let onboardingProgress: OnboardingProgress?
    var isShowingWelcome: Bool { launchAccess.requiresOnboarding }

    init(
        settings: SettingsStore? = nil,
        launchAccess: LaunchAccess = .ready,
        onboardingProgress: OnboardingProgress? = nil,
        hasFullDiskAccess: @escaping () -> Bool = { FullDiskAccess.isGranted },
        trashService: any TrashServicing = TrashService(),
        historyReader: (any CleanupHistoryReading)? = nil,
        dashboardService: any DashboardMeasuring = DashboardMeasurementService(),
        dashboardPersistence: any DashboardPersisting = DashboardPersistence(),
        cleanupHistoryService: CleanupHistoryService = CleanupHistoryService(),
        appUninstallPlanner: AppUninstallPlanner = AppUninstallPlanner(),
        homebrewUninstallService: HomebrewUninstallService = HomebrewAuthentication.service(),
        cleanupService: CleanupService = CleanupService(),
        uninstallerScanner: (any AppUninstallerScanning)? = nil,
        uninstallerRemover: (any AppUninstallRemoving)? = nil,
        storageExplorerService: any StorageExplorerScanning = StorageExplorerService(),
        storageExplorerRemover: any StorageExplorerRemoving = StorageExplorerRemovalService(),
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
        self.onboardingProgress = onboardingProgress
        if launchAccess.requiresOnboarding { onboardingProgress?.begin() }
        self.hasFullDiskAccess = hasFullDiskAccess
        let operations = OperationCoordinator()
        self.operations = operations
        self.cleanup = CleanupModel(
            operations: operations,
            scanner: cleanupScanner,
            remover: cleanupRemover ?? cleanupService,
            preferences: { [weak settings] in
                let removal = RemovalPreferences(settings: settings)
                return CleanupModel.Preferences(
                    enabledCategories: settings.map { store in
                        Set(CategoryID.allCases.filter { store.isEnabled($0) })
                    },
                    excludedPaths: removal.excludedPaths,
                    excludedPatterns: removal.excludedPatterns,
                    confirmBeforeCleanup: settings?.confirmBeforeCleanup ?? SettingsStore.Defaults.confirmBeforeCleanup,
                    keepReceipt: removal.keepReceipt
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
            preferences: { [weak settings] in RemovalPreferences(settings: settings) }
        )
        self.dashboard = DashboardModel(service: dashboardService, persistence: dashboardPersistence)
        self.recovery = RecoveryModel(
            operations: operations, trashService: trashService,
            historyService: historyReader ?? CleanupHistoryReader(service: cleanupHistoryService)
        )
        self.uninstaller = AppUninstallerModel(
            operations: operations,
            scanner: uninstallerScanner ?? AppUninstallerScanService(planner: appUninstallPlanner),
            remover: uninstallerRemover ?? cleanupService,
            homebrewRemover: homebrewUninstallService,
            preferences: { [weak settings] in RemovalPreferences(settings: settings) }
        )
        self.storageExplorer = StorageExplorerModel(
            operations: operations, service: storageExplorerService, removalService: storageExplorerRemover,
            preferences: { [weak settings] in RemovalPreferences(settings: settings) }
        )
        storageExplorer.onEvent = { [weak self] event in self?.handleStorageExplorerEvent(event) }
        storageExplorer.refreshAfterRemoval = { [weak self] in await self?.refreshAfterRemoval() }
        dashboard.iCloudPlanBytes = settings?.iCloudPlan.bytes
        dashboard.canLoad = { [weak self] in self?.isShowingWelcome == false }
        dashboard.canMeasure = { [weak self] automatic in self?.checkDiskAccess(automatic: automatic) ?? false }
        dashboard.hasLimitedAccess = { [weak self] in self?.launchAccess == .limited }
        dashboard.onVolumeChanged = { [weak self] volume in
            guard let self, let settings = self.settings, settings.lowSpaceAlertsEnabled else { return }
            await self.lowDiskNotifications.observe(
                freeBytes: volume.freeBytes, volumeName: volume.name, thresholdGB: settings.warnBelowGB
            )
        }
        recovery.onEvent = { [weak self] event in self?.handleRecoveryEvent(event) }
        recovery.refreshAfterMutation = { [weak self] mutation in
            guard let self else { return }
            switch mutation {
            case .emptyTrash:
                await self.dashboard.measureStorage(trigger: .removal)
            case .putBack:
                if self.checkDiskAccess(automatic: true) { await self.dashboard.measureStorage() }
            }
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
        cleanupScheduler.refreshVolume = { [weak self] in await self?.dashboard.refreshVolumeInfo() }
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
        onboardingProgress?.save(.welcome)
        launchAccess = .welcome
    }

    func finishWelcomeGuide(folder: URL? = nil) {
        onboardingProgress?.finish()
        launchAccess.finishOnboarding(hasFullDiskAccess: hasFullDiskAccess())
        if let folder {
            view = .storageExplorer
            storageExplorer.selectLocation(folder)
        } else if launchAccess == .limited {
            view = .storageExplorer
        }
    }

    /// Keeps automatic scans off when the user continues with limited access.
    func checkDiskAccess(automatic: Bool = false) -> Bool {
        let isAuthorized = launchAccess.authorizeScan(hasFullDiskAccess: hasFullDiskAccess(), automatic: automatic)
        if launchAccess.requiresOnboarding { onboardingProgress?.begin() }
        return isAuthorized
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
        dashboard.recordTrashRemoval(outcome)
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

    /// Starts a broad initial scan only with Full Disk Access.
    func startInitialCleanupScan() {
        guard hasFullDiskAccess(), checkDiskAccess() else { return }
        guard view == .scanner, cleanup.scanResults == nil, !cleanup.hasStartedInitialScan,
              cleanupCompletion == nil, !isBusyWithDisk else { return }
        cleanup.startScan(refreshOverview: false)
    }

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
    var isShowingAppDataAccessAlert = false

    var isBusyWithDisk: Bool { operations.isBusy }

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
            storageExplorer.removeLabel
        case .trash:
            "Empty Trash"
        case .dashboard, .history:
            "Remove"
        }
    }

    /// Opens the Scanner on one of its filtered lists.
    ///
    /// The order matters: the filter is set before the view, so the Scanner draws
    /// the requested list on its first frame instead of showing the whole outline
    /// for a frame and then replacing it.
    func showScanner(filtered filter: CleanupModel.ScanFilter) {
        cleanup.scanFilter = filter
        view = .scanner
    }

    /// The disk changed, so the cached breakdown and the Trash summary are both
    /// wrong. They run together: the Trash read is usually quick and feeds the
    /// sidebar count, and it should not queue behind a 20-second walk.
    private func refreshAfterRemoval(invalidateCleanup: Bool = true, invalidateFileDuplicates: Bool = true) async {
        if invalidateFileDuplicates { fileDuplicates.invalidateResults() }
        if invalidateCleanup { cleanup.invalidateResults() }
        // Every cached Explorer level is stale too: a folder measured before a
        // Scanner clean-up came back from the cache with its old figure.
        storageExplorer.invalidateCache()
        if view == .storageExplorer, !storageExplorer.isMeasurementBlocked {
            storageExplorer.refreshIfNeeded()
        }
        cleanup.pruneVanishedEntries()
        async let trash: Void = recovery.loadTrash()
        async let history: Void = recovery.loadCleanupHistory()
        // `removal` marks this measurement as the post-clean-up baseline, which is
        // what "since the last clean-up" reads and what the ring never thins away.
        await dashboard.measureStorage(trigger: .removal)
        await trash
        await history
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

    /// macOS controls access to the data of other apps separately from Full Disk Access.
    /// Returns true when the outcome needs the app data access alert.
    @discardableResult
    private func showAppDataAccessAlertIfNeeded(_ outcome: CleanupOutcome) -> Bool {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true).path
        let deniedAppData = outcome.permissionDenied.contains {
            $0.hasPrefix(library + "/Containers/") || $0.hasPrefix(library + "/Group Containers/")
        }
        if deniedAppData { isShowingAppDataAccessAlert = true }
        return deniedAppData
    }

    /// Last measured size per category, for the Preferences › Categories rows.
    /// Absent until a scan has run — those rows show an em dash rather than `0 B`,
    /// which would claim a measurement that never happened.
    var categorySizes: [CategoryID: Int64] {
        guard let results = cleanup.scanResults else { return [:] }
        return Dictionary(uniqueKeysWithValues: results.categories.map { ($0.categoryID, $0.totalBytes) })
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

    // MARK: - Storage Explorer presentation

    private func handleStorageExplorerEvent(_ event: StorageExplorerModel.Event) {
        switch event {
        case .reviewing(let count):
            removalCompletion = nil
            activity = .reviewingStorageItems(itemCount: count)
        case .removalStarted(let count, let bytes):
            activity = .removingStorageItems(itemCount: count, totalBytes: bytes)
        case .removed(let outcome):
            completeTrashRemoval(outcome, in: .storageExplorer)
        case .operationFinished:
            activity = nil
        case .failure(let title, let message):
            report(title, message)
        }
    }

    // MARK: - Recovery presentation

    private func handleRecoveryEvent(_ event: RecoveryModel.Event) {
        switch event {
        case .showTrash:
            view = .trash
        case .emptyingTrash(let count, let bytes):
            activeSheet = nil
            removalCompletion = nil
            activity = .emptyingTrash(itemCount: count, totalBytes: bytes)
        case .emptiedTrash(let freedBytes, let skipped):
            if let notice = dashboard.trashNotice { dashboard.dismissTrashNotice(notice.id) }
            removalCompletion = RemovalCompletion(
                destination: .trash,
                title: skipped == 0 ? "Trash emptied" : "Some items remain in Trash",
                detail: skipped == 0
                    ? "\(ByteFormatting.string(freedBytes)) recovered."
                    : "\(skipped) \(skipped == 1 ? "item could" : "items could") not be removed.",
                isSuccess: skipped == 0
            )
        case .restoringTrashItem(let name):
            activity = .restoringTrashItem(name: name)
        case .restored:
            if let notice = dashboard.trashNotice { dashboard.dismissTrashNotice(notice.id) }
            fileDuplicates.invalidateResults()
            storageExplorer.invalidateCache()
            cleanup.invalidateResults()
        case .operationFinished:
            activity = nil
        case .failure(let title, let message):
            report(title, message)
        }
    }

    // MARK: - Cleanup presentation

    private func handleCleanupEvent(_ event: CleanupModel.Event) {
        switch event {
        case .scanStarted(let automatic, let refreshOverview):
            cleanupCompletion = nil
            if !automatic { view = .scanner }
            if refreshOverview {
                Task { await dashboard.measureStorage(trigger: automatic ? .scheduled : .scan) }
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
            if !showAppDataAccessAlertIfNeeded(outcome),
               destination == .scanner, let unfinished = Self.cleanUpNotice(outcome) {
                notice = unfinished
            }
            if destination == .scanner { dashboard.recordTrashRemoval(outcome) }
            else { completeTrashRemoval(outcome, in: destination) }
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
        case .removalStarted(let count, let bytes):
            activity = .cleaningUp(itemCount: count, totalBytes: bytes)
        case .removed(let outcome):
            showAppDataAccessAlertIfNeeded(outcome)
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
            showAppDataAccessAlertIfNeeded(outcome)
        case .operationFinished:
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
