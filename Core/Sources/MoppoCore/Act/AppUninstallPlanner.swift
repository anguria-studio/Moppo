import Darwin
import Foundation

/// A reviewed, immutable description of one application uninstall.
///
/// The plan uses exact bundle identifiers or explicit app data rules for related files.
/// If the identifier is not valid, the plan contains only the application.
/// Cleanup checks each path again before it moves any item.
public struct AppUninstallPlan: Sendable, Equatable, Identifiable {

    /// A related path that the uninstall keeps on disk.
    public struct PreservedPath: Sendable, Equatable, Identifiable {
        public enum Reason: Sendable, Equatable, CaseIterable {
            case excluded
            case protectedContent
            case databaseData
            case sharedGroupContainer
            case unverifiedLocation
            case sharedSoundContent
            case unlistedSoundContent
            case unreadable

            /// The review shows this text below the path.
            public var explanation: String {
                switch self {
                case .excluded:
                    "Your exclusion list includes this path or an item in it."
                case .protectedContent:
                    "This folder holds protected items, such as a keychain or a disk image."
                case .databaseData:
                    "This folder holds database data."
                case .sharedGroupContainer:
                    "Another application can use this group container, or Moppo cannot read the code signatures."
                case .unverifiedLocation:
                    "Moppo cannot verify that this location is safe to remove."
                case .sharedSoundContent:
                    "Another installed application uses this sound content."
                case .unlistedSoundContent:
                    "This folder holds files that the installer receipt does not list."
                case .unreadable:
                    "Moppo cannot read all items in this folder."
                }
            }
        }

        public var id: String { url.path }
        public let url: URL
        public let reason: Reason
        /// Nil when Moppo does not measure the path, such as an excluded path,
        /// or when Moppo cannot read any item in it.
        public let allocatedBytes: Int64?
        /// The item that removes this path when the user opts in after a warning.
        /// Only a shared group container that passes every other check has one.
        public let optInItem: Item?
        /// The other applications that claim the group of a shared group container.
        /// Nil when Moppo cannot read the claims. See `ApplicationGroupClaims.groupsClaimedElsewhere`.
        public let claimingApplications: [URL]?

        public init(url: URL, reason: Reason, allocatedBytes: Int64? = nil) {
            self.url = url
            self.reason = reason
            self.allocatedBytes = allocatedBytes
            self.optInItem = nil
            self.claimingApplications = nil
        }

        init(url: URL, reason: Reason, measurement: SizeMeasurement) {
            let nothingRead = measurement.allocatedBytes == 0 && measurement.unreadableCount > 0
            self.init(url: url, reason: reason,
                      allocatedBytes: nothingRead ? nil : measurement.allocatedBytes)
        }

        init(sharedGroupContainer item: Item, claimingApplications: [URL]?) {
            self.url = item.url
            self.reason = .sharedGroupContainer
            self.allocatedBytes = item.allocatedBytes
            self.optInItem = item
            self.claimingApplications = claimingApplications
        }
    }

    public struct ManagedPackage: Sendable, Equatable {
        public enum Manager: String, Sendable {
            case homebrew = "Homebrew"
        }

        public let manager: Manager
        public let name: String
        public let executable: String

        public var uninstallCommand: String {
            "\(executable) uninstall --cask \(name)"
        }
    }

    public struct Item: Sendable, Equatable, Identifiable {
        public enum Category: String, Sendable, CaseIterable {
            case application
            case support
            case caches
            case preferences
            case containers
            case logs
            case state
            case helpers
        }

        /// What kind of app-owned content this item contains.
        public enum Content: String, Sendable {
            /// The target `.app` bundle. It is mandatory and always goes first.
            case application
            /// Scratch data the app recreates.
            case regenerable
            /// Diagnostic records that the app writes. Old records do not come back.
            case logs
            /// Launch items and privileged helpers that exist only for the app.
            case appComponent
            /// Profiles, preferences, documents, sessions, and other user state.
            case userData
            /// Downloaded sound content that requires review before removal.
            case soundLibrary
        }

        public var id: String { url.standardizedFileURL.path }
        public let url: URL
        public let displayName: String
        public let category: Category
        public let content: Content
        public let allocatedBytes: Int64
        public let ownerBundleIdentifier: String?
        /// The app group of a group container. Only the selected application claims it.
        let applicationGroup: String?
        let plannedIdentity: String?
        public let soundLibrary: AppleSoundLibrary.Inventory?

        public var isProtectedUserData: Bool { content == .userData }

        init(
            url: URL,
            displayName: String? = nil,
            category: Category,
            content: Content,
            allocatedBytes: Int64,
            ownerBundleIdentifier: String?,
            applicationGroup: String? = nil,
            soundLibrary: AppleSoundLibrary.Inventory? = nil
        ) {
            self.url = url.standardizedFileURL
            self.displayName = displayName ?? url.lastPathComponent
            self.category = category
            self.content = content
            self.allocatedBytes = allocatedBytes
            self.ownerBundleIdentifier = ownerBundleIdentifier
            self.applicationGroup = applicationGroup
            self.plannedIdentity = FileIdentity.of(url)
            self.soundLibrary = soundLibrary
        }

        public var fileEntry: FileEntry {
            let kind: FileEntry.Kind = switch category {
            case .application: .appBundle
            case .caches, .state: .cache
            case .logs: (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ? .folder : .file
            case .preferences: .file
            case .support, .containers, .helpers: .folder
            }
            return FileEntry(
                url: url,
                displayName: displayName,
                kind: kind,
                allocatedBytes: allocatedBytes,
                isRegenerable: content == .regenerable,
                notRegenerable: content == .logs ? .logs : nil,
                protectionReason: content == .userData ? .userData : nil,
                soundLibrary: soundLibrary
            )
        }
    }

    public var id: String { applicationURL.path }
    public let applicationURL: URL
    public let applicationName: String
    public let bundleIdentifier: String?
    public let items: [Item]
    /// Package ownership is informational and a hard direct-removal gate. The
    /// package manager must remove its own receipt and app artifact together.
    public let managedPackage: ManagedPackage?
    /// The installer package the application came from, when a receipt lists it —
    /// see `InstallerReceipts`. Information for the review, never a gate: the
    /// application is removed as any other, and the review says what the same
    /// installer wrote elsewhere, which stays.
    public var installerPackage: InstallerReceipts.Package?
    /// Sound content stays unless the user requests its separate removal.
    public var soundLibraryItems: [Item] = []
    /// Related paths that stay on disk, such as excluded paths, protected content,
    /// database data, and shared group containers. The plan never removes them.
    /// The review names each one with its reason.
    public var preservedPaths: [PreservedPath]
    public var soundLibraryUnreadableCount = 0
    /// Shared group containers that the user chose to remove after the warning.
    /// Moppo removes them after the application. See `includingSharedGroupContainers(_:context:)`.
    public private(set) var optedInItems: [Item] = []
    /// The exclusion rules when the user confirmed the removal. Moppo checks the opted-in items against them again.
    private(set) var optInExcludedPaths: [String] = []
    private(set) var optInExcludedPatterns: [String] = []

