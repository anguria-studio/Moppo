import Foundation
import Observation
import MoppoCore

/// Owns application lists, uninstall reviews, selection, and operation tasks.
@MainActor
@Observable
final class AppUninstallerModel {
    typealias Preferences = RemovalPreferences

    enum Event {
        case planningStarted
        case operationStarted
        case uninstalling(name: String, applicationOnly: Bool, waiting: Bool, homebrew: Bool)
        case removalStarted(count: Int, bytes: Int64)
        case removed(CleanupOutcome)
        case operationFinished
        case failure(title: String, message: String)
    }

    @ObservationIgnored private let operations: OperationCoordinator
    @ObservationIgnored private let scanner: any AppUninstallerScanning
    @ObservationIgnored private let remover: any AppUninstallRemoving
    @ObservationIgnored private let homebrewRemover: any HomebrewUninstallRemoving
    @ObservationIgnored private let preferences: () -> Preferences
    @ObservationIgnored private let applications: AppUninstallApplications
    @ObservationIgnored private let hasFullDiskAccess: () -> Bool
    @ObservationIgnored private var detailCache: AppUninstallDetailCache
    @ObservationIgnored private var installedID: UUID?
    @ObservationIgnored private var leftoversID: UUID?
    @ObservationIgnored var canPlan: () -> Bool = { true }
    @ObservationIgnored var onEvent: (Event) -> Void = { _ in }
    @ObservationIgnored var refreshAfterRemoval: () async -> Void = {}
    @ObservationIgnored var beforeSizeMeasurement: () async -> Bool = { true }
    private(set) var isUninstallingApp = false
    var isBusyWithDisk: Bool { operations.isBusy }

    init(
        operations: OperationCoordinator,
        scanner: any AppUninstallerScanning = AppUninstallerScanService(),
        remover: any AppUninstallRemoving = CleanupService(),
        homebrewRemover: any HomebrewUninstallRemoving = HomebrewAuthentication.service(),
        preferences: @escaping () -> Preferences = { Preferences() },
        applications: AppUninstallApplications = AppUninstallApplications(),
        hasFullDiskAccess: @escaping () -> Bool = { FullDiskAccess.isGranted },
        detailCache: AppUninstallDetailCache = AppUninstallDetailCache()
    ) {
        self.operations = operations
        self.scanner = scanner
        self.remover = remover
        self.homebrewRemover = homebrewRemover
        self.preferences = preferences
        self.applications = applications
        self.hasFullDiskAccess = hasFullDiskAccess
        self.detailCache = detailCache
    }

    private func makeContext() -> ScanContext {
        let settings = preferences()
        return ScanContext(
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: settings.excludedPaths,
            excludedPatterns: settings.excludedPatterns
        )
    }

    private func report(_ title: String, _ message: String) {
        onEvent(.failure(title: title, message: message))
    }

    private func detailCacheSettings() -> AppUninstallDetailCache.Settings {
        let settings = preferences()
        return .init(
            excludedPaths: settings.excludedPaths, excludedPatterns: settings.excludedPatterns,
            hasFullDiskAccess: hasFullDiskAccess()
        )
    }

    /// Prevent an earlier calculation from restoring results after invalidation.
    func invalidateDetailCache() {
        detailCache.invalidate()
    }

    /// Keep the task and guard until the removal service returns.
    @discardableResult
    private func startRemoval(
        _ operation: OperationCoordinator.Operation,
        execute: @escaping @MainActor () async -> Bool
    ) -> Task<Void, Never> {
        invalidateDetailCache()
        isUninstallingApp = true
        onEvent(.operationStarted)
        return Task { [self] in
            let attempted = await execute()
            isUninstallingApp = false
            onEvent(.operationFinished)
            operations.finish(operation)
            if attempted { await refreshAfterRemoval() }
        }
    }

