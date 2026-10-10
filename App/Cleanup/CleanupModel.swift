import AppKit
import Observation
import MoppoCore

/// Owns Cleanup scans, selection, captured plans, and operation tasks.
@MainActor
@Observable
final class CleanupModel {
    struct Preferences: Sendable {
        var enabledCategories: Set<CategoryID>?
        var excludedPaths: [String] = []
        var excludedPatterns: [String] = []
        var confirmBeforeCleanup = true
        var keepReceipt = true
    }

    enum Event {
        case scanStarted(automatic: Bool, refreshOverview: Bool)
        case confirmationRequested
        case confirmationDismissed
        case operationStarted
        case waitingForApplications(names: [String])
        case removalStarted(count: Int, bytes: Int64)
        case removed(CleanupOutcome)
        case operationFinished
        case failure(title: String, message: String)
    }

    @ObservationIgnored private let operations: OperationCoordinator
    @ObservationIgnored private let scanner: any CleanupScanning
    @ObservationIgnored private let remover: any CleanupRemoving
    @ObservationIgnored private let preferences: () -> Preferences
    @ObservationIgnored private let applications: CleanupApplications
    @ObservationIgnored private let measureSaving: ([URL]) async throws -> PrivateSizeMeasurement?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanID: UUID?
    @ObservationIgnored private var cleanUpSavingTask: Task<Void, Never>?
    @ObservationIgnored var canScan: (Bool) -> Bool = { _ in true }
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }
    @ObservationIgnored var refreshAfterRemoval: () async -> Void = {}
    @ObservationIgnored var refreshLeftovers: (Set<String>) async -> Void = { _ in }

    init(
        operations: OperationCoordinator,
        scanner: any CleanupScanning = CleanupScanService(),
        remover: any CleanupRemoving = CleanupService(),
        preferences: @escaping () -> Preferences = { Preferences() },
        applications: CleanupApplications = CleanupApplications(),
        defaults: UserDefaults = .standard,
        measureSaving: @escaping ([URL]) async throws -> PrivateSizeMeasurement? = {
            try await PrivateSizeMeasurer().measure($0)
        }
    ) {
        self.operations = operations
        self.scanner = scanner
        self.remover = remover
        self.preferences = preferences
        self.applications = applications
        self.defaults = defaults
        self.measureSaving = measureSaving
        lastScanFinishedAt = defaults.object(forKey: "lastScanFinishedAt") as? Date
    }

    var scanResults: ScanResults?
    var scanFilter: ScanFilter = .safeToRemove
    var openCategories: Set<CategoryID> = [.documentsAndFiles]
    var scannerSelection: Set<FileEntry.ID> = []
    var userDataRemovalOverrides: Set<FileEntry.ID> = []
    private(set) var isScanning = false
    private(set) var isInterruptingScan = false
    private(set) var scanProgress = 0
    private(set) var lastScanFinishedAt: Date?
    private(set) var hasStartedInitialScan = false
    private(set) var isRemoving = false
    private(set) var cleanupOutcome: CleanupOutcome?
    private(set) var pendingCleanUp: CleanupPlan?
    var isBusyWithDisk: Bool { operations.isBusy }

    enum ScanFilter: String, CaseIterable, Identifiable {
        case all, safeToRemove, needsReview
        var id: String { rawValue }

        var title: String {
            switch self {
            case .all:          "All"
            case .safeToRemove: "Safe to Remove"
            case .needsReview:  "Needs Review"
            }
        }

        var explanation: String? {
            switch self {
            case .all:
                nil
            case .safeToRemove:
                "Caches and package files. They regenerate on demand, so removing them costs nothing."
            case .needsReview:
                "Large files, unused apps and what removed apps left behind. Look before you remove."
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
        }
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
            ? result.entries : result.tileRows(safeToRemove: filter == .safeToRemove)
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

    func tileEntries(safeToRemove wantSafe: Bool) -> [FileEntry] {
        guard let results = scanResults else { return [] }
        var seen: Set<FileEntry.ID> = []
        return results.categories
            .flatMap { $0.tileRows(safeToRemove: wantSafe) }
            .filter { seen.insert($0.id).inserted }
            .sorted { $0.displayBytes > $1.displayBytes }
    }

    private var rowsInCurrentView: [FileEntry] {
        switch scanFilter {
        case .all: scanResults?.categories.flatMap(\.entries) ?? []
        case .safeToRemove: tileEntries(safeToRemove: true)
        case .needsReview: tileEntries(safeToRemove: false)
        }
    }

    private var selectableInCurrentView: [FileEntry] {
        let rows = rowsInCurrentView
        let candidates = scanFilter == .all
            ? rows + tileEntries(safeToRemove: true) : rows
        var seen = Set<FileEntry.ID>()
        let selectable = candidates.filter {
            !$0.isRemovalLocked && $0.kind != .appBundle && seen.insert($0.id).inserted
        }
        let covered = Set(selectable.flatMap(\.children).map(\.id))
        return selectable.filter { !covered.contains($0.id) }
    }

    func cleanupSelection(in filter: ScanFilter) -> Set<FileEntry.ID> {
        let scope: CleanupSelection.Scope = switch filter {
        case .all: .all
        case .safeToRemove: .safe
        case .needsReview: .review
        }
        return CleanupSelection.ids(
            in: scanResults?.categories ?? [], selected: scannerSelection, scope: scope
        )
    }

    func cleanupSelectionBytes(in filter: ScanFilter) -> Int64 {
        let ids = cleanupSelection(in: filter)
        return selectedEntries.filter { ids.contains($0.id) }
            .reduce(0) { $0 + Self.plannedBytes(for: $1) }
            + selectedOrphanApplicationEntries.filter { ids.contains($0.id) }
                .reduce(0) { $0 + $1.displayBytes }
    }

    var canSelectAllInCurrentView: Bool {
        let selectable = selectableInCurrentView
        return !selectable.isEmpty
            && !selectable.allSatisfy { scannerSelection.contains($0.id) }
    }

    var hasSelectableItemsInCurrentView: Bool { !selectableInCurrentView.isEmpty }

    var hasSelectionInCurrentView: Bool {
        let rows = rowsInCurrentView
        return (rows + rows.flatMap(\.children)).contains { scannerSelection.contains($0.id) }
    }

    func deselectAllInCurrentView() {
        guard !isBusyWithDisk else { return }
        let rows = rowsInCurrentView
        let ids = Set((rows + rows.flatMap(\.children)).map(\.id))
        scannerSelection.subtract(ids)
        userDataRemovalOverrides.subtract(ids)
    }

    @ObservationIgnored private var safeSelectionSeededAt: Date?

    func seedSafeToRemoveSelection() {
        guard let finishedAt = scanResults?.finishedAt,
              safeSelectionSeededAt != finishedAt
        else { return }
        safeSelectionSeededAt = finishedAt

        select(tileEntries(safeToRemove: true).filter {
            !$0.isRemovalLocked && $0.kind != .appBundle && $0.removalAction == nil
        })
    }

    func selectAllInCurrentView() {
        guard !isBusyWithDisk else { return }
        select(selectableInCurrentView)
    }

    /// A selected row covers its children, so the children leave the selection.
    private func select(_ entries: [FileEntry]) {
        guard !entries.isEmpty else { return }
        scannerSelection.formUnion(entries.map(\.id))
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
        let entries: [FileEntry]
        let userDataRemovalOverrides: Set<FileEntry.ID>
        let applicationLeftoverPlan: OrphanedAppLeftoverPlan?
        let orphanedApplicationBundleIdentifiers: Set<String>
        let orphanedApplicationItemPaths: Set<String>
        var runningOwners: [FileEntry.RunningOwner] = []

        var freed: PrivateSizeMeasurement?

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
        var totalBytes: Int64 {
            let ordinary = entries.reduce(0) { $0 + CleanupModel.plannedBytes(for: $1) }
            return ordinary + orphanedApplicationItems.reduce(0) { $0 + $1.allocatedBytes }
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

        if preferences.confirmBeforeCleanup || !plan.runningOwners.isEmpty {
            onEvent(.confirmationRequested)
            measureCleanUpSaving(for: plan)
        } else {
            beginRemoval(quittingOwners: false)
        }
    }

    private func measureCleanUpSaving(for plan: CleanupPlan) {
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
                  !entry.isRemovalLocked, entry.inUseBy != nil,
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
              let operation = operations.begin(.cleanupScan) else { return }
        let preferences = preferences()
        let scanID = UUID()
        self.scanID = scanID
        hasStartedInitialScan = true
        scannerSelection.subtract(userDataRemovalOverrides)
        userDataRemovalOverrides.removeAll()
        cleanupOutcome = nil
        isScanning = true
        isInterruptingScan = false
        scanProgress = 0
        onEvent(.scanStarted(automatic: automatic, refreshOverview: refreshOverview))
        scanTask = Task { [self] in
            let presentation = OperationPresentationDuration()
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
                let results = try await scanner.scan(preferences: preferences) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.scanID == scanID, !self.isInterruptingScan else { return }
                        self.scanProgress = progress.percent
                    }
                }
                try Task.checkCancellation()
                guard self.scanID == scanID else { return }
                scanResults = results
                lastScanFinishedAt = results.finishedAt
                defaults.set(results.finishedAt, forKey: "lastScanFinishedAt")
                openCategories = []
                seedSafeToRemoveSelection()
                refreshCleanupRunningOwners()
            } catch is CancellationError {
                // Keep the previous results when the user stops the scan.
            } catch {
                guard self.scanID == scanID, !Task.isCancelled else { return }
                onEvent(.failure(
                    title: "The Scan Did Not Finish",
                    message: "Moppo could not finish measuring. Nothing was removed; try scanning again."
                ))
            }
            try? await presentation.wait()
        }
    }

    /// Keep the operation guard until the scan service returns.
    func cancelScan() {
        guard isScanning, !isInterruptingScan else { return }
        isInterruptingScan = true
        scanTask?.cancel()
    }

    func cancelCleanUp() {
        cleanUpSavingTask?.cancel()
        cleanUpSavingTask = nil
        pendingCleanUp = nil
        onEvent(.confirmationDismissed)
    }

    func performCleanUp(quittingOwners: Bool = false) async {
        guard !Task.isCancelled, let task = beginRemoval(quittingOwners: quittingOwners) else { return }
        await task.value
    }

    /// Removal owns its task so a closed view cannot discard completed work.
    @discardableResult
    private func beginRemoval(quittingOwners: Bool) -> Task<Void, Never>? {
        guard let plan = pendingCleanUp,
              let operation = operations.begin(.cleanupRemoval) else { return nil }
        isRemoving = true
        onEvent(.operationStarted)
        cancelCleanUp()
        return Task { [self] in
            let attempted = await execute(plan, quittingOwners: quittingOwners)
            onEvent(.operationFinished)
            isRemoving = false
            operations.finish(operation)
            if attempted { await refreshAfterRemoval() }
        }
    }

    private func execute(_ plan: CleanupPlan, quittingOwners: Bool) async -> Bool {
        var presentation = OperationPresentationDuration()
        if quittingOwners, !plan.runningOwners.isEmpty {
            onEvent(.waitingForApplications(names: plan.runningOwners.map(\.name)))
            let stragglers = await applications.quit(plan.runningOwners)
            guard stragglers.isEmpty else {
                let names = ListFormatter.localizedString(byJoining: stragglers.map(\.name))
                onEvent(.failure(
                    title: "Nothing Was Removed",
                    message: "\(names) did not quit, so Moppo stopped before touching anything. "
                        + "Quit it yourself and try Clean Up again."
                ))
                return false
            }
            clearInUse(of: plan.runningOwners)
        }
        onEvent(.removalStarted(count: plan.itemCount, bytes: plan.totalBytes))
        presentation.extend(toShow: .deletion(bytes: plan.totalBytes))
        let entries = plan.entries
        var outcome = CleanupOutcome()
        if !entries.isEmpty {
            let ordinary = (try? await remover.remove(
                entries: entries,
                trashFirst: true,
                privilegedFallback: true,
                keepReceipt: plan.keepReceipt,
                userDataRemovalOverrides: plan.userDataRemovalOverrides,
                appDataRemovalOverrides: [],
                expectedIdentities: [:]
            )) ?? CleanupOutcome(failed: entries.map(\.id))
            outcome.merge(ordinary)
        }
        if let leftovers = plan.applicationLeftoverPlan,
           !plan.orphanedApplicationBundleIdentifiers.isEmpty {
            let registered = applications.registeredIdentifiers(plan.orphanedApplicationBundleIdentifiers)
            let orphaned = (try? await remover.removeOrphanedAppLeftovers(
                leftovers,
                bundleIdentifiers: plan.orphanedApplicationBundleIdentifiers,
                itemPaths: plan.orphanedApplicationItemPaths,
                registeredApplicationBundleIdentifiers: registered,
                privilegedFallback: true,
                keepReceipt: plan.keepReceipt
            )) ?? CleanupOutcome(failed: plan.orphanedApplicationItems.map { $0.url.path })
            outcome.merge(orphaned)
        }
        cleanupOutcome = outcome
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
        await refreshLeftovers(plan.orphanedApplicationBundleIdentifiers)
        try? await presentation.wait()
        onEvent(.removed(outcome))
        if outcome.removedCount > 0 { invalidateResults() }
        return true
    }

    func quitAppsForCleanup() async {
        guard !Task.isCancelled, pendingCleanUp == nil, !isBusyWithDisk else { return }
        refreshCleanupRunningOwners()
        let owners = cleanupRunningOwners
        guard !owners.isEmpty, let operation = operations.begin(.cleanupQuit) else { return }
        onEvent(.operationStarted)
        onEvent(.waitingForApplications(names: owners.map(\.name)))
        let task = Task { [self] in
            let stillOpen = await applications.quit(owners)
            clearInUse(of: owners.filter { !stillOpen.contains($0) })
            refreshCleanupRunningOwners()
            if !stillOpen.isEmpty {
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

    /// Disk changes invalidate the review and its protected-data authorizations.
    func invalidateResults() {
        cancelScan()
        cancelCleanUp()
        scanResults = nil
        scannerSelection.removeAll()
        userDataRemovalOverrides.removeAll()
        cleanupRunningOwners = []
        scanFilter = .safeToRemove
        hasStartedInitialScan = false
        safeSelectionSeededAt = nil
    }
}