    let candidateBundleIdentifiers: Set<String>
    /// The home folder of the review. Moppo finds database folders in it again at removal.
    let home: URL
    let applicationRoots: [URL]
    let allowedRelatedRoots: [URL]
    /// Named data folders outside `allowedRelatedRoots`. See `ApplicationDataFolders`.
    let allowedRelatedFolders: [URL]

    public var applicationItem: Item { items[0] }
    /// No related file could be attributed: there is no identifier to match on, or
    /// the identifier is one no single application owns (every Shortcuts droplet
    /// carries `com.apple.shortcuts.droplet`). An ordinary plan always has at least
    /// its primary identifier as a candidate.
    public var isApplicationOnly: Bool {
        bundleIdentifier == nil || candidateBundleIdentifiers.isEmpty
    }
    public var protectedItems: [Item] { items.filter(\.isProtectedUserData) }

    /// The review heading. A plan that keeps related paths on disk is not complete.
    public var reviewTitle: String {
        if isApplicationOnly { return "Application-only uninstall" }
        return preservedPaths.isEmpty ? "Complete uninstall" : "Partial uninstall"
    }

    public var reviewDetail: String {
        if isApplicationOnly {
            return "Moppo cannot identify related files safely. Removal includes only the application."
        }
        let removal = protectedItems.isEmpty
            ? "Every verified related file below will move to the Trash."
            : "Every verified related file below will move to the Trash, including profiles and settings."
        switch preservedPaths.count {
        case 0: return removal
        case 1: return removal + " 1 related path stays on disk."
        case let count: return removal + " \(count) related paths stay on disk."
        }
    }
    public var totalBytes: Int64 { items.reduce(0) { $0 + $1.allocatedBytes } }

    /// A copy of the plan that also removes the selected shared group containers.
    ///
    /// Only rows with an `optInItem` can be selected. Other preserved paths stay on disk.
    /// - Parameter context: the current exclusion rules. Moppo checks them again at removal.
    public func includingSharedGroupContainers(_ ids: Set<String>, context: ScanContext) -> AppUninstallPlan {
        var plan = self
        plan.optedInItems = preservedPaths.filter { ids.contains($0.id) }.compactMap(\.optInItem)
        guard !plan.optedInItems.isEmpty else { return plan }
        plan.optInExcludedPaths = context.excludedPaths
        plan.optInExcludedPatterns = context.excludedPatterns
        return plan
    }

    /// Mandatory app first, then every related item. If the bundle cannot
    /// move, cleanup aborts before profiles or settings can be touched.
    func removalOrder() -> [Item] {
        // Nested paths before their containing folder. This both honours the
        // review rows and gives each moved subtree its own accurate receipt before
        // the curated remainder root follows.
        let related = items.dropFirst()
            .sorted {
                let lhsDepth = $0.url.pathComponents.count
                let rhsDepth = $1.url.pathComponents.count
                if lhsDepth != rhsDepth { return lhsDepth > rhsDepth }
                return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
        return [applicationItem] + related
    }

    init(
        applicationURL: URL,
        applicationName: String,
        bundleIdentifier: String?,
        items: [Item],
        managedPackage: ManagedPackage?,
        preservedPaths: [PreservedPath],
        candidateBundleIdentifiers: Set<String>,
        home: URL,
        applicationRoots: [URL],
        allowedRelatedRoots: [URL],
        allowedRelatedFolders: [URL] = []
    ) {
        precondition(items.first?.content == .application)
        self.applicationURL = applicationURL.standardizedFileURL
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.items = items
        self.managedPackage = managedPackage
        self.preservedPaths = preservedPaths
        self.candidateBundleIdentifiers = candidateBundleIdentifiers
        self.home = home.standardizedFileURL
        self.applicationRoots = applicationRoots.map(\.standardizedFileURL)
        self.allowedRelatedRoots = allowedRelatedRoots.map(\.standardizedFileURL)
        self.allowedRelatedFolders = allowedRelatedFolders.map(\.standardizedFileURL)
    }
}

public enum AppUninstallPlanningError: Error, Sendable, Equatable, LocalizedError {
    case notAnApplication
    case applicationMissing
    case untrustedLocation
    case protectedApplication
    case symbolicLink
    case applicationExcluded
    case protectedContent(String)
    case packageOwnershipUnavailable