    /// Keep the guard until the planner returns. A reset requested during planning applies after that.
    private func startPlanning(
        _ operation: OperationCoordinator.Operation,
        then: (() -> Void)? = nil,
        plan: @escaping @MainActor (_ planningID: UUID) async -> Void
    ) {
        let planningID = UUID()
        appUninstallPlanningID = planningID
        isPlanningAppUninstall = true
        isInterruptingAppUninstall = false
        appUninstallTask = Task { [self] in
            defer {
                if appUninstallPlanningID == planningID {
                    let interrupted = isInterruptingAppUninstall || Task.isCancelled
                    isPlanningAppUninstall = false
                    appUninstallPlanningURL = nil
                    appUninstallPlanningDetail = nil
                    appUninstallTask = nil
                    appUninstallPlanningID = nil
                    if isInterruptingAppUninstall { resetAppUninstall() }
                    operations.finish(operation)
                    if !interrupted { then?() }
                }
            }
            await plan(planningID)
        }
    }

    // MARK: - Uninstall review

    var uninstallerRemoveLabel: String {
        switch uninstallerTab {
        case .installed:
            let count = selectedApplicationIDs.count
            let label = preferences().confirmBeforeCleanup ? "Review Uninstall" : "Uninstall"
            guard count > 0 else { return label }
            return "\(label) (\(count) \(count == 1 ? "app" : "apps"))"
        case .leftovers:
            return "Move Leftovers to Trash"
        }
    }

    @ObservationIgnored private var appUninstallTask: Task<Void, Never>?
    @ObservationIgnored private var appUninstallPlanningID: UUID?

    var appUninstallPlan: AppUninstallPlan?
    var selectedSoundLibraryIDs: Set<String> = []
    struct SoundLibraryRemovalReview: Identifiable {
        let id = UUID()
        let plan: AppUninstallPlan
        let items: [AppUninstallPlan.Item]
        let keepReceipt: Bool
    }
    var pendingSoundLibraryRemoval: SoundLibraryRemovalReview?
    struct LeftoverRemovalReview: Identifiable {
        let id = UUID()
        let plan: OrphanedAppLeftoverPlan
        let identifiers: Set<String>
        let items: [AppUninstallPlan.Item]
        let keepReceipt: Bool
    }
    var pendingLeftoverRemoval: LeftoverRemovalReview?
    @ObservationIgnored var confirmRemoval: (RemovalConfirmation) async -> Bool = { _ in false }
    private(set) var isPlanningAppUninstall = false
    private(set) var isInterruptingAppUninstall = false
    /// The selected application remains visible while its review is prepared.
    private(set) var appUninstallPlanningURL: URL?
    /// Keeps the selected application available after planning fails.
    private(set) var appUninstallReviewURL: URL?

    var isShowingAppUninstallDetail: Bool {
        guard !isInterruptingAppUninstall,
              appUninstallOutcome == nil, batchUninstallOutcome == nil else { return false }
        return appUninstallPlan != nil
            || (appUninstallReviewURL != nil && (isPlanningAppUninstall || appUninstallError != nil))
    }
    private(set) var appUninstallError: String?
    private(set) var appUninstallOutcome: CleanupOutcome?
    private(set) var lastUninstalledApplicationName: String?

    /// Open a review for an application selected from any page.
    func planAppUninstall(_ applicationURL: URL) {
        guard !isBusyWithDisk else {
            report(
                "Wait for the Current Operation",
                "Finish or stop the current operation before you review another application."
            )
            return
        }
        guard canPlan(), let operation = operations.begin(.appUninstallPlanning) else { return }
        resetAppUninstall()
        appUninstallReviewURL = applicationURL.standardizedFileURL
        let settings = detailCacheSettings()
        if let plan = detailCache.plan(for: applicationURL, settings: settings) {
            appUninstallPlan = plan
            operations.finish(operation)
            onEvent(.planningStarted)
            return
        }
        appUninstallPlanningURL = applicationURL.standardizedFileURL
        let generation = detailCache.generation
        let stamp = AppUninstallDetailCache.BundleStamp(applicationURL)
        let context = makeContext()
        startPlanning(operation) { [self] planningID in
            let presentation = OperationPresentationDuration()
            do {
                let plan = try await scanner.plan(applicationURL: applicationURL, context: context)
                try Task.checkCancellation()
                guard appUninstallPlanningID == planningID else { return }
                appUninstallPlan = plan
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, appUninstallPlanningID == planningID else { return }
                // Shown on the review page itself, where the user is waiting.
                appUninstallError = error.localizedDescription
            }
            try? await presentation.wait()
            guard !Task.isCancelled, appUninstallPlanningID == planningID,
                  let plan = appUninstallPlan, let stamp,
                  settings == detailCacheSettings() else { return }
            detailCache.store(plan, stamp: stamp, settings: settings, generation: generation)
        }
        onEvent(.planningStarted)
    }

