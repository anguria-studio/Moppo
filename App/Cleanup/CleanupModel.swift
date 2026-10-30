import AppKit
import Observation
import MoppoCore

/// Owns Cleanup scans, selection, captured plans, and operation tasks.
@MainActor
@Observable
final class CleanupModel {
    private static let runningAppsNoticeHiddenKey = "cleanup.runningAppsNoticeHidden"

    struct Preferences: Sendable {
        var enabledCategories: Set<CategoryID>?
        var excludedPaths: [String] = []
        var excludedPatterns: [String] = []
        var showsSmallItems = false
        var confirmBeforeCleanup = true
        var keepReceipt = true
    }

    enum Event {
        case scanStarted(automatic: Bool, refreshOverview: Bool)
        case confirmationRequested
        case confirmationDismissed
        case operationStarted
        case waitingForApplications(names: [String])
        case checkingWorktrees
        case removalStarted(count: Int, bytes: Int64)
        case removed(CleanupOutcome)
        case operationFinished
        case failure(title: String, message: String)
    }

    @ObservationIgnored private let operations: OperationCoordinator
    @ObservationIgnored private let scanner: any CleanupScanning
    @ObservationIgnored private let remover: any CleanupRemoving
    @ObservationIgnored private let isAdministratorRetryEligible: (AppleSoundLibrary.Inventory) -> Bool
    @ObservationIgnored private let administratorRemover: any CleanupRemoving
    @ObservationIgnored private var administratorRetryEntries: [FileEntry] = []
    @ObservationIgnored private let saveExclusion: (FileEntry) -> Bool
    @ObservationIgnored private let preferences: () -> Preferences
    @ObservationIgnored private let applications: CleanupApplications
    @ObservationIgnored private let measureSaving: ([URL]) async throws -> PrivateSizeMeasurement?
    @ObservationIgnored private let scanDocker: (Preferences) async throws -> ScanCategoryResult
    @ObservationIgnored private let reviewWorktrees: ([URL]) async throws -> [URL: GitWorktreeReview]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var scanTask: Task<Bool, Never>?
    @ObservationIgnored private var scanID: UUID?
    @ObservationIgnored private var cleanUpSavingTask: Task<Void, Never>?
    @ObservationIgnored private var removalTask: Task<Void, Never>?
    private(set) var canCancelRemoval = false
    private(set) var isInterruptingRemoval = false
    @ObservationIgnored private var applicationQuitTask: Task<[FileEntry.RunningOwner], Never>?
    @ObservationIgnored var canScan: (Bool) -> Bool = { _ in true }
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }
    @ObservationIgnored var refreshAfterRemoval: () async -> Void = {}
    @ObservationIgnored var beforeScan: () async -> Void = {}
    @ObservationIgnored var refreshLeftovers: (Set<String>) async -> Void = { _ in }

    init(
        operations: OperationCoordinator,
        scanner: any CleanupScanning = CleanupScanService(),
        remover: any CleanupRemoving = CleanupService(),
        administratorRemover: any CleanupRemoving = CleanupService(administratorTrash: AdministratorTrashService().trash),
        isAdministratorRetryEligible: @escaping (AppleSoundLibrary.Inventory) -> Bool = AdministratorTrashRequest.canRetry,
        preferences: @escaping () -> Preferences = { Preferences() },
        saveExclusion: @escaping (FileEntry) -> Bool = { _ in false },
        applications: CleanupApplications = CleanupApplications(),
        defaults: UserDefaults = .standard,
        scanDocker: @escaping (Preferences) async throws -> ScanCategoryResult = { preferences in
            try await DockerScanner().scan(context: ScanContext(
                excludedPaths: preferences.excludedPaths, excludedPatterns: preferences.excludedPatterns
            ))
        },
        reviewWorktrees: @escaping ([URL]) async throws -> [URL: GitWorktreeReview] = {
            try await ScanLog.reviewWorktrees($0, source: "removal")
        },
        measureSaving: @escaping ([URL]) async throws -> PrivateSizeMeasurement? = {
            try await PrivateSizeMeasurer().measure($0)
        }
    ) {
        self.operations = operations
        self.scanner = scanner
        self.remover = remover
        self.administratorRemover = administratorRemover
        self.isAdministratorRetryEligible = isAdministratorRetryEligible
        self.preferences = preferences
        self.saveExclusion = saveExclusion
        self.applications = applications
        self.defaults = defaults
        self.measureSaving = measureSaving
        self.scanDocker = scanDocker
        self.reviewWorktrees = reviewWorktrees
        lastScanFinishedAt = defaults.object(forKey: "lastScanFinishedAt") as? Date
        isRunningAppsNoticeDismissed = defaults.bool(forKey: Self.runningAppsNoticeHiddenKey)
    }

    var scanResults: ScanResults? {
        didSet { resetUnavailableDataType() }
    }
    var scanFilter: ScanFilter = .safeToRemove {
        didSet { resetUnavailableDataType() }
    }
    var dataTypeFilter: CleanupDataType = .all {
        didSet {
            if dataTypeFilter != .all { openCategories.formUnion(visibleCategories.map(\.categoryID)) }
        }
    }
    var openCategories: Set<CategoryID> = [.documentsAndFiles]
    var scannerSelection: Set<FileEntry.ID> = []
    var userDataRemovalOverrides: Set<FileEntry.ID> = []
    private(set) var isScanning = false
    private(set) var isInterruptingScan = false
    private(set) var scanProgress = 0
    private(set) var scanPhase: String?

    var scanProgressDetail: String {
        let phase = scanPhase ?? "Checking files"
        return scanProgress > 0 ? "\(scanProgress)% · \(phase)" : phase
    }
    private(set) var lastScanFinishedAt: Date?
    private(set) var hasStartedInitialScan = false
    private(set) var isRemoving = false
    private(set) var isWaitingForApplications = false
    private(set) var isInterruptingApplicationQuit = false
    private(set) var cleanupOutcome: CleanupOutcome?
    private(set) var pendingCleanUp: CleanupPlan?
    var isBusyWithDisk: Bool { operations.isBusy }

    enum ScanFilter: String, CaseIterable, Identifiable {
        case all, safeToRemove
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:          "All"
            case .safeToRemove: "Safe to Remove"
            }
        }
    }

    var allEntries: [FileEntry] {
        let tops = scanResults?.categories.flatMap(\.entries) ?? []
        return tops + tops.flatMap(\.children)
    }

    var selectedEntries: [FileEntry] {
        let selected = scannerSelection
        return allEntries.filter {
            selected.contains($0.id)
                && $0.kind != .appBundle
                && $0.removalAction == nil
                && $0.protectionReason != .inventory
                && $0.unlockableChildren.isEmpty
        }
    }

    func neverOfferAgain(_ entry: FileEntry) {
        guard !isBusyWithDisk, pendingCleanUp == nil,
              let current = allEntries.first(where: { $0.id == entry.id }),
              current.canExcludeFromCleanup, saveExclusion(current) else { return }
        applyExclusions()
    }

    private func applyExclusions() {
        guard var results = scanResults else { return }
        let current = preferences()
        let context = ScanContext(excludedPaths: current.excludedPaths, excludedPatterns: current.excludedPatterns)
        results.categories = results.categories.map { $0.excluding(context) }
        scanResults = results
        let selectable = Set(allEntries.filter {
            !$0.isRemovalLocked || ($0.protectionReason == .userData && userDataRemovalOverrides.contains($0.id))
        }.map(\.id))
        scannerSelection.formIntersection(selectable)
        userDataRemovalOverrides.formIntersection(selectable)
        refreshCleanupRunningOwners()
    }

    func updateWorktreeReview(_ review: GitWorktreeReview, for id: FileEntry.ID) {
        guard var results = scanResults else { return }
        let wasSafe = allEntries.first(where: { $0.id == id })?.gitWorktreeReview?.isSafeToRemove == true
        for categoryIndex in results.categories.indices {
            for entryIndex in results.categories[categoryIndex].entries.indices {
                if results.categories[categoryIndex].entries[entryIndex].id == id {
                    results.categories[categoryIndex].entries[entryIndex].gitWorktreeReview = review
                }
                for childIndex in results.categories[categoryIndex].entries[entryIndex].children.indices {
                    if results.categories[categoryIndex].entries[entryIndex].children[childIndex].id == id {
                        results.categories[categoryIndex].entries[entryIndex].children[childIndex].gitWorktreeReview = review
                    }
                }
            }
        }
        scanResults = results
        if wasSafe && !review.isSafeToRemove { scannerSelection.remove(id) }
    }

    func selectWorktree(_ id: FileEntry.ID) {
        guard !isBusyWithDisk, let entry = allEntries.first(where: { $0.id == id }),
              entry.isGitWorktree, !entry.isRemovalLocked else { return }
        for parent in scanResults?.categories.flatMap(\.entries) ?? [] where parent.children.contains(where: { $0.id == id }) {
            scannerSelection.remove(parent.id)
        }
        select([entry])
    }

    /// Unlock reviewed children without selecting them or their parent.
    func unlockChildren(in reviewedGroup: FileEntry) {
        guard !isBusyWithDisk,
              let currentGroup = scanResults?.categories.flatMap(\.entries).first(where: { $0.id == reviewedGroup.id })
        else { return }
        let reviewed = Dictionary(uniqueKeysWithValues: reviewedGroup.unlockableChildren.map { ($0.id, $0) })
        let ids = Set(currentGroup.unlockableChildren.filter {
            reviewed[$0.id] == $0
        }.map(\.id))
        guard !ids.isEmpty else { return }
        scannerSelection.subtract(currentGroup.children.map(\.id))
        scannerSelection.remove(currentGroup.id)
        userDataRemovalOverrides.remove(currentGroup.id)
        userDataRemovalOverrides.formUnion(ids)
    }

    func setChildrenSelected(_ isSelected: Bool, in groupID: FileEntry.ID) {
        guard !isBusyWithDisk,
              let group = scanResults?.categories.flatMap(\.entries).first(where: { $0.id == groupID })
        else { return }
        if isSelected {
            scannerSelection.formUnion(group.selectableChildren(userDataRemovalOverrides: userDataRemovalOverrides).map(\.id))
        } else {
            scannerSelection.subtract(group.children.map(\.id))
        }
    }

    var hasSelectedDockerImages: Bool {
        let selected = cleanupSelection(in: scanFilter)
        return selectedEntries.contains { selected.contains($0.id) && $0.dockerImage != nil }
    }

    private var selectedOrphanApplicationEntries: [FileEntry] {
        let selected = scannerSelection
        return scanResults?.categories
            .first(where: { $0.categoryID == .applicationLeftovers })?
            .entries.filter { selected.contains($0.id) } ?? []
    }

    /// Cleanup never removes protected app data without a separate authorization.
    nonisolated private static func plannedTargets(for entry: FileEntry) -> [FileEntry] {
        CleanupService.removalTargets(for: entry, removeProtectedAppData: false)
    }

    nonisolated private static func plannedBytes(for entry: FileEntry) -> Int64 {
        plannedTargets(for: entry).reduce(0) { $0 + $1.allocatedBytes }
    }

    func selectedBytes(in category: CategoryID, filter: ScanFilter = .all) -> Int64 {
        let selected = cleanupSelection(in: filter)
        guard let result = scanResults?.categories.first(where: { $0.categoryID == category })
        else { return 0 }
        let entries = filter == .all
            ? result.entries : result.tileRows(safeToRemove: true)
        if category == .applicationLeftovers {
            return entries
                .filter { selected.contains($0.id) }
                .reduce(0) { $0 + $1.displayBytes }
        }
        return entries.reduce(Int64(0)) { total, entry in
            if selected.contains(entry.id) {
                let targets = Self.plannedTargets(for: entry)
                let covered = Set(targets.map(\.id))
                let extraChildren = entry.children
                    .filter { selected.contains($0.id) && !covered.contains($0.id) }
                    .reduce(0) { $0 + Self.plannedBytes(for: $1) }
                return total + targets.reduce(0) { $0 + $1.allocatedBytes } + extraChildren
            }
            return total + entry.children
                .filter { selected.contains($0.id) }
                .reduce(0) { $0 + $1.allocatedBytes }
        }
    }

    func pruneVanishedEntries() {
        guard var results = scanResults else { return }
        let fileManager = FileManager.default
        var vanished: Set<FileEntry.ID> = []

        results.categories = results.categories.map { category in
            var copy = category
            copy.entries = copy.entries.compactMap { original in
                var entry = original
                if entry.removalAction != nil {
                    entry.children.removeAll {
                        let gone = !fileManager.fileExists(atPath: $0.url.path)
                        if gone { vanished.insert($0.id) }
                        return gone
                    }
                    guard !entry.children.isEmpty else {
                        vanished.insert(entry.id)
                        return nil
                    }
                    entry.url = entry.children[0].url
                    entry.childCount = entry.children.count
                    return entry
                }
                if entry.toolCommand != nil, cleanupOutcome?.failed.contains(entry.id) == true { return entry }
                guard entry.url.isFileURL, entry.manualRemoval == nil else { return entry }
                let gone = !fileManager.fileExists(atPath: entry.url.path)
                if gone { vanished.insert(entry.id) }
                return gone ? nil : entry
            }
            copy.entries = copy.entries.map { entry in
                var entry = entry
                entry.children.removeAll { child in
                    let gone = !fileManager.fileExists(atPath: child.url.path)
                    if gone { vanished.insert(child.id) }
                    return gone
                }
                return entry
            }
            copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
            return copy
        }

        if !vanished.isEmpty {
            scanResults = results
            scannerSelection.subtract(vanished)
            userDataRemovalOverrides.subtract(vanished)
        }
    }

    /// Keeps the Docker setup message visible when no type filter is active.
    var safetyFilteredCategories: [ScanCategoryResult] {
        let categories = (scanResults?.categories ?? []).filter { $0.availability != .notInstalled }
        guard scanFilter != .all else { return categories }
        return categories.compactMap { category in
            if category.categoryID == .docker, case .unavailable = category.availability { return category }
            let filtered = category.filtered(safeToRemove: true)
            return filtered.entries.isEmpty ? nil : filtered
        }
    }

    private var safeToRemoveEntries: [FileEntry] {
        guard let results = scanResults else { return [] }
        var seen: Set<FileEntry.ID> = []
        return results.categories
            .flatMap { $0.tileRows(safeToRemove: true) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayBytes > $1.displayBytes }
    }

    private var rowsInCurrentView: [FileEntry] {
        visibleCategories.flatMap(\.entries)
    }

    private var selectableInCurrentView: [FileEntry] {
        let rows = rowsInCurrentView
        let candidates = scanFilter == .all && dataTypeFilter == .all
            ? rows + safeToRemoveEntries : rows
        return selectableEntries(from: candidates)
    }

    private func selectableEntries(from candidates: [FileEntry]) -> [FileEntry] {
        var seen = Set<FileEntry.ID>()
        let children = candidates.flatMap { $0.selectableChildren(userDataRemovalOverrides: userDataRemovalOverrides) }
        let selectable = (candidates + children).filter {
            dataTypeFilter.matches($0)
                && (!$0.isRemovalLocked || ($0.protectionReason == .userData && userDataRemovalOverrides.contains($0.id)))
                && $0.unlockableChildren.isEmpty && $0.kind != .appBundle && seen.insert($0.id).inserted
        }
        let covered = Set(selectable.flatMap(\.children).map(\.id))
        return selectable.filter { !covered.contains($0.id) }
    }

    private func selectableEntries(in category: ScanCategoryResult) -> [FileEntry] {
        let candidates = scanFilter == .all
            ? category.entries + category.tileRows(safeToRemove: true) : category.entries
        return selectableEntries(from: candidates)
    }

    func selectableIDs(in category: ScanCategoryResult) -> Set<FileEntry.ID> {
        Set(selectableEntries(in: category).map(\.id))
    }

    func selectedIDs(in category: ScanCategoryResult) -> Set<FileEntry.ID> {
        CleanupSelection.ids(in: [category], selected: scannerSelection, scope: .all)
            .intersection(viewIDs(in: category.entries))
    }

    func selectAllState(in category: ScanCategoryResult) -> NSControl.StateValue {
        selectAllState(in: selectableEntries(in: category), selected: selectedIDs(in: category))
    }

    private func selectAllState(in selectable: [FileEntry], selected: Set<FileEntry.ID>) -> NSControl.StateValue {
        guard !selected.isEmpty else { return .off }
        return !selectable.isEmpty && selectable.allSatisfy { selected.contains($0.id) } ? .on : .mixed
    }

    func setSelected(_ isSelected: Bool, in category: ScanCategoryResult) {
        guard !isBusyWithDisk else { return }
        if isSelected {
            select(selectableEntries(in: category))
        } else {
            let ids = viewIDs(in: category.entries)
            scannerSelection.subtract(ids)
            userDataRemovalOverrides.subtract(ids)
        }
    }

    func cleanupSelection(in filter: ScanFilter) -> Set<FileEntry.ID> {
        let scope: CleanupSelection.Scope = switch filter {
        case .all: .all
        case .safeToRemove: .safe
        }
        let selected = dataTypeFilter == .all ? scannerSelection : scannerSelection.intersection(idsInCurrentView)
        return CleanupSelection.ids(
            in: scanResults?.categories ?? [], selected: selected, scope: scope
        )
    }

    func cleanupSelectionBytes(in filter: ScanFilter) -> Int64 {
        let ids = cleanupSelection(in: filter)
        return selectedEntries.filter { ids.contains($0.id) }
            .reduce(0) { $0 + Self.plannedBytes(for: $1) }
            + selectedOrphanApplicationEntries.filter { ids.contains($0.id) }
                .reduce(0) { $0 + $1.displayBytes }
    }

    var selectAllStateInCurrentView: NSControl.StateValue {
        selectAllState(in: selectableInCurrentView,
            selected: cleanupSelection(in: scanFilter).intersection(idsInCurrentView))
    }

    var canSelectAllInCurrentView: Bool {
        let selectable = selectableInCurrentView
        return !selectable.isEmpty && !selectable.allSatisfy { scannerSelection.contains($0.id) }
    }

    var hasSelectableItemsInCurrentView: Bool { !selectableInCurrentView.isEmpty }

    var hasSelectionInCurrentView: Bool {
        !scannerSelection.isDisjoint(with: idsInCurrentView)
    }

    func deselectAllInCurrentView() {
        guard !isBusyWithDisk else { return }
        let ids = idsInCurrentView
        scannerSelection.subtract(ids)
        userDataRemovalOverrides.subtract(ids)
    }

    @ObservationIgnored private var safeSelectionSeededAt: Date?

    func seedSafeToRemoveSelection() {
        guard let finishedAt = scanResults?.finishedAt,
              safeSelectionSeededAt != finishedAt
        else { return }
        safeSelectionSeededAt = finishedAt

        select(safeToRemoveEntries.filter {
            !$0.isRemovalLocked && $0.kind != .appBundle && $0.removalAction == nil && $0.unlockableChildren.isEmpty
        })
    }

    func selectAllInCurrentView() {
        guard !isBusyWithDisk else { return }
        select(selectableInCurrentView)
    }

    /// A selected row covers its children, so the children leave the selection.
    private func select(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        setScannerSelection(scannerSelection.union(entries.map(\.id)))
        let childIDs = Set(entries.flatMap(\.children).map(\.id))
        scannerSelection.subtract(childIDs)
        userDataRemovalOverrides.subtract(childIDs)
    }

    func deselectAll() {
        guard !isBusyWithDisk else { return }
        scannerSelection.removeAll()
        userDataRemovalOverrides.removeAll()
    }

    struct CleanupPlan {
        let id = UUID()
        var keepReceipt = true
        var entries: [FileEntry]
        let userDataRemovalOverrides: Set<FileEntry.ID>
        let applicationLeftoverPlan: OrphanedAppLeftoverPlan?
        let orphanedApplicationBundleIdentifiers: Set<String>
        let orphanedApplicationItemPaths: Set<String>
        var runningOwners: [FileEntry.RunningOwner] = []

        var freed: PrivateSizeMeasurement?
        var confirmedToolCommands: [FileEntry.ID: ToolCommandRemoval] = [:]
        var quitsOwners = false

        var toolCommandEntries: [FileEntry] { entries.filter { $0.toolCommand != nil } }
        var nextToolCommand: FileEntry? {
            toolCommandEntries.first { confirmedToolCommands[$0.id] != $0.toolCommand }
        }

        var codexSessionCount: Int {
            entries.compactMap(\.codexSession).reduce(0) { $0 + $1.members.count }
        }

        var codexSessionWarning: String? {
            let reviews = entries.compactMap(\.codexSession)
            guard !reviews.isEmpty else { return nil }
            return CodexSessionReview.warning(for: reviews)
        }

        var worktreeWarning: String? {
            let worktrees = Dictionary(entries.flatMap(CleanupModel.plannedTargets)
                .filter(\.isGitWorktree).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values
            let local = worktrees.filter { $0.gitWorktreeReview?.status == .uncommittedChanges }.count
            let commits = worktrees.filter {
                $0.gitWorktreeReview?.status != .uncommittedChanges && ($0.gitWorktreeReview?.unpushedCommitCount ?? 0) > 0
            }.count
            let other = worktrees.filter {
                $0.gitWorktreeReview?.status != .uncommittedChanges && ($0.gitWorktreeReview?.unpushedCommitCount ?? 0) == 0
                    && $0.gitWorktreeReview?.isSafeToRemove != true
            }.count
            var messages: [String] = []
            if local > 0 { messages.append("\(local) \(local == 1 ? "worktree has" : "worktrees have") uncommitted changes.") }
            if commits > 0 { messages.append("\(commits) \(commits == 1 ? "worktree has" : "worktrees have") unpushed commits.") }
            if other > 0 { messages.append("\(other) \(other == 1 ? "worktree needs" : "worktrees need") further review.") }
            return messages.isEmpty ? nil : messages.joined(separator: " ") + " These worktrees will move to the Trash."
        }

        var orphanedApplicationItems: [AppUninstallPlan.Item] {
            applicationLeftoverPlan?.groups.filter {
                orphanedApplicationBundleIdentifiers.contains($0.bundleIdentifier)
            }.flatMap(\.items).filter {
                orphanedApplicationItemPaths.contains($0.id)
            } ?? []
        }

        var itemCount: Int {
            entries.count + orphanedApplicationItems.count
        }
        var includesSoundLibrary: Bool {
            entries.flatMap { [$0] + $0.children }.contains { $0.soundLibrary != nil }
                || orphanedApplicationItems.contains { $0.soundLibrary != nil }
        }
        var totalBytes: Int64 {
            let ordinary = entries.reduce(0) { $0 + CleanupModel.plannedBytes(for: $1) }
            return ordinary + orphanedApplicationItems.reduce(0) { $0 + $1.allocatedBytes }
        }
        var dockerImageCount: Int { entries.filter { $0.dockerImage != nil }.count }
        var dockerImageBytes: Int64 {
            entries.filter { $0.dockerImage != nil }.reduce(0) { $0 + $1.allocatedBytes }
        }
        var protectedDataCount: Int {
            var protectedIDs: Set<FileEntry.ID> = []
            for entry in entries {
                if entry.protectionReason == .userData,
                   userDataRemovalOverrides.contains(entry.id) {
                    protectedIDs.insert(entry.id)
                }
            }
            let orphanedCount = orphanedApplicationItems.filter(\.isProtectedUserData).count
            return protectedIDs.count + orphanedCount
        }
    }

    func requestCleanUp(in filter: ScanFilter) {
        guard !isBusyWithDisk, pendingCleanUp == nil else { return }
        let scope = cleanupSelection(in: filter)
        let entries = selectedEntries.filter { scope.contains($0.id) }
        let selectedIDs = Set(entries.map(\.id))
        let orphanedEntries = selectedOrphanApplicationEntries.filter { scope.contains($0.id) }
        let orphanedIdentifiers = Set(orphanedEntries.compactMap(\.orphanedApplicationBundleIdentifier))
        let orphanedItemPaths = Set(orphanedEntries.flatMap(\.children).map(\.id))
        let orphanedPlan = scanResults?.categories
            .first(where: { $0.categoryID == .applicationLeftovers })?
            .applicationLeftoverPlan
        guard !entries.isEmpty || !orphanedIdentifiers.isEmpty else { return }
        let preferences = preferences()
        let plan = CleanupPlan(
            keepReceipt: preferences.keepReceipt,
            entries: entries,
            userDataRemovalOverrides: userDataRemovalOverrides.intersection(selectedIDs),
            applicationLeftoverPlan: orphanedPlan,
            orphanedApplicationBundleIdentifiers: orphanedIdentifiers,
            orphanedApplicationItemPaths: orphanedItemPaths,
            runningOwners: applications.stillRunning(
                entries.flatMap(Self.plannedTargets).compactMap(\.inUseBy)
            )
        )
        pendingCleanUp = plan

        if preferences.confirmBeforeCleanup || plan.worktreeWarning != nil || plan.codexSessionCount > 0
            || !plan.toolCommandEntries.isEmpty {
            onEvent(.confirmationRequested)
            measureCleanUpSaving(for: plan)
        } else {
            beginRemoval(quittingOwners: false)
        }
    }

    var confirmBeforeCleanup: Bool { preferences().confirmBeforeCleanup }

    private func measureCleanUpSaving(for plan: CleanupPlan) {
        // Filesystem measurements cannot measure Docker image layers.
        guard plan.dockerImageCount == 0, plan.toolCommandEntries.isEmpty else { return }
        let urls = plan.entries.flatMap(Self.plannedTargets).map(\.url)
            + plan.orphanedApplicationItems.map(\.url)
        guard !urls.isEmpty else { return }

        cleanUpSavingTask?.cancel()
        let measureSaving = measureSaving
        cleanUpSavingTask = Task { [weak self] in
            let measurement = try? await measureSaving(urls)
            guard !Task.isCancelled, let measurement else { return }
            guard let self, self.pendingCleanUp?.id == plan.id else { return }
            self.pendingCleanUp?.freed = measurement
        }
    }

    private(set) var cleanupRunningOwners: [FileEntry.RunningOwner] = []
    private(set) var isRunningAppsNoticeDismissed = false

    func dismissRunningAppsNotice(permanently: Bool = false) {
        if permanently { defaults.set(true, forKey: Self.runningAppsNoticeHiddenKey) }
        isRunningAppsNoticeDismissed = true
    }

    private var runningCacheCandidates: [FileEntry] {
        var candidates: [FileEntry] = []
        var seen: Set<FileEntry.ID> = []
        func visit(_ entry: FileEntry) {
            guard entry.removalAction == nil, !entry.removesAsUnit,
                  entry.manualRemoval == nil, entry.protectionReason != .userData else { return }
            if !entry.children.isEmpty {
                entry.children.forEach(visit)
                return
            }
            guard entry.kind != .appBundle, entry.isRegenerable,
                  !entry.isRemovalLocked, let owner = entry.inUseBy,
                  ApplicationRuntime.canQuitForCleanup(owner),
                  entry.allocatedBytes > 0, seen.insert(entry.id).inserted else { return }
            candidates.append(entry)
        }
        scanResults?.categories.flatMap(\.entries).forEach(visit)
        return candidates
    }

    var runningAppCaches: [FileEntry] {
        let owners = Set(cleanupRunningOwners)
        return runningCacheCandidates.filter { entry in
            entry.inUseBy.map { owners.contains($0) } ?? false
        }
    }

    func refreshCleanupRunningOwners() {
        let known = Array(Set(runningCacheCandidates.compactMap(\.inUseBy)))
        let live = applications.stillRunning(known)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        cleanupRunningOwners = live
    }

    private func clearInUse(of owners: [FileEntry.RunningOwner]) {
        guard var results = scanResults else { return }
        let gone = Set(owners)
        func cleared(_ entry: FileEntry) -> FileEntry {
            var entry = entry
            if let owner = entry.inUseBy, gone.contains(owner) { entry.inUseBy = nil }
            entry.children = entry.children.map(cleared)
            return entry
        }
        results.categories = results.categories.map { category in
            var copy = category
            copy.entries = category.entries.map(cleared)
            return copy
        }
        scanResults = results
    }

    func startScan(automatic: Bool = false, refreshOverview: Bool = true) {
        guard canScan(automatic), pendingCleanUp == nil,
              let operation = operations.begin(.cleanupScan, cancel: { [weak self] in self?.cancelScan() }) else { return }
        let preferences = preferences()
        isRunningAppsNoticeDismissed = defaults.bool(forKey: Self.runningAppsNoticeHiddenKey)
        let scanID = UUID()
        self.scanID = scanID
        hasStartedInitialScan = true
        scannerSelection.subtract(userDataRemovalOverrides)
        userDataRemovalOverrides.removeAll()
        cleanupOutcome = nil
        administratorRetryEntries = []
        isScanning = true
        isInterruptingScan = false
        scanProgress = 0
        scanPhase = nil
        onEvent(.scanStarted(automatic: automatic, refreshOverview: refreshOverview))
        scanTask = Task { [self] in
            let presentation = OperationPresentationDuration()
            var completed = false
            defer {
                if self.scanID == scanID {
                    isScanning = false
                    isInterruptingScan = false
                    scanTask = nil
                    self.scanID = nil
                }
                operations.finish(operation)
            }
            do {
                await beforeScan()
                try Task.checkCancellation()
                let results = try await scanner.scan(preferences: preferences) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.scanID == scanID, !self.isInterruptingScan else { return }
                        self.scanProgress = progress.percent
                        self.scanPhase = progress.phase
                    }
                }
                try Task.checkCancellation()
                guard self.scanID == scanID else { return false }
                scanResults = results
                applyExclusions()
                lastScanFinishedAt = results.finishedAt
                defaults.set(results.finishedAt, forKey: "lastScanFinishedAt")
                openCategories = []
                seedSafeToRemoveSelection()
                refreshCleanupRunningOwners()
                completed = true
            } catch is CancellationError {
                // Keep the previous results when the user stops the scan.
            } catch {
                guard self.scanID == scanID, !Task.isCancelled else { return false }
                onEvent(.failure(
                    title: "The Scan Did Not Finish",
                    message: "Moppo could not finish measuring. Nothing was removed; try scanning again."
                ))
            }
            try? await presentation.wait()
            return completed && !Task.isCancelled
        }
    }

    /// Keep the operation guard until the scan service returns.
    func cancelScan() {
        guard isScanning, !isInterruptingScan else { return }
        isInterruptingScan = true
        scanTask?.cancel()
    }

    /// Wait for scan workers. Return false if the active scan stops or fails.
    func waitForScan() async -> Bool {
        await scanTask?.value ?? true
    }

    func cancelCleanUp() {
        cleanUpSavingTask?.cancel()
        cleanUpSavingTask = nil
        pendingCleanUp = nil
        onEvent(.confirmationDismissed)
    }

    func performCleanUp(quittingOwners: Bool = false, confirmingToolCommand: ToolCommandRemoval? = nil) async {
        guard !Task.isCancelled, var plan = pendingCleanUp else { return }
        plan.quitsOwners = plan.quitsOwners || quittingOwners
        if let entry = plan.nextToolCommand, let command = entry.toolCommand {
            guard confirmingToolCommand == command else { return }
            plan.confirmedToolCommands[entry.id] = command
            pendingCleanUp = plan
            if plan.nextToolCommand != nil { return }
        }
        guard let task = beginRemoval(quittingOwners: plan.quitsOwners) else { return }
        await task.value
    }

    func cancelRemoval() {
        guard canCancelRemoval, !isInterruptingRemoval else { return }
        isInterruptingRemoval = true
        removalTask?.cancel()
        cancelApplicationQuit()
    }

    /// Removal owns its task so a closed view cannot discard completed work.
    @discardableResult
    private func beginRemoval(quittingOwners: Bool) -> Task<Void, Never>? {
        guard let plan = pendingCleanUp, plan.nextToolCommand == nil else { return nil }
        let includesCommands = !plan.toolCommandEntries.isEmpty
        let cancel: (() -> Void)? = includesCommands ? { [weak self] in self?.cancelRemoval() } : nil
        guard let operation = operations.begin(.cleanupRemoval, cancel: cancel) else { return nil }
        administratorRetryEntries = []
        isRemoving = true
        canCancelRemoval = includesCommands
        isInterruptingRemoval = false
        onEvent(.operationStarted)
        cancelCleanUp()
        let task = Task { [self] in
            let attempted = await execute(plan, quittingOwners: quittingOwners)
            onEvent(.operationFinished)
            isRemoving = false
            canCancelRemoval = false
            isInterruptingRemoval = false
            removalTask = nil
            operations.finish(operation)
            if attempted { await refreshAfterRemoval() }
        }
        removalTask = task
        return task
    }

    private func execute(_ capturedPlan: CleanupPlan, quittingOwners: Bool) async -> Bool {
        var plan = capturedPlan
        var presentation = OperationPresentationDuration()
        var skippedWorktrees: Set<String> = []
        let worktrees = plan.entries.flatMap(Self.plannedTargets).filter { $0.gitWorktreeReview?.isSafeToRemove == true }
        var currentReviews: [URL: GitWorktreeReview] = [:]
        if !worktrees.isEmpty {
            onEvent(.checkingWorktrees)
            currentReviews = (try? await reviewWorktrees(worktrees.map(\.url))) ?? [:]
        }
        for entry in worktrees {
            let current = currentReviews[entry.url] ?? GitWorktreeReview()
            if !current.isSafeToRemove {
                updateWorktreeReview(current, for: entry.id)
                skippedWorktrees.insert(entry.id)
            }
        }
        if !skippedWorktrees.isEmpty {
            // Exclude a selected parent when it contains a changed worktree.
            let skippedEntries = plan.entries.filter { entry in
                Self.plannedTargets(for: entry).contains { skippedWorktrees.contains($0.id) }
            }
            let deselected = skippedWorktrees.union(skippedEntries.map(\.id))
            plan.entries.removeAll { deselected.contains($0.id) }
            scannerSelection.subtract(deselected)
            userDataRemovalOverrides.subtract(deselected)
            plan.runningOwners = applications.stillRunning(plan.entries.flatMap(Self.plannedTargets).compactMap(\.inUseBy))
        }
        var outcome = CleanupOutcome(skippedWorktrees: skippedWorktrees.sorted())
        guard plan.itemCount > 0 else {
            cleanupOutcome = outcome
            try? await presentation.wait()
            onEvent(.removed(outcome))
            return false
        }
        if quittingOwners, !plan.runningOwners.isEmpty {
            guard let stragglers = await waitForApplicationsToQuit(plan.runningOwners) else { return false }
            guard stragglers.isEmpty else {
                let names = ListFormatter.localizedString(byJoining: stragglers.map(\.name))
                onEvent(.failure(
                    title: "Nothing Was Removed",
                    message: "\(names) did not quit, so Moppo stopped before touching anything. "
                        + "Quit it yourself and try Clean Up again."
                ))
                return false
            }
        }
        onEvent(.removalStarted(count: plan.itemCount, bytes: plan.totalBytes))
        presentation.extend(toShow: .deletion(bytes: plan.totalBytes))
        let entries = plan.entries
        if !entries.isEmpty {
            let ordinary = (try? await remover.remove(
                entries: entries,
                trashFirst: true,
                keepReceipt: plan.keepReceipt,
                userDataRemovalOverrides: plan.userDataRemovalOverrides,
                appDataRemovalOverrides: [],
                expectedIdentities: [:],
                confirmedToolCommands: plan.confirmedToolCommands
            )) ?? CleanupOutcome(failed: entries.map(\.id))
            outcome.merge(ordinary)
        }
        if let leftovers = plan.applicationLeftoverPlan,
           !plan.orphanedApplicationBundleIdentifiers.isEmpty {
            let registered = applications.registeredIdentifiers(
                leftovers.ownerBundleIdentifiers(for: plan.orphanedApplicationBundleIdentifiers)
            )
            let orphaned = (try? await remover.removeOrphanedAppLeftovers(
                leftovers,
                bundleIdentifiers: plan.orphanedApplicationBundleIdentifiers,
                itemPaths: plan.orphanedApplicationItemPaths,
                registeredApplicationBundleIdentifiers: registered,
                keepReceipt: plan.keepReceipt
            )) ?? CleanupOutcome(failed: plan.orphanedApplicationItems.map { $0.url.path })
            outcome.merge(orphaned)
        }
        administratorRetryEntries = (entries.flatMap(Self.plannedTargets) + plan.orphanedApplicationItems.map(\.fileEntry))
            .filter { entry in
                outcome.permissionDenied.contains(entry.id)
                    && entry.soundLibrary.map(isAdministratorRetryEligible) == true
            }
        cleanupOutcome = outcome
        for result in outcome.toolCommandResults where result.status != .completed {
            guard var results = scanResults else { continue }
            results.categories = results.categories.map { category in
                var copy = category
                copy.entries = copy.entries.map { original in
                    guard original.id == result.targetID else { return original }
                    var entry = original
                    if let bytes = result.afterBytes { entry.allocatedBytes = bytes }
                    entry.safetyCaveat = result.failureReason
                    return entry
                }
                return copy
            }
            scanResults = results
        }
        let completed = Set(entries.map(\.id)).subtracting(outcome.failed)
        scannerSelection.subtract(completed)
        userDataRemovalOverrides.subtract(completed)
        if var results = scanResults {
            results.categories = results.categories.map { category in
                var copy = category
                copy.entries.removeAll { completed.contains($0.id) }
                copy.entries = copy.entries.map { entry in
                    var entry = entry
                    entry.children.removeAll { completed.contains($0.id) }
                    return entry
                }
                copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
                return copy
            }
            scanResults = results
        }
        pruneVanishedEntries()
        if plan.dockerImageCount > 0, var results = scanResults {
            let category: ScanCategoryResult
            do {
                category = try await scanDocker(preferences())
            } catch {
                category = .unavailable(.docker, reason: "Docker storage could not be updated. Try scanning again.")
            }
            results.categories = results.categories.map { $0.categoryID == .docker ? category : $0 }
            scanResults = results
            let imageIDs = Set(category.entries.filter { !$0.isRemovalLocked }.map(\.id))
            scannerSelection.subtract(Set(plan.entries.filter { $0.dockerImage != nil }.map(\.id)).subtracting(imageIDs))
        }
        await refreshLeftovers(plan.orphanedApplicationBundleIdentifiers)
        try? await presentation.wait()
        onEvent(.removed(outcome))
        // The remaining results stay valid. Protected-data approvals apply to one removal only.
        if outcome.removedCount > 0 { userDataRemovalOverrides.removeAll() }
        return true
    }

    var administratorRetryCount: Int { Set(administratorRetryEntries.map(\.id)).count }
    var canRetryWithAdministrator: Bool { administratorRetryCount > 0 && preferences().keepReceipt }

    /// Retries only captured failures. A changed selection cannot add another item.
    func retryWithAdministrator() async {
        guard canRetryWithAdministrator, pendingCleanUp == nil,
              let operation = operations.begin(.cleanupRemoval) else { return }
        let captured = administratorRetryEntries
        administratorRetryEntries = []
        let previous = cleanupOutcome ?? CleanupOutcome()
        let current = preferences()
        let context = ScanContext(excludedPaths: current.excludedPaths, excludedPatterns: current.excludedPatterns)
        let entries = captured.filter { $0.soundLibrary?.isExcluded(in: context) == false }
        isRemoving = true
        onEvent(.operationStarted)
        onEvent(.removalStarted(count: entries.count, bytes: entries.reduce(0) { $0 + $1.allocatedBytes }))
        let task = Task { [self] in
            let result = entries.isEmpty ? CleanupOutcome() : (try? await administratorRemover.remove(
                entries: entries, trashFirst: true, keepReceipt: true, userDataRemovalOverrides: [],
                appDataRemovalOverrides: [], expectedIdentities: [:], confirmedToolCommands: [:]
            )) ?? CleanupOutcome(failed: entries.map(\.id))
            let succeeded = Set(entries.map(\.id)).subtracting(result.failed)
            var combined = previous
            combined.failed.removeAll { succeeded.contains($0) }
            combined.permissionDenied.removeAll { succeeded.contains($0) }
            var delta = result
            delta.failed = Array(Set(combined.failed).union(result.failed)).sorted()
            combined.failed = []
            combined.merge(delta)
            cleanupOutcome = combined
            scannerSelection.subtract(succeeded)
            pruneVanishedEntries()
            // Events report only this attempt's bytes so Dashboard does not count the first move twice.
            if !result.administratorApprovalCancelled || result.removedCount > 0 { onEvent(.removed(delta)) }
            onEvent(.operationFinished)
            isRemoving = false
            operations.finish(operation)
            if result.removedCount > 0 { await refreshAfterRemoval() }
        }
        await task.value
    }

    func quitAppsForCleanup() async {
        guard !Task.isCancelled, pendingCleanUp == nil, !isBusyWithDisk else { return }
        refreshCleanupRunningOwners()
        let owners = cleanupRunningOwners
        guard !owners.isEmpty, let operation = operations.begin(.cleanupQuit) else { return }
        onEvent(.operationStarted)
        let task = Task { [self] in
            if let stillOpen = await waitForApplicationsToQuit(owners), !stillOpen.isEmpty {
                let names = ListFormatter.localizedString(byJoining: stillOpen.map(\.name))
                onEvent(.failure(
                    title: "Some Apps Are Still Open",
                    message: "\(names) did not quit. Close these apps, then try Quit Apps again."
                ))
            }
            onEvent(.operationFinished)
            operations.finish(operation)
        }
        await task.value
    }

    /// Keep the operation guard until the quit service returns.
    func cancelApplicationQuit() {
        guard isWaitingForApplications, !isInterruptingApplicationQuit else { return }
        isInterruptingApplicationQuit = true
        applicationQuitTask?.cancel()
    }

    private func waitForApplicationsToQuit(
        _ owners: [FileEntry.RunningOwner]
    ) async -> [FileEntry.RunningOwner]? {
        let task = Task { await applications.quit(owners) }
        applicationQuitTask = task
        isWaitingForApplications = true
        isInterruptingApplicationQuit = false
        onEvent(.waitingForApplications(names: owners.map(\.name)))
        let result = await task.value
        let cancelled = task.isCancelled
        let stillOpen = cancelled ? applications.stillRunning(owners) : result
        clearInUse(of: owners.filter { !stillOpen.contains($0) })
        refreshCleanupRunningOwners()
        applicationQuitTask = nil
        isWaitingForApplications = false
        isInterruptingApplicationQuit = false
        return cancelled ? nil : result
    }

    /// Disk changes invalidate the review and its protected-data authorizations.
    func invalidateResults() {
        cancelScan()
        cancelCleanUp()
        scanResults = nil
        administratorRetryEntries = []
        scannerSelection.removeAll()
        userDataRemovalOverrides.removeAll()
        cleanupRunningOwners = []
        scanFilter = .safeToRemove
        hasStartedInitialScan = false
        safeSelectionSeededAt = nil
    }
}