    public var errorDescription: String? {
        switch self {
        case .notAnApplication:
            "Choose a valid macOS application bundle."
        case .applicationMissing:
            "The application is no longer at its original location. Review Leftovers to check for remaining data."
        case .untrustedLocation:
            "Only applications installed in /Applications or your Applications folder can be uninstalled."
        case .protectedApplication:
            "System applications and Moppo itself cannot be removed here. An application "
                + "with an Apple identifier needs an App Store receipt to be offered."
        case .symbolicLink:
            "This application is reached through a symbolic link. Reveal and remove the original application instead."
        case .applicationExcluded:
            "This application is protected by an exclusion in Moppo settings."
        case .protectedContent(let path):
            "The application contains protected content at \(path), so Moppo will not offer it for removal."
        case .packageOwnershipUnavailable:
            "Homebrew is installed but its package catalog could not be read. Try again before removing this application."
        }
    }
}

/// Builds exact, reviewable uninstall plans for installed applications.
public struct AppUninstallPlanner: Sendable {
    let home: URL
    let userLibrary: URL
    let systemLibrary: URL
    let applicationRoots: [URL]
    let darwinCache: URL?
    let darwinTemp: URL?
    private let homebrewExecutable: String?
    private let loadHomebrewCatalog: @Sendable (String) async throws -> Data
    /// Nil in fixture tests, which must not read this machine's receipts.
    private let installerReceipts: InstallerReceipts?
    let soundLibraries: AppleSoundLibrary?
    let protectedBundleIdentifiers: Set<String>
    let applicationGroupClaims: ApplicationGroupClaims

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        self.init(
            home: home,
            systemLibrary: URL(fileURLWithPath: "/Library", isDirectory: true),
            applicationRoots: [
                URL(fileURLWithPath: "/Applications", isDirectory: true),
                home.appendingPathComponent("Applications", isDirectory: true),
            ],
            darwinCache: Self.darwinUserDirectory(_CS_DARWIN_USER_CACHE_DIR),
            darwinTemp: Self.darwinUserDirectory(_CS_DARWIN_USER_TEMP_DIR),
            homebrewExecutable: Self.homebrewExecutables.first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }),
            protectedBundleIdentifiers: [
                "com.tommasolaterza.Moppo",
                Bundle.main.bundleIdentifier ?? "com.tommasolaterza.Moppo",
            ],
            installerReceipts: InstallerReceipts(),
            soundLibraries: AppleSoundLibrary(),
            applicationGroupClaims: .live
        )
    }

    /// Internal configuration point used by deterministic sandbox tests.
    init(
        home: URL,
        systemLibrary: URL,
        applicationRoots: [URL],
        darwinCache: URL?,
        darwinTemp: URL?,
        homebrewExecutable: String? = nil,
        processRunner: ProcessRunner = ProcessRunner(),
        loadHomebrewCatalog: (@Sendable (String) async throws -> Data)? = nil,
        protectedBundleIdentifiers: Set<String> = ["com.tommasolaterza.Moppo"],
        installerReceipts: InstallerReceipts? = nil,
        soundLibraries: AppleSoundLibrary? = nil,
        applicationGroupClaims: ApplicationGroupClaims = .applicationRootsOnly
    ) {
        self.home = home.standardizedFileURL
        self.userLibrary = home.appendingPathComponent("Library", isDirectory: true)
            .standardizedFileURL
        self.systemLibrary = systemLibrary.standardizedFileURL
        self.applicationRoots = applicationRoots.map(\.standardizedFileURL)
        self.darwinCache = darwinCache?.standardizedFileURL
        self.darwinTemp = darwinTemp?.standardizedFileURL
        self.homebrewExecutable = homebrewExecutable
        self.loadHomebrewCatalog = loadHomebrewCatalog ?? { executable in
            try await processRunner.run(executable, ["info", "--json=v2", "--installed"], timeout: .seconds(20))
        }
        self.protectedBundleIdentifiers = protectedBundleIdentifiers
        self.installerReceipts = installerReceipts
        self.soundLibraries = soundLibraries
        self.applicationGroupClaims = applicationGroupClaims
    }

    public func plan(
        applicationURL: URL,
        context: ScanContext = ScanContext()
    ) async throws -> AppUninstallPlan {
        try await plan(applicationURL: applicationURL, context: context, ownership: nil, catalog: nil)
    }

    /// Shares ownership checks within one review. Removal always checks current owners again.
    public func plans(
        applicationURLs: [URL],
        context: ScanContext = ScanContext(),
        onProgress: @escaping @Sendable (Int) async -> Void = { _ in }
    ) async throws -> [Result<AppUninstallPlan, Error>] {
        guard !applicationURLs.isEmpty else { return [] }
        try Task.checkCancellation()
        let ownership = try Self.applicationOwnership(in: applicationRoots)
        let catalog: Result<Data, Error>?
        if let homebrewExecutable {
            do { catalog = .success(try await loadHomebrewCatalog(homebrewExecutable)) }
            catch is CancellationError { throw CancellationError() }
            catch { catalog = .failure(error) }
        } else { catalog = nil }
        return try await Self.planBatch(applicationURLs: applicationURLs, onProgress: onProgress) { url in
            try await plan(applicationURL: url, context: context, ownership: ownership, catalog: catalog)
        }
    }

    static func planBatch(
        applicationURLs: [URL],
        onProgress: @escaping @Sendable (Int) async -> Void,
        plan: @escaping @Sendable (URL) async throws -> AppUninstallPlan
    ) async throws -> [Result<AppUninstallPlan, Error>] {
        try await withThrowingTaskGroup(of: (Int, Result<AppUninstallPlan, Error>).self) { group in
            var next = 0
            var results: [Int: Result<AppUninstallPlan, Error>] = [:]
            func submit() {
                guard next < applicationURLs.count else { return }
                let index = next
                let url = applicationURLs[index]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    do { return (index, .success(try await plan(url))) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (index, .failure(error)) }
                }
            }
            try Task.checkCancellation()
            for _ in 0..<min(3, applicationURLs.count) { submit() }
            for try await (index, result) in group {
                try Task.checkCancellation()
                results[index] = result
                await onProgress(results.count)
                try Task.checkCancellation()
                submit()
            }
            try Task.checkCancellation()
            return applicationURLs.indices.compactMap { results[$0] }
        }
    }

    private func plan(
        applicationURL: URL, context: ScanContext,
        ownership: [String: Set<String>]?, catalog: Result<Data, Error>?
    ) async throws -> AppUninstallPlan {
        var plan = try await planWithoutReceipts(
            applicationURL: applicationURL, context: context, ownership: ownership, catalog: catalog
        )
        if let identifier = plan.bundleIdentifier,
           AppleSoundLibrary.ownerIdentifiers.contains(identifier), let soundLibraries {
            let installed = (ownership.map { $0.values.reduce(into: Set<String>()) { $0.formUnion($1) } }
                ?? Self.installedBundleIdentifiers(in: applicationRoots))
                .union(context.registeredApplicationBundleIdentifiers)
            let content = try await soundLibraries.scan(
                context: context, installedOwners: installed, applicationIdentifier: identifier
            )
            plan.soundLibraryItems = content.items
            plan.preservedPaths = Self.deduplicated(plan.preservedPaths + content.preservedPaths)
            plan.soundLibraryUnreadableCount = content.unreadableCount
        }
        // Asked last, and only of an application the plan has accepted. It never
        // refuses one: a receipt that cannot be read is a note that is not shown.
        if plan.managedPackage == nil {
            plan.installerPackage = await installerReceipts?.package(owning: plan.applicationURL)
        }
        return plan
    }

    private func planWithoutReceipts(
        applicationURL rawApplicationURL: URL,
        context: ScanContext,
        ownership: [String: Set<String>]?, catalog: Result<Data, Error>?
    ) async throws -> AppUninstallPlan {
        try Task.checkCancellation()
        let fm = FileManager.default
        let applicationURL = rawApplicationURL.standardizedFileURL
        if applicationURL.pathExtension.lowercased() == "app", FileIdentity.isAbsent(applicationURL) {
            throw AppUninstallPlanningError.applicationMissing
        }
        guard applicationURL.pathExtension.lowercased() == "app",
              fm.fileExists(atPath: applicationURL.path),
              let bundle = Bundle(url: applicationURL)
        else { throw AppUninstallPlanningError.notAnApplication }
        guard Self.isInside(applicationURL, oneOf: applicationRoots) else {
            throw AppUninstallPlanningError.untrustedLocation
        }
        guard !Self.isSymbolicLink(applicationURL),
              applicationURL.resolvingSymlinksInPath().standardizedFileURL == applicationURL
        else { throw AppUninstallPlanningError.symbolicLink }
        let bundleIdentifier = Self.verifiedBundleIdentifier(bundle.bundleIdentifier)
        let scope = uninstallScope(identifier: bundleIdentifier, applicationURL: applicationURL)
        guard scope != .refused else { throw AppUninstallPlanningError.protectedApplication }
        guard !context.isExcluded(applicationURL) else {
            throw AppUninstallPlanningError.applicationExcluded
        }

        let applicationMeasurement = try await context.measurer.measure(applicationURL)
        guard !applicationMeasurement.containsProtectedPattern else {
            throw AppUninstallPlanningError.protectedContent(applicationURL.path)
        }

        var name = applicationURL.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = applicationURL.lastPathComponent }

        let managedPackage: AppUninstallPlan.ManagedPackage?
        do {
            managedPackage = try await homebrewPackage(managing: applicationURL, catalog: catalog)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Failing open could trash a cask artifact while leaving Homebrew's
            // receipt behind. Ownership uncertainty is therefore a visible stop.
            throw AppUninstallPlanningError.packageOwnershipUnavailable
        }

        let applicationItem = AppUninstallPlan.Item(
            url: applicationURL,
            displayName: name,
            category: .application,
            content: .application,
            allocatedBytes: applicationMeasurement.allocatedBytes,
            ownerBundleIdentifier: nil
        )

        // Every removal path uses the same related-file ownership checks.
        guard let bundleIdentifier, scope != .applicationOnly else {
            return AppUninstallPlan(
                applicationURL: applicationURL,
                applicationName: name,
                bundleIdentifier: bundleIdentifier,
                items: [applicationItem],
                managedPackage: managedPackage,
                preservedPaths: [],
                candidateBundleIdentifiers: [],
                home: home,
                applicationRoots: applicationRoots,
                allowedRelatedRoots: allowedRelatedRoots,
                allowedRelatedFolders: allowedRelatedFolders
            )
        }

        let bundleIDs = scope == .exactIdentifier
            ? [bundleIdentifier]
            : ownership?[applicationURL.path] ?? Self.allBundleIdentifiers(in: applicationURL, fileManager: fm)
        // Under an Apple identifier only the application's own name is matched.
        // The prefix rule below is sound for a vendor, who owns everything under
        // their reverse-DNS name; nobody but the system owns `com.apple.`, and what
        // else answers to a name beneath this one cannot be known from here.
        let candidateIDs = scope == .exactIdentifier
            ? [bundleIdentifier]
            : Self.ownedBundleIdentifiers(
                in: applicationURL, primary: bundleIdentifier, fileManager: fm,
                knownIdentifiers: bundleIDs
            )
        // A launch file can name any bundle in the application, such as an updater
        // that does not use the application identifier. See `LaunchItemFile`.
        let exclusiveBundleIDs = try Self.exclusiveBundleIdentifiers(
            candidates: candidateIDs.union(bundleIDs),
            selectedApplication: applicationURL,
            applicationRoots: applicationRoots,
            fileManager: fm,
            ownership: ownership,
            checkCancellation: Task.checkCancellation
        )
        let exclusiveIDs = exclusiveBundleIDs.intersection(candidateIDs)

        var items: [AppUninstallPlan.Item] = [applicationItem]
        var preserved: [AppUninstallPlan.PreservedPath] = []
        let databaseFolders = DatabaseStorage.locations(home: home)
        var claimedPaths = Set(items.map(\.id))

        // Several applications can share a group container, and an entitlement
        // defines its name. So a name that matches the identifier is not proof of
        // exclusive ownership. A container becomes user data only when the
        // signatures show that this application alone claims its group.
        // Other containers stay on disk, and the review shows them. The user can
        // opt in to remove one after a warning. Under an Apple identifier, system
        // services outside any application can claim the group.
        let groupContainers = groupContainers(for: exclusiveIDs, primary: bundleIdentifier)
        let groupClaims = scope == .exactIdentifier ? .unknown : try await exclusiveApplicationGroups(
            Set(groupContainers.compactMap(\.applicationGroup)), applicationURL: applicationURL,
            identifiers: bundleIDs.union(candidateIDs)
                .union(context.registeredApplicationBundleIdentifiers)
        )
        // A shared container goes through the same checks as an exclusive container below.
        var sharedContainerPaths = Set<String>()
        var claimingApplications: [String: [URL]] = [:]
        for container in groupContainers {
            if let group = container.applicationGroup, groupClaims.exclusive.contains(group) { continue }
            sharedContainerPaths.insert(container.url.path)
            claimingApplications[container.url.path] = container.applicationGroup.flatMap {
                groupClaims.claimedElsewhere[$0]
            }
        }

        let curation = exclusiveIDs.contains(bundleIdentifier)
            ? ApplicationsScanner.curation(
                bundleID: bundleIdentifier, baseName: name, home: home
            )
            : nil
        let curatedRoot = curation.map {
            home.appendingPathComponent($0.root).standardizedFileURL
        }

        if let curation, let curatedRoot {
            if let curated = try await ApplicationsScanner.curatedChildren(
                curation, home: home, context: context
            ) {
                if curated.holdsProtectedContent {
                    preserved.append(try await Self.preservedPath(
                        curatedRoot,
                        reason: context.isExcluded(curatedRoot) ? .excluded : .protectedContent,
                        context: context
                    ))
                } else {
                    for entry in curated.entries {
                        let item = AppUninstallPlan.Item(
                            url: entry.url,
                            displayName: entry.displayName,
                            category: entry.isRegenerable ? .caches : .support,
                            content: entry.isRegenerable ? .regenerable : .userData,
                            allocatedBytes: entry.allocatedBytes,
                            ownerBundleIdentifier: bundleIdentifier
                        )
                        if claimedPaths.insert(item.id).inserted { items.append(item) }
                    }
                }
            }
        }

        let launchItems = launchItemCandidates(
            applicationURL: applicationURL, primary: bundleIdentifier,
            exclusiveIdentifiers: exclusiveBundleIDs
        )
        for candidate in candidates(for: exclusiveIDs) + launchItems + groupContainers {
            try Task.checkCancellation()
            let isSharedContainer = sharedContainerPaths.contains(candidate.url.path)
            if let curatedRoot,
               ApplicationsScanner.overlaps(candidate.url.standardizedFileURL.path,
                                            curatedRoot.path) {
                continue
            }
            guard fm.fileExists(atPath: candidate.url.path) else { continue }
            guard candidateIsSafe(candidate.url) else {
                preserved.append(.init(url: candidate.url, reason: .unverifiedLocation))
                continue
            }
            guard DatabaseStorage.location(overlapping: candidate.url, in: databaseFolders) == nil else {
                preserved.append(try await Self.preservedPath(
                    candidate.url, reason: .databaseData, context: context
                ))
                continue
            }
            guard !context.isExcluded(candidate.url) else {
                preserved.append(.init(url: candidate.url, reason: .excluded))
                continue
            }
            let measurement = try await context.measurer.measure(candidate.url)
            // Moppo cannot look for protected content in an item that it cannot read.
            // So a shared container that the user can opt in to remove must be fully readable.
            if isSharedContainer, measurement.unreadableCount > 0 {
                preserved.append(.init(url: candidate.url, reason: .unreadable, measurement: measurement))
                continue
            }
            guard measurement.allocatedBytes > 0 || isSharedContainer else {
                // macOS can deny access to the group container of another application.
                // The review names the container, because it stays on disk.
                if candidate.applicationGroup != nil, measurement.unreadableCount > 0 {
                    preserved.append(.init(url: candidate.url, reason: .unreadable, measurement: measurement))
                }
                continue
            }
            guard !measurement.containsProtectedPattern else {
                preserved.append(.init(
                    url: candidate.url, reason: .protectedContent, measurement: measurement
                ))
                continue
            }
            let item = AppUninstallPlan.Item(
                url: candidate.url,
                category: candidate.category,
                content: candidate.content,
                allocatedBytes: measurement.allocatedBytes,
                ownerBundleIdentifier: candidate.ownerBundleIdentifier,
                applicationGroup: candidate.applicationGroup
            )
            if isSharedContainer {
                preserved.append(.init(
                    sharedGroupContainer: item, claimingApplications: claimingApplications[candidate.url.path]
                ))
            } else if claimedPaths.insert(item.id).inserted {
                items.append(item)
            }
        }

        let categoryRank = Dictionary(
            uniqueKeysWithValues: AppUninstallPlan.Item.Category.allCases.enumerated().map {
                ($0.element, $0.offset)
            }
        )
        let application = items.removeFirst()
        items.sort {
            let lhs = categoryRank[$0.category, default: 0]
            let rhs = categoryRank[$1.category, default: 0]
            if lhs != rhs { return lhs < rhs }
            if $0.allocatedBytes != $1.allocatedBytes { return $0.allocatedBytes > $1.allocatedBytes }
            return $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }

        return AppUninstallPlan(
            applicationURL: applicationURL,
            applicationName: name,
            bundleIdentifier: bundleIdentifier,
            items: [application] + items,
            managedPackage: managedPackage,
            preservedPaths: Self.deduplicated(preserved),
            candidateBundleIdentifiers: candidateIDs,
            home: home,
            applicationRoots: applicationRoots,
            allowedRelatedRoots: allowedRelatedRoots,
            allowedRelatedFolders: allowedRelatedFolders
        )
    }

    // MARK: Candidate discovery

    struct Candidate {
        let url: URL
        let category: AppUninstallPlan.Item.Category
        let content: AppUninstallPlan.Item.Content
        let ownerBundleIdentifier: String
        var applicationGroup: String? = nil
    }

    func candidates(for bundleIdentifiers: Set<String>) -> [Candidate] {
        var result: [Candidate] = []

        func append(
            _ root: URL,
            _ relative: String,
            _ category: AppUninstallPlan.Item.Category,
            _ content: AppUninstallPlan.Item.Content,
            owner: String
        ) {
            result.append(Candidate(
                url: root.appendingPathComponent(relative), category: category,
                content: content, ownerBundleIdentifier: owner
            ))
        }

        for id in bundleIdentifiers.sorted() {
            append(userLibrary, "Application Support/\(id)", .support, .userData, owner: id)
            append(userLibrary, "Containers/\(id)", .containers, .userData, owner: id)
            append(userLibrary, "Caches/\(id)", .caches, .regenerable, owner: id)
            append(userLibrary, "Preferences/\(id).plist", .preferences, .userData, owner: id)
            append(userLibrary, "Saved Application State/\(id).savedState", .state, .regenerable, owner: id)
            append(userLibrary, "HTTPStorages/\(id)", .caches, .regenerable, owner: id)
            append(userLibrary, "HTTPStorages/\(id).binarycookies", .caches, .regenerable, owner: id)
            append(userLibrary, "WebKit/\(id)", .caches, .regenerable, owner: id)
            append(userLibrary, "Application Scripts/\(id)", .containers, .userData, owner: id)
            append(userLibrary, "Cookies/\(id).binarycookies", .preferences, .userData, owner: id)
            append(userLibrary, "Logs/\(id)", .logs, .logs, owner: id)

            append(systemLibrary, "Application Support/\(id)", .support, .appComponent, owner: id)
            append(systemLibrary, "Caches/\(id)", .caches, .regenerable, owner: id)
            append(systemLibrary, "Preferences/\(id).plist", .preferences, .userData, owner: id)
            append(systemLibrary, "PrivilegedHelperTools/\(id)", .helpers, .appComponent, owner: id)

            for folder in ApplicationDataFolders.folders(for: id, home: home) {
                result.append(Candidate(
                    url: folder, category: .support, content: .userData, ownerBundleIdentifier: id
                ))
            }

            append(home, ".config/\(id)", .support, .userData, owner: id)
            append(home, ".cache/\(id)", .caches, .regenerable, owner: id)
            append(home, ".local/share/\(id)", .support, .userData, owner: id)
            if let darwinCache {
                append(darwinCache, id, .caches, .regenerable, owner: id)
            }
            if let darwinTemp {
                append(darwinTemp, id, .caches, .regenerable, owner: id)
            }

            let byHost = userLibrary.appendingPathComponent("Preferences/ByHost", isDirectory: true)
            for entry in Self.directoryNames(byHost) where Self.matchesByHostPreference(entry, id: id) {
                append(byHost, entry, .preferences, .userData, owner: id)
            }
            for directory in launchItemDirectories {
                let filename = "\(id).plist"
                if Self.directoryNames(directory).contains(filename) {
                    append(directory, filename, .helpers, .appComponent, owner: id)
                }
            }
        }
        return result
    }

    var launchItemDirectories: [URL] {
        [
            userLibrary.appendingPathComponent("LaunchAgents", isDirectory: true),
            systemLibrary.appendingPathComponent("LaunchAgents", isDirectory: true),
            systemLibrary.appendingPathComponent("LaunchDaemons", isDirectory: true),
        ]
    }

    /// Launch files whose name does not match a bundle identifier. See `LaunchItemFile`.
    ///
    /// A file belongs to the application when its program is in the application bundle.
    /// It also belongs to the application when each identifier in `AssociatedBundleIdentifiers`
    /// is a bundle in this application and in no other installed application.
    /// A program in another installed application keeps the file with that application.
    func launchItemCandidates(
        applicationURL: URL, primary: String, exclusiveIdentifiers: Set<String>
    ) -> [Candidate] {
        LaunchItemFile.files(in: launchItemDirectories).compactMap { file in
            let owner: String
            if let program = file.program, Self.isInside(program, root: applicationURL) {
                owner = primary
            } else if file.installedApplication(in: applicationRoots) != nil {
                return nil
            } else if !file.associatedBundleIdentifiers.isEmpty,
                      file.associatedBundleIdentifiers.isSubset(of: exclusiveIdentifiers) {
                owner = file.associatedBundleIdentifiers.contains(primary)
                    ? primary : file.associatedBundleIdentifiers.sorted()[0]
            } else {
                return nil
            }
            guard exclusiveIdentifiers.contains(owner) else { return nil }
            return Candidate(url: file.url, category: .helpers, content: .appComponent, ownerBundleIdentifier: owner)
        }
    }

    /// Group containers whose name matches one of `bundleIdentifiers`. The folder name is the app group.
    private func groupContainers(for bundleIdentifiers: Set<String>, primary: String) -> [Candidate] {
        let root = userLibrary.appendingPathComponent("Group Containers", isDirectory: true)
        return Self.directoryNames(root).sorted().compactMap { name in
            let owners = bundleIdentifiers.filter { identifier in
                name == identifier
                    || name == "group.\(identifier)"
                    || name.hasPrefix("group.\(identifier).")
            }
            guard let owner = owners.contains(primary) ? primary : owners.sorted().first else { return nil }
            return Candidate(
                url: root.appendingPathComponent(name, isDirectory: true).standardizedFileURL,
                category: .containers, content: .userData,
                ownerBundleIdentifier: owner, applicationGroup: name
            )
        }
    }

    struct GroupClaims {
        /// The groups that the application or its code items claim, and no other application claims.
        var exclusive: Set<String> = []
        /// The other applications that claim a group. A group that is not a key has no known claims.
        var claimedElsewhere: [String: [URL]] = [:]

        static let unknown = GroupClaims()
    }

    /// The claims on the groups in `groups`.
    /// Unknown when a signature or the application inventory cannot be read.
    private func exclusiveApplicationGroups(
        _ groups: Set<String>, applicationURL: URL, identifiers: Set<String>
    ) async throws -> GroupClaims {
        guard !groups.isEmpty else { return .unknown }
        do {
            let claimed = try ApplicationGroupClaims.claimedGroups(
                in: applicationURL, checkCancellation: Task.checkCancellation
            ).intersection(groups)
            guard !claimed.isEmpty else { return .unknown }
            let elsewhere = try await applicationGroupClaims.groupsClaimedElsewhere(
                claimed, selectedApplication: applicationURL,
                applicationRoots: applicationRoots, identifiers: identifiers
            )
            return GroupClaims(exclusive: claimed.subtracting(elsewhere.keys), claimedElsewhere: elsewhere)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unknown
        }
    }

    // MARK: Package-manager ownership

    private static let homebrewExecutables = [
        "/opt/homebrew/bin/brew", "/usr/local/bin/brew",
    ]

    private func homebrewPackage(
        managing applicationURL: URL, catalog: Result<Data, Error>?
    ) async throws -> AppUninstallPlan.ManagedPackage? {
        guard let homebrewExecutable else { return nil }
        let data: Data
        if let catalog { data = try catalog.get() }
        else { data = try await loadHomebrewCatalog(homebrewExecutable) }
        return try Self.homebrewPackage(
            in: data, managing: applicationURL, executable: homebrewExecutable
        )
    }

    static func homebrewPackage(
        in data: Data,
        managing applicationURL: URL,
        executable: String
    ) throws -> AppUninstallPlan.ManagedPackage? {
        struct Catalog: Decodable { let casks: [Cask] }
        struct Cask: Decodable {
            let token: String
            let artifacts: [Artifact]
        }
        struct Artifact: Decodable {
            let isApplication: Bool
            let target: String?

            enum CodingKeys: String, CodingKey { case app, target }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                isApplication = values.contains(.app)
                target = try values.decodeIfPresent(String.self, forKey: .target)
            }
        }

        let catalog = try JSONDecoder().decode(Catalog.self, from: data)
        let selectedPath = applicationURL.standardizedFileURL.path
        let matches = catalog.casks.filter { cask in
            Self.validHomebrewToken(cask.token)
                && cask.artifacts.contains { artifact in
                    guard artifact.isApplication, let target = artifact.target else { return false }
                    return Self.expandedHomePath(target).standardizedFileURL.path == selectedPath
                }
        }
        guard matches.count <= 1 else { throw AppUninstallPlanningError.packageOwnershipUnavailable }
        guard let match = matches.first else { return nil }
        return AppUninstallPlan.ManagedPackage(
            manager: .homebrew,
            name: match.token,
            executable: executable
        )
    }

    private static func validHomebrewToken(_ token: String) -> Bool {
        guard !token.isEmpty, !token.hasPrefix("-"),
              !token.contains(".."), !token.contains("//")
        else { return false }
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+@/-"
        )
        return token.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static func expandedHomePath(_ path: String) -> URL {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser }
        if path.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(String(path.dropFirst(2)))
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: Ownership and safety

    static func verifiedBundleIdentifier(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        // Two parts, not three: `net.scribus` is a real application's identifier.
        // Three was a shorthand for "looks like reverse-DNS", and its cost was that
        // Scribus' saved state was nobody's. A bare word is still not an identifier.
        // Every place an identifier is *used* matches it exactly, or beneath it with
        // a dot, so a shorter one claims no more than its own name.
        guard parts.count >= 2 else { return nil }
        for part in parts where part.isEmpty { return nil }
        for scalar in rawValue.unicodeScalars {
            let valid = (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
                || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "-" || scalar == "_"
            guard valid else { return nil }
        }
        return rawValue
    }

    // MARK: - Who may be uninstalled

    /// How far the uninstaller may go for one application.
    enum UninstallScope: Equatable {
        /// The application and everything under its vendor's identifier.
        case full
        /// The application and what is named by its identifier exactly.
        case exactIdentifier
        /// The application alone.
        case applicationOnly
        case refused
    }

    /// An Apple identifier was refused outright until 19 Sep 2026, on the reading
    /// that `com.apple.` means a system application. It does not. System
    /// applications live in `/System/Applications`, on the sealed volume, which is
    /// not an application root and is never listed; Safari's entry in
    /// `/Applications` is a symbolic link, refused by its own rule. What the
    /// identifier test actually caught in `/Applications` on this Mac was Pages,
    /// Numbers, Keynote, iMovie, Developer and Xcode — App Store installs the user
    /// can delete from Launchpad — and a Shortcuts droplet the user had made.
    ///
    /// So the name is no longer the test; evidence that the user installed it is.
    /// An App Store receipt inside the bundle is that evidence. An Apple-named
    /// bundle without one stays refused: nothing here can say where it came from.
    ///
    /// Related files are the careful half. `exactIdentifier` and not `full`, because
    /// the prefix rule assumes a vendor owns everything beneath their name, and
    /// under `com.apple.` that vendor is the operating system. Shared group
    /// containers (`group.com.apple.iWork`, which Pages, Numbers and Keynote share)
    /// are preserved for every application already.
    ///
    /// A droplet is the application alone: all droplets carry one identifier, so
    /// anything matched by it belongs to each of them and to none.
    func uninstallScope(identifier: String?, applicationURL: URL) -> UninstallScope {
        guard let identifier else { return .applicationOnly }
        guard !protectedBundleIdentifiers.contains(identifier) else { return .refused }
        guard Self.isProtectedBundleIdentifier(identifier) else { return .full }
        if identifier == Self.shortcutsDropletIdentifier { return .applicationOnly }
        if identifier.hasPrefix(Self.macOSInstallerIdentifierPrefix) { return .applicationOnly }
        return Self.hasAppStoreReceipt(applicationURL) ? .exactIdentifier : .refused
    }

    static let shortcutsDropletIdentifier = "com.apple.shortcuts.droplet"

    /// `Install macOS Sonoma.app` is `com.apple.InstallAssistant.macOSSonoma`: about
    /// twelve gigabytes, and the first thing anyone opening a disk cleaner would
    /// clear. The receipt rule refused most of them. One fetched by Software Update,
    /// or by `softwareupdate --fetch-full-installer`, carries no App Store receipt,
    /// so it was a row the size of the scan that nothing here could remove.
    ///
    /// An installer is never part of the running system: it is a download that sits
    /// in `/Applications` until someone runs it, and the same download can be had
    /// again. The identifier says what it is, and the application roots — never
    /// `/System` — say where. It goes alone: what else answers to an Apple name is
    /// not knowable from here.
    ///
    /// None was on this Mac on 20 Sep 2026; the identifier is Apple's documented one.
    static let macOSInstallerIdentifierPrefix = "com.apple.InstallAssistant."

    /// The receipt the App Store writes into every bundle it installs.
    static func hasAppStoreReceipt(_ applicationURL: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: applicationURL.appendingPathComponent("Contents/_MASReceipt/receipt").path
        )
    }

    /// A web application's launcher, written by a Chromium browser: `app_mode_loader`
    /// and a plist naming the profile that owns it. Seen on this Mac as two 0-byte
    /// entries in `~/Applications/Chrome Apps.localized`. The browser manages these
    /// and writes them again; removing one uninstalls nothing, so it is not listed.
    static func isChromiumApplicationShim(_ bundle: Bundle) -> Bool {
        bundle.object(forInfoDictionaryKey: "CrAppModeShortcutID") != nil
    }

    /// An identifier the system may own. Not by itself a verdict on an application —
    /// see `uninstallScope` — but it is one for a leftover, which has no bundle to
    /// carry a receipt.
    static func isProtectedBundleIdentifier(_ identifier: String) -> Bool {
        let lowered = identifier.lowercased()
        let wrapped = "." + lowered + "."
        return lowered == "com.apple"
            || wrapped.contains(".com.apple.")
            || wrapped.contains(".developer.apple.")
            || wrapped.contains(".is.workflow.")
    }

    static func ownedBundleIdentifiers(
        in applicationURL: URL,
        primary: String,
        fileManager: FileManager,
        knownIdentifiers: Set<String>? = nil
    ) -> Set<String> {
        var result: Set<String> = [primary]
        for identifier in knownIdentifiers ?? allBundleIdentifiers(in: applicationURL, fileManager: fileManager)
        where identifier.hasPrefix(primary + ".") {
            result.insert(identifier)
        }
        return result
    }

    static func exclusiveBundleIdentifiers(
        candidates: Set<String>, selectedApplication: URL, applicationRoots: [URL],
        fileManager: FileManager = .default, ownership: [String: Set<String>]? = nil,
        checkCancellation: () throws -> Void
    ) throws -> Set<String> {
        try checkCancellation()
        guard !candidates.isEmpty else { return [] }
        let selectedPath = selectedApplication.resolvingSymlinksInPath().standardizedFileURL.path
        var ownedElsewhere = Set<String>()
        let applications = try ownership.map { $0.keys.map { URL(fileURLWithPath: $0) } }
            ?? installedApplications(in: applicationRoots, fileManager: fileManager, checkCancellation: checkCancellation)
        for application in applications {
            try checkCancellation()
            let path = application.resolvingSymlinksInPath().standardizedFileURL.path
            guard path != selectedPath, !path.hasPrefix(selectedPath + "/") else { continue }
            let identifiers = try ownership?[path] ?? allBundleIdentifiers(
                in: application, fileManager: fileManager, checkCancellation: checkCancellation
            )
            ownedElsewhere.formUnion(identifiers)
            if candidates.isSubset(of: ownedElsewhere) { return [] }
        }
        return candidates.subtracting(ownedElsewhere)
    }

    private static func applicationOwnership(in roots: [URL]) throws -> [String: Set<String>] {
        var ownership: [String: Set<String>] = [:]
        for application in try installedApplications(
            in: roots, fileManager: .default, checkCancellation: Task.checkCancellation
        ) {
            let path = application.resolvingSymlinksInPath().standardizedFileURL.path
            ownership[path] = try allBundleIdentifiers(
                in: application, fileManager: .default, checkCancellation: Task.checkCancellation
            )
        }
        return ownership
    }

    /// - Parameter exclusiveApplicationGroups: the app groups that no other application claims now.
    ///   A group container item without its group in this set stays on disk.
    static func removalIsStillSafe(
        _ item: AppUninstallPlan.Item,
        in plan: AppUninstallPlan,
        exclusiveBundleIdentifiers: Set<String>,
        exclusiveApplicationGroups: Set<String> = []
    ) -> Bool {
        guard plan.items.contains(where: { $0.id == item.id && $0 == item }) else { return false }
        if let currentIdentity = FileIdentity.of(item.url),
           currentIdentity != item.plannedIdentity {
            // The path now names a different filesystem object than the one shown
            // in review. A location is not an identity; leave the replacement.
            return false
        }
        if item.content == .application {
            return item.url == plan.applicationURL
                && Self.isInside(item.url, oneOf: plan.applicationRoots)
                && !Self.isSymbolicLink(item.url)
        }
        if let group = item.applicationGroup, !exclusiveApplicationGroups.contains(group) { return false }
        guard let owner = item.ownerBundleIdentifier, exclusiveBundleIdentifiers.contains(owner) else { return false }
        return isSafeLocation(item.url, roots: plan.allowedRelatedRoots, folders: plan.allowedRelatedFolders)
    }

    /// The checks for a shared group container that the user opted in to remove.
    ///
    /// The application must be gone, and the container must be the reviewed folder
    /// in a safe location. It must not hold database data, an excluded path, protected
    /// content, or an item that Moppo cannot read. Another application can claim the
    /// group, because the user accepted that risk after the warning.
    static func optedInRemovalIsStillSafe(
        _ item: AppUninstallPlan.Item, in plan: AppUninstallPlan
    ) async -> Bool {
        guard plan.optedInItems.contains(item),
              FileIdentity.isAbsent(plan.applicationURL),
              let identity = FileIdentity.of(item.url), identity == item.plannedIdentity,
              isSafeLocation(item.url, roots: plan.allowedRelatedRoots, folders: plan.allowedRelatedFolders),
              DatabaseStorage.location(overlapping: item.url, in: DatabaseStorage.locations(home: plan.home)) == nil
        else { return false }
        let context = ScanContext(
            measurer: AllocatedSizeMeasurer(followSymlinks: false),
            excludedPaths: plan.optInExcludedPaths, excludedPatterns: plan.optInExcludedPatterns
        )
        guard !context.isExcluded(item.url),
              let measurement = try? await context.measurer.measure(item.url)
        else { return false }
        return !measurement.containsProtectedPattern && measurement.unreadableCount == 0
    }

    /// True when `url` is in an allowed location, and it and its parents are not symbolic links.
    static func isSafeLocation(_ url: URL, roots: [URL], folders: [URL]) -> Bool {
        guard let root = relatedRoot(of: url, roots: roots, folders: folders), !isSymbolicLink(url) else {
            return false
        }
        return !hasSymbolicLinkInParents(of: url, through: root)
    }

    var allowedRelatedRoots: [URL] {
        [
            userLibrary,
            systemLibrary,
            home.appendingPathComponent(".config", isDirectory: true),
            home.appendingPathComponent(".cache", isDirectory: true),
            home.appendingPathComponent(".local/share", isDirectory: true),
        ] + [darwinCache, darwinTemp].compactMap { $0 }
    }

    var allowedRelatedFolders: [URL] {
        ApplicationDataFolders.foldersOutsideLibrary(home: home)
    }

    func candidateIsSafe(_ url: URL) -> Bool {
        Self.isSafeLocation(url, roots: allowedRelatedRoots, folders: allowedRelatedFolders)
    }

    /// The folder through which the symbolic link check runs, or nil when `url` is outside the allowed locations.
    /// A path in a root is allowed. A named folder is allowed as the complete folder or a path in it.
    /// Its parent is not an allowed location.
    static func relatedRoot(of url: URL, roots: [URL], folders: [URL]) -> URL? {
        if let root = roots.first(where: { isInside(url, root: $0) }) { return root }
        let path = url.standardizedFileURL.path
        return folders.first { $0.standardizedFileURL.path == path || isInside(url, root: $0) }?
            .deletingLastPathComponent()
    }

    static func installedApplications(
        in roots: [URL], fileManager: FileManager
    ) -> [URL] {
        (try? installedApplications(in: roots, fileManager: fileManager, checkCancellation: {})) ?? []
    }

    static func installedApplications(
        in roots: [URL], fileManager: FileManager,
        excluding isExcluded: (URL) -> Bool = { _ in false },
        requireCompleteInventory: Bool = false,
        checkCancellation: () throws -> Void
    ) throws -> [URL] {
        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin("installed_application_discovery", details: ["roots": roots.map(\.path).joined(separator: "\n")])
        defer { diagnostics?.end(span) }
        try checkCancellation()
        var result: [URL] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        for root in roots where fileManager.fileExists(atPath: root.path) {
            try checkCancellation()
            guard !isExcluded(root) else { continue }
            var readError: Error?
            guard let enumerator = fileManager.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles], errorHandler: { _, error in
                    readError = error
                    return !requireCompleteInventory
                }
            ) else {
                if requireCompleteInventory { throw CocoaError(.fileReadNoPermission) }
                continue
            }
            for case let url as URL in enumerator {
                diagnostics?.update(span, path: url.path)
                try checkCancellation()
                let values: URLResourceValues?
                if requireCompleteInventory { values = try url.resourceValues(forKeys: Set(keys)) }
                else { values = try? url.resourceValues(forKeys: Set(keys)) }
                // The enumerator does not follow symbolic links. Skipping their descendants can skip the next folder.
                if values?.isSymbolicLink == true { continue }
                if isExcluded(url) {
                    if values?.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                guard values?.isDirectory == true,
                      url.pathExtension.lowercased() == "app"
                else { continue }
                result.append(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
            if requireCompleteInventory, let readError { throw readError }
        }
        return result
    }

    static func allBundleIdentifiers(
        in applicationURL: URL, fileManager: FileManager
    ) -> Set<String> {
        (try? allBundleIdentifiers(in: applicationURL, fileManager: fileManager, checkCancellation: {})) ?? []
    }

    private static func allBundleIdentifiers(
        in applicationURL: URL, fileManager: FileManager, checkCancellation: () throws -> Void
    ) throws -> Set<String> {
        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin("application_bundle_identifiers", path: applicationURL.path)
        defer { diagnostics?.end(span) }
        try checkCancellation()
        var result = Set<String>()
        if let identifier = verifiedBundleIdentifier(Bundle(url: applicationURL)?.bundleIdentifier) {
            result.insert(identifier)
        }
        guard let enumerator = fileManager.enumerator(
            at: applicationURL, includingPropertiesForKeys: [],
            options: [.skipsHiddenFiles], errorHandler: nil
        ) else { return result }
        for case let url as URL in enumerator {
            diagnostics?.update(span, path: url.path)
            try checkCancellation()
            let extensionName = url.pathExtension.lowercased()
            guard ["app", "appex", "xpc", "plugin", "bundle"].contains(extensionName)
            else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values?.isDirectory == true, values?.isSymbolicLink != true else { continue }
            if let identifier = verifiedBundleIdentifier(Bundle(url: url)?.bundleIdentifier) {
                result.insert(identifier)
            }
            if extensionName == "app" { enumerator.skipDescendants() }
        }
        return result
    }

    private static func matchesByHostPreference(_ name: String, id: String) -> Bool {
        guard name.hasPrefix(id + "."), name.hasSuffix(".plist") else { return false }
        let suffix = String(name.dropFirst(id.count + 1).dropLast(".plist".count))
        return UUID(uuidString: suffix) != nil
    }

    static func installedBundleIdentifiers(
        in roots: [URL], fileManager: FileManager = .default
    ) -> Set<String> {
        (try? installedBundleIdentifiers(in: roots, fileManager: fileManager, checkCancellation: {})) ?? []
    }

    /// Stops scan ownership checks before they can return an incomplete owner set.
    static func installedBundleIdentifiers(
        in roots: [URL], fileManager: FileManager = .default, checkCancellation: () throws -> Void
    ) throws -> Set<String> {
        var result = Set<String>()
        for application in try installedApplications(
            in: roots, fileManager: fileManager, checkCancellation: checkCancellation
        ) {
            result.formUnion(try allBundleIdentifiers(
                in: application, fileManager: fileManager, checkCancellation: checkCancellation
            ))
        }
        return result
    }

    /// Walks each application bundle at most one time for each scan.
    static func installedBundleIdentifiers(
        in roots: [URL], fileManager: FileManager = .default, sharing walks: ApplicationBundleWalks
    ) async throws -> Set<String> {
        let applications = try installedApplications(
            in: roots, fileManager: fileManager, checkCancellation: Task.checkCancellation
        )
        return try await walks.identifiers(in: applications) {
            try allBundleIdentifiers(in: $0, fileManager: fileManager, checkCancellation: Task.checkCancellation)
        }
    }

    static func ownerIsInstalled(
        _ identifier: String, installedBundleIdentifiers: Set<String>
    ) -> Bool {
        installedBundleIdentifiers.contains { installed in
            identifier == installed
                || identifier.hasPrefix(installed + ".")
                || installed.hasPrefix(identifier + ".")
        }
    }

    static func directoryNames(_ url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }

    static func isInside(_ url: URL, oneOf roots: [URL]) -> Bool {
        roots.contains { isInside(url, root: $0) }
    }

    static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path.hasPrefix(rootPath + "/")
    }

    static func isSymbolicLink(_ url: URL) -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { return false }
        return (information.st_mode & S_IFMT) == S_IFLNK
    }

    static func hasSymbolicLinkInParents(of url: URL, through root: URL) -> Bool {
        var current = url.deletingLastPathComponent().standardizedFileURL
        let root = root.standardizedFileURL
        while current.path.count >= root.path.count {
            if isSymbolicLink(current) { return true }
            if current.path == root.path { return false }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return true }
            current = parent
        }
        return true
    }

    private static func darwinUserDirectory(_ name: Int32) -> URL? {
        let length = confstr(name, nil, 0)
        guard length > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard confstr(name, &buffer, length) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self), isDirectory: true)
            .standardizedFileURL
    }

    static func deduplicated(
        _ paths: [AppUninstallPlan.PreservedPath]
    ) -> [AppUninstallPlan.PreservedPath] {
        var seen = Set<String>()
        return paths.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    /// Measures a kept path for the review. An excluded path is not measured.
    static func preservedPath(
        _ url: URL, reason: AppUninstallPlan.PreservedPath.Reason, context: ScanContext
    ) async throws -> AppUninstallPlan.PreservedPath {
        guard reason != .excluded, !context.isExcluded(url), !isSymbolicLink(url) else {
            return .init(url: url, reason: reason)
        }
        return .init(url: url, reason: reason, measurement: try await context.measurer.measure(url))
    }
}