    func resetAppUninstall() {
        guard !isUninstallingApp else { return }
        appUninstallReviewURL = nil
        if isPlanningAppUninstall {
            guard !isInterruptingAppUninstall else { return }
            isInterruptingAppUninstall = true
            appUninstallTask?.cancel()
            return
        }
        appUninstallTask?.cancel()
        appUninstallTask = nil
        appUninstallPlanningID = nil
        appUninstallPlan = nil
        selectedSoundLibraryIDs.removeAll()
        pendingSoundLibraryRemoval = nil
        pendingLeftoverRemoval = nil
        appUninstallError = nil
        appUninstallOutcome = nil
        lastUninstalledApplicationName = nil
        isPlanningAppUninstall = false
        isInterruptingAppUninstall = false
        appUninstallPlanningURL = nil
        appUninstallPlanningDetail = nil
        batchUninstallReview = nil
        batchUninstallOutcome = nil
    }

    // MARK: Installed applications

    /// Removes only the sound content captured in the separate review.
    func requestSoundLibraryRemoval(_ plan: AppUninstallPlan, itemPaths: Set<String>) async {
        guard !Task.isCancelled, !isBusyWithDisk, pendingSoundLibraryRemoval == nil,
              appUninstallPlan == plan else { return }
        let items = plan.soundLibraryItems.filter { itemPaths.contains($0.id) }
        guard !items.isEmpty else { return }
        guard !applications.isRunning(plan.applicationURL) else {
            report("Quit the Application", "Quit \(plan.applicationName) before you remove its sound library.")
            return
        }
        let settings = preferences()
        let review = SoundLibraryRemovalReview(plan: plan, items: items, keepReceipt: settings.keepReceipt)
        if settings.confirmBeforeCleanup {
            pendingSoundLibraryRemoval = review
            return
        }
        await performSoundLibraryRemoval(review)
    }

    func confirmSoundLibraryRemoval() async {
        guard let review = pendingSoundLibraryRemoval else { return }
        pendingSoundLibraryRemoval = nil
        await performSoundLibraryRemoval(review)
    }

    private func performSoundLibraryRemoval(_ review: SoundLibraryRemovalReview) async {
        let plan = review.plan
        guard appUninstallPlan == plan, !applications.isRunning(plan.applicationURL),
              let operation = operations.begin(.appLeftoverRemoval) else { return }
        let items = review.items
        let paths = Set(items.map(\.id))
        let bytes = items.reduce(0) { $0 + $1.allocatedBytes }
        let keepReceipt = review.keepReceipt
        onEvent(.removalStarted(count: items.count, bytes: bytes))
        let task = startRemoval(operation) { [self] in
            var presentation = OperationPresentationDuration()
            presentation.extend(toShow: .deletion(bytes: bytes))
            let outcome = (try? await remover.removeSoundLibraries(
                plan, itemPaths: paths, keepReceipt: keepReceipt
            )) ?? CleanupOutcome(failed: Array(paths).sorted())
            appUninstallPlan = nil
            selectedSoundLibraryIDs.removeAll()
            try? await presentation.wait()
            onEvent(.removed(outcome))
            return true
        }
        await task.value
    }

    /// A nil list indicates that the first application load has not finished.
    private(set) var installedApplications: [InstalledApplication]?

    /// Keep measured sizes across visits. Each removal review measures the bundle again.
    private(set) var installedApplicationBytes: [String: Int64] = [:]

    /// Allow size sorting after all application measurements finish.
    private(set) var installedApplicationsMeasured = false

    @ObservationIgnored private var installedApplicationsTask: Task<Void, Never>?

    // MARK: Application leftovers, in the Uninstaller

    /// Leftover results load independently of Cleanup scans.
    private(set) var applicationLeftovers: OrphanedAppLeftoverPlan?
    private(set) var isLoadingApplicationLeftovers = false
    /// Removed applications ticked in that tab, by bundle identifier.
    var selectedLeftoverIdentifiers: Set<String> = []
    @ObservationIgnored private var applicationLeftoversTask: Task<Void, Never>?

    var selectedLeftoverBytes: Int64 {
        applicationLeftovers?.groups
            .filter { selectedLeftoverIdentifiers.contains($0.bundleIdentifier) }
            .reduce(0) { $0 + $1.totalBytes } ?? 0
    }

    func loadApplicationLeftovers() {
        applicationLeftoversTask?.cancel()
        let context = makeContext()
        let id = UUID()
        leftoversID = id
        isLoadingApplicationLeftovers = true
        applicationLeftoversTask = Task { [self] in
            defer {
                if leftoversID == id {
                    isLoadingApplicationLeftovers = false
                    applicationLeftoversTask = nil
                    leftoversID = nil
                }
            }
            let presentation = OperationPresentationDuration()
            let plan = try? await scanner.leftovers(context: context)
            try? await presentation.wait()
            guard !Task.isCancelled, leftoversID == id else { return }
            applicationLeftovers = plan
            let listed = Set(plan?.groups.map(\.bundleIdentifier) ?? [])
            selectedLeftoverIdentifiers.formIntersection(listed)
        }
    }

    func refreshLeftovers(afterRemoving identifiers: Set<String>, wait: Bool = false) async {
        guard applicationLeftovers != nil, !identifiers.isEmpty else { return }
        selectedLeftoverIdentifiers.subtract(identifiers)
        loadApplicationLeftovers()
        if wait { await applicationLeftoversTask?.value }
    }

    func toggleLeftoverSelection(_ bundleIdentifier: String) {
        guard !isBusyWithDisk, applicationLeftovers?.groups.contains(where: {
            $0.bundleIdentifier == bundleIdentifier
        }) == true else { return }
        if !selectedLeftoverIdentifiers.insert(bundleIdentifier).inserted {
            selectedLeftoverIdentifiers.remove(bundleIdentifier)
        }
    }

    /// Capture the reviewed paths and preferences before removal starts.
    func requestLeftoverRemoval() async {
        guard !Task.isCancelled, !isBusyWithDisk, !isLoadingApplicationLeftovers,
              pendingLeftoverRemoval == nil,
              let leftovers = applicationLeftovers else { return }
        let identifiers = selectedLeftoverIdentifiers
        let items = leftovers.groups
            .filter { identifiers.contains($0.bundleIdentifier) }
            .flatMap(\.items)
        guard !items.isEmpty else { return }
        let settings = preferences()
        let review = LeftoverRemovalReview(
            plan: leftovers, identifiers: identifiers, items: items, keepReceipt: settings.keepReceipt
        )
        if settings.confirmBeforeCleanup {
            pendingLeftoverRemoval = review
            return
        }
        await performLeftoverRemoval(review)
    }

    func confirmLeftoverRemoval() async {
        guard let review = pendingLeftoverRemoval else { return }
        pendingLeftoverRemoval = nil
        await performLeftoverRemoval(review)
    }

    private func performLeftoverRemoval(_ review: LeftoverRemovalReview) async {
        guard let operation = operations.begin(.appLeftoverRemoval) else { return }
        let leftovers = review.plan
        let identifiers = review.identifiers
        let items = review.items
        let keepReceipt = review.keepReceipt
        let paths = Set(items.map(\.id))
        let bytes = items.reduce(0) { $0 + $1.allocatedBytes }
        onEvent(.removalStarted(count: items.count, bytes: bytes))
        let task = startRemoval(operation) { [self] in
            var presentation = OperationPresentationDuration()
            presentation.extend(toShow: .deletion(bytes: bytes))
            let registered = applications.registeredIdentifiers(leftovers.ownerBundleIdentifiers(for: identifiers))
            let outcome = (try? await remover.removeOrphanedAppLeftovers(
                leftovers, bundleIdentifiers: identifiers, itemPaths: paths,
                registeredApplicationBundleIdentifiers: registered,
                keepReceipt: keepReceipt
            )) ?? CleanupOutcome(failed: Array(paths).sorted())
            await refreshLeftovers(afterRemoving: identifiers, wait: true)
            try? await presentation.wait()
            onEvent(.removed(outcome))
            return true
        }
        await task.value
    }

    func refreshInstalledApplications() {
        invalidateDetailCache()
        loadInstalledApplications()
    }

    func loadInstalledApplications() {
        installedApplicationsTask?.cancel()
        let context = makeContext()
        let id = UUID()
        installedID = id
        installedApplicationsTask = Task { [self] in
            defer {
                if installedID == id {
                    installedApplicationsTask = nil
                    installedID = nil
                }
            }
            let applications = await scanner.installedApplications(context: context)
            guard !Task.isCancelled, installedID == id else { return }
            installedApplications = applications
            let listed = Set(applications.map(\.id))
            installedApplicationBytes = installedApplicationBytes.filter { listed.contains($0.key) }
            selectedApplicationIDs.formIntersection(listed)
            installedApplicationsMeasured = applications.allSatisfy { installedApplicationBytes[$0.id] != nil }
            for application in applications where installedApplicationBytes[application.id] == nil {
                guard await beforeSizeMeasurement() else { return }
                guard !Task.isCancelled, installedID == id else { return }
                guard let bytes = try? await scanner.allocatedBytes(at: application.url, context: context)
                else { continue }
                guard !Task.isCancelled, installedID == id else { return }
                installedApplicationBytes[application.id] = bytes
            }
            guard !Task.isCancelled, installedID == id else { return }
            installedApplicationsMeasured = true
        }
    }

    func requestAppUninstall() {
        guard let plan = appUninstallPlan,
              let operation = operations.begin(.appUninstall) else { return }
        let settings = preferences()
        startRemoval(operation) { [self] in
            if plan.managedPackage == nil {
                guard await settings.confirmRemoval(
                    .trash(itemCount: plan.items.count, totalBytes: plan.totalBytes,
                           protectedDataCount: plan.protectedItems.count), using: confirmRemoval
                ) else { return false }
            }
            return await performAppUninstall(plan, keepReceipt: settings.keepReceipt)
        }
    }

    private enum UninstallAttempt {
        case stillRunning
        case interrupted
        case finished(CleanupOutcome)
        case homebrew(HomebrewUninstallOutcome)
    }

    /// Ask the application and its helpers to quit before removal. Never force termination.
    private func attemptUninstall(_ plan: AppUninstallPlan, keepReceipt: Bool) async -> UninstallAttempt {
        let applicationName = plan.applicationName
        let applicationOnly = plan.isApplicationOnly
        onEvent(.uninstalling(name: applicationName, applicationOnly: applicationOnly, waiting: false, homebrew: false))
        if applications.isRunning(plan.applicationURL) {
            onEvent(.uninstalling(name: applicationName, applicationOnly: applicationOnly, waiting: true, homebrew: false))
            guard await applications.quit(plan.applicationURL) else { return .stillRunning }
        }
        onEvent(.uninstalling(name: applicationName, applicationOnly: applicationOnly, waiting: false, homebrew: false))

        if plan.managedPackage != nil {
            onEvent(.uninstalling(name: applicationName, applicationOnly: true, waiting: false, homebrew: true))
            return .homebrew(await homebrewRemover.uninstall(
                plan, keepReceipt: keepReceipt
            ))
        }

        do {
            return .finished(try await remover.uninstall(
                plan, keepReceipt: keepReceipt
            ))
        } catch {
            return .interrupted
        }
    }

    private func performAppUninstall(_ plan: AppUninstallPlan, keepReceipt: Bool) async -> Bool {
        appUninstallError = nil
        let presentation = OperationPresentationDuration()

        let outcome: CleanupOutcome
        switch await attemptUninstall(plan, keepReceipt: keepReceipt) {
        case .stillRunning:
            appUninstallError = "\(plan.applicationName) is still running. "
                + "Quit it and try again; no files were removed."
            return false
        case .interrupted:
            appUninstallError = "The uninstall was interrupted. Review the application and try again."
            return false
        case .finished(let finished):
            outcome = finished
        case .homebrew(let finished):
            var result = BatchUninstallOutcome()
            result.recordHomebrew(finished, plan: plan)
            batchUninstallOutcome = result
            appUninstallPlan = nil
            if finished.applicationRemoved { selectedApplicationIDs.remove(plan.applicationURL.path) }
            try? await presentation.wait()
            return true
        }

        appUninstallOutcome = outcome
        lastUninstalledApplicationName = plan.applicationName
        appUninstallPlan = nil
        selectedApplicationIDs.remove(plan.applicationURL.path)

        let applicationFailed = outcome.failed.contains(plan.applicationURL.path)
        if applicationFailed {
            let relatedFilesMessage = plan.isApplicationOnly
                ? "" : " No related files were removed."
            appUninstallError = "\(plan.applicationName) could not be moved to the Trash."
                + relatedFilesMessage
        }

        try? await presentation.wait()
        return true
    }

    // MARK: Several applications at once

    /// The selected tab determines the toolbar action.
    enum UninstallerTab: String, CaseIterable {
        case installed = "Installed"
        case leftovers = "Leftovers"
    }
    var uninstallerTab: UninstallerTab = .installed

    /// Reviews and results supply their own actions.
    var isShowingUninstallerLibrary: Bool {
        !isShowingAppUninstallDetail && batchUninstallReview == nil
            && appUninstallOutcome == nil && batchUninstallOutcome == nil
            && !isPlanningAppUninstall
    }

    /// Return a total only after all selected applications have measured sizes.
    var selectedApplicationBytes: Int64? {
        var total: Int64 = 0
        for id in selectedApplicationIDs {
            guard let bytes = installedApplicationBytes[id] else { return nil }
            total += bytes
        }
        return total
    }

    private(set) var selectedApplicationIDs: Set<String> = []

    func toggleApplicationSelection(_ application: InstalledApplication) {
        guard !isBusyWithDisk else { return }
        if selectedApplicationIDs.remove(application.id) == nil {
            selectedApplicationIDs.insert(application.id)
        }
    }

    func clearApplicationSelection() { selectedApplicationIDs.removeAll() }

    /// An application that needs attention, with its next available actions.
    struct SetAsideApplication {
        enum Kind { case notAttempted, failed }
        let name: String
        let reason: String
        var kind: Kind = .notAttempted
        var applicationURL: URL?
        var managedPackage: AppUninstallPlan.ManagedPackage?
        var details: String?
    }

    /// Captures checked application plans and applications that cannot be removed.
    struct BatchUninstallReview {
        let plans: [AppUninstallPlan]
        let setAside: [SetAsideApplication]

        var homebrewCount: Int { plans.filter { $0.managedPackage != nil }.count }
    }

    struct BatchUninstallOutcome {
        var uninstalled: [String] = []
        var setAside: [SetAsideApplication] = []
        var removedBytes: Int64 = 0
        var survivorCount = 0
        var homebrewUninstalled: [String] = []

        var title: String {
            if uninstalled.isEmpty {
                return setAside.allSatisfy { $0.kind == .notAttempted }
                    ? "No applications were removed" : "Removal needs attention"
            }
            return "\(uninstalled.count) \(uninstalled.count == 1 ? "application" : "applications") uninstalled"
        }

        mutating func recordHomebrew(_ outcome: HomebrewUninstallOutcome, plan: AppUninstallPlan) {
            if outcome.status == .completed {
                uninstalled.append(plan.applicationName)
                homebrewUninstalled.append(plan.applicationName)
                removedBytes += outcome.relatedCleanup.removedBytes
                survivorCount += outcome.relatedCleanup.failed.count
                if !outcome.relatedCleanup.failed.isEmpty {
                    setAside.append(SetAsideApplication(
                        name: plan.applicationName, reason: "Homebrew removed the application. Moppo could not move some related data to the Trash.",
                        kind: .failed, details: outcome.relatedCleanup.failed.joined(separator: "\n")
                    ))
                }
            } else {
                setAside.append(SetAsideApplication(
                    name: plan.applicationName, reason: outcome.message,
                    kind: outcome.status == .notStarted ? .notAttempted : .failed,
                    applicationURL: outcome.applicationRemoved ? nil : plan.applicationURL,
                    managedPackage: plan.managedPackage, details: outcome.details
                ))
            }
        }
    }

    private(set) var batchUninstallReview: BatchUninstallReview?
    private(set) var batchUninstallOutcome: BatchUninstallOutcome?
    /// "Slack · 2 of 5" under the planning spinner; nil for a single application.
    private(set) var appUninstallPlanningDetail: String?

    /// Checks selected applications before removal. Homebrew always requires a review.
    func moveSelectedApplicationsToTrash() {
        let selected = (installedApplications ?? [])
            .filter { selectedApplicationIDs.contains($0.id) }
        guard !selected.isEmpty, !isBusyWithDisk, !isPlanningAppUninstall else { return }

        guard canPlan(), let operation = operations.begin(.appUninstallPlanning) else { return }
        resetAppUninstall()
        let context = makeContext()
        let settings = preferences()
        startPlanning(operation, then: { [self] in
            guard !settings.confirmBeforeCleanup, let review = batchUninstallReview,
                  review.homebrewCount == 0 else { return }
            startBatchUninstall(review, keepReceipt: settings.keepReceipt)
        }) { [self] planningID in
            var plans: [AppUninstallPlan] = []
            var setAside: [SetAsideApplication] = []
            for (index, application) in selected.enumerated() {
                guard !Task.isCancelled else { return }
                appUninstallPlanningDetail = "\(application.name) · \(index + 1) of \(selected.count)"
                do {
                    let plan = try await scanner.plan(
                        applicationURL: application.url, context: context
                    )
                    plans.append(plan)
                } catch is CancellationError {
                    return
                } catch {
                    setAside.append(SetAsideApplication(
                        name: application.name, reason: error.localizedDescription,
                        applicationURL: application.url
                    ))
                }
            }
            guard !Task.isCancelled, appUninstallPlanningID == planningID else { return }
            batchUninstallReview = BatchUninstallReview(plans: plans, setAside: setAside)
        }
    }

    func requestBatchUninstall() {
        guard let review = batchUninstallReview else { return }
        startBatchUninstall(review, keepReceipt: preferences().keepReceipt)
    }

    private func startBatchUninstall(_ review: BatchUninstallReview, keepReceipt: Bool) {
        guard !review.plans.isEmpty,
              let operation = operations.begin(.appUninstall) else { return }
        startRemoval(operation) { [self] in
            await performBatchUninstall(review, keepReceipt: keepReceipt)
        }
    }

    /// Remove each application through its reviewed removal service.
    private func performBatchUninstall(_ request: BatchUninstallReview, keepReceipt: Bool) async -> Bool {
        appUninstallError = nil
        let presentation = OperationPresentationDuration()

        var result = BatchUninstallOutcome(setAside: request.setAside)
        for plan in request.plans {
            let name = plan.applicationName
            switch await attemptUninstall(plan, keepReceipt: keepReceipt) {
            case .stillRunning:
                result.setAside.append(SetAsideApplication(
                    name: name, reason: "Still running. No files were removed.",
                    applicationURL: plan.applicationURL, managedPackage: plan.managedPackage
                ))
            case .interrupted:
                result.setAside.append(SetAsideApplication(
                    name: name, reason: "The uninstall was interrupted.", kind: .failed,
                    applicationURL: plan.applicationURL
                ))
            case .homebrew(let outcome):
                result.recordHomebrew(outcome, plan: plan)
                if outcome.applicationRemoved { selectedApplicationIDs.remove(plan.applicationURL.path) }
            case .finished(let outcome):
                result.removedBytes += outcome.removedBytes
                if outcome.failed.contains(plan.applicationURL.path) {
                    result.setAside.append(SetAsideApplication(
                        name: name,
                        reason: "Could not be moved to the Trash. No related files were removed.",
                        kind: .failed, applicationURL: plan.applicationURL
                    ))
                } else {
                    result.uninstalled.append(name)
                    result.survivorCount += outcome.failed.count
                    selectedApplicationIDs.remove(plan.applicationURL.path)
                }
            }
        }

        batchUninstallReview = nil
        // The done page lists what was uninstalled and what is still installed.
        batchUninstallOutcome = result

        try? await presentation.wait()
        return true
    }
}
