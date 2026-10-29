import Foundation

/// The Scanner categories, in their display order.
public enum CategoryID: String, Sendable, CaseIterable, Identifiable {
    case documentsAndFiles
    case applications
    case applicationLeftovers
    case aiTools
    case hiddenSystemData
    case systemCaches
    case packageManagers
    case xcode
    case docker

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .documentsAndFiles: "Documents & Files"
        case .applications:      "Applications"
        case .applicationLeftovers: "Application Leftovers"
        case .aiTools:           "AI Tools"
        case .hiddenSystemData:  "Hidden & System Data"
        case .systemCaches:      "System Caches & Logs"
        case .packageManagers:   "Package Manager Caches"
        case .xcode:             "Xcode & iOS Dev"
        case .docker:            "Docker"
        }
    }

    public var subtitle: String {
        switch self {
        case .documentsAndFiles:
            "Largest folders in Documents, Downloads, Desktop, Movies, Pictures, Music"
        case .applications:
            "Apps in /Applications and ~/Applications. Least recently used first."
        case .applicationLeftovers:
            "Files with no installed application owner"
        case .aiTools:
            "Sessions, worktrees, downloaded runtimes, virtual machines, and local models"
        case .hiddenSystemData:
            "iOS backups, Mail downloads, hidden folders, large disk images"
        case .systemCaches:
            "~/Library/Caches, ~/Library/Logs, ~/.cache, Apple's own apps"
        case .packageManagers:
            "npm, pnpm, pip, Homebrew, Cargo, CocoaPods, Gradle and more"
        case .xcode:
            "DerivedData, Device Support, Simulator caches"
        case .docker:
            "Docker images, containers and volumes"
        }
    }

    /// Rendered in monospace when the subtitle is a path list.
    public var subtitleIsPath: Bool { self == .systemCaches }

    public var color: ColorToken {
        switch self {
        case .documentsAndFiles: .orange
        case .applications:      .pink
        case .applicationLeftovers: .teal
        case .aiTools:           .indigo
        case .hiddenSystemData:  .purple
        case .systemCaches:      .accent
        case .packageManagers:   .green
        case .xcode:             .yellow
        case .docker:            .gray
        }
    }

    /// Removing it costs nothing: what is here regenerates on demand. This value
    /// drives the Dashboard's "Safe to Remove" total and the green badge on a row.
    ///
    /// Application leftovers were in this list until 20 Sep 2026, on the reasoning
    /// that a file with no installed owner is safe. It is safe for the *system* and
    /// not free for the *user*: a leftover is a removed application's settings, its
    /// saved state, sometimes its licence, and nothing regenerates those. Whether
    /// they matter depends on whether that application is ever installed again,
    /// which only the user knows. So leftovers need review, like everything else
    /// whose removal is a decision, and "safe to remove" keeps one meaning. They had
    /// been counted safe and deliberately never ticked, which was the two meanings
    /// showing.
    public var isSafe: Bool {
        switch self {
        case .systemCaches, .packageManagers, .xcode: true
        case .documentsAndFiles, .applications, .applicationLeftovers,
             .aiTools, .hiddenSystemData, .docker: false
        }
    }

    /// Removal moves to the Trash rather than unlinking. Applications always do,
    /// regardless of the global "Always move to Trash" setting.
    public var alwaysMovesToTrash: Bool {
        self == .applications || self == .applicationLeftovers
    }
}

/// Why a category has nothing to offer. The reason is user-facing copy: the design
/// requires Docker's row to say how to fix it, which the predecessor's bare
/// "Docker is not running" did not.
public enum CategoryAvailability: Sendable, Equatable {
    case available
    /// Measured successfully and found nothing.
    case empty
    /// The required application is absent. Cleanup hides this category.
    case notInstalled
    case unavailable(reason: String)

    public var isActionable: Bool { self == .available }
}

public struct ScanCategoryResult: Sendable, Equatable, Identifiable {
    public let categoryID: CategoryID
    public var totalBytes: Int64
    public var entries: [FileEntry]
    public var availability: CategoryAvailability
    /// Entries this scanner could not read, surfaced rather than swallowed.
    public var unreadableCount: Int
    /// The reviewed identities behind the Application Leftovers rows.
    public var applicationLeftoverPlan: OrphanedAppLeftoverPlan?
    /// Storage roots that this category owns, including excluded or unreadable roots.
    public var claimedStoragePaths: [String] = []

    public var id: String { categoryID.rawValue }

    /// The space used by installed app bundles. The cleanup total can be lower when
    /// an app is running, or higher when related files are removable with the app.
    public var applicationInstalledBytes: Int64? {
        guard categoryID == .applications else { return nil }
        return entries.reduce(0) { $0 + $1.allocatedBytes }
    }

    /// This category's contribution to "Safe to Remove". It counts regenerable
    /// rows, verified application-leftover groups, and the regenerable children of
    /// rows that are not themselves safe. A safe cache category can hold data that
    /// does not regenerate, such as an `.xcarchive`. Therefore, each ordinary row
    /// must pass the regenerable check.
    ///
    /// The children matter because of applications. Chrome's caches are children of
    /// the Chrome row, the Applications category is not safe, and every row in it is
    /// an app bundle — so before this the tile could not see a single one of them,
    /// though the Scanner badged them `regenerable` one screen away. On the author's
    /// Mac that was 1.37 GB in Chrome alone.
    public var safeToRemoveBytes: Int64 {
        tileRows(safeToRemove: true).reduce(0) { $0 + $1.displayBytes }
    }

    /// The rows behind one tile — and the definition of what that tile counts, since
    /// both totals are sums over exactly these.
    ///
    /// It lives here, beside the figures, because it used to live in the app while
    /// the figures lived in Core. The two were written to agree and did, until a
    /// build took one of them and not the other: the tile then read 10.24 GB over a
    /// list of 13 rows worth 1.61 GB. Neither number was wrong for the code that
    /// produced it, which is the whole problem with keeping one claim in two places.
    ///
    /// A row that is not safe can still carry children that are. An application is
    /// the case this exists for: Chrome is not safe to remove and its caches are, so
    /// the caches come back as rows of their own and the row this returns for "needs
    /// review" is Chrome *without* them. Trimming rather than repeating is what keeps
    /// the two lists from claiming the same bytes twice.
    ///
    /// The Scanner does not use this. There an application keeps every child it has,
    /// because that view is about one application rather than about a total.
    public func tileRows(safeToRemove wantSafe: Bool) -> [FileEntry] {
        entries.flatMap { entry -> [FileEntry] in
            if countsAsSafe(entry) { return wantSafe ? [entry] : [] }
            // A leftover group or a model is one thing, removed through its own row —
            // a leftover's route checks the owner and each file's identity again.
            // A cache lifted out of it would be removed the ordinary way, unchecked.
            if entry.removalAction != nil || entry.removesAsUnit { return wantSafe ? [] : [entry] }

            let safeChildren = entry.children.filter(Self.isSafeChild)
            if wantSafe {
                return safeChildren.map { child in
                    var child = child
                    if child.aiStorageSection == nil, let section = entry.aiStorageSection {
                        child.aiStorageSection = .init(owner: section.owner, title: child.displayName,
                            summary: FileEntryPresentation(entry: child).summary)
                    }
                    return child
                }
            }
            guard !safeChildren.isEmpty else { return [entry] }

            var remainder = entry
            remainder.children = entry.children.filter { !Self.isSafeChild($0) }
            // A locked row whose only removable content was those children is worth
            // nothing here. It counts zero towards the tile, so the list the tile
            // opens should not show it either.
            return remainder.displayBytes > 0 ? [remainder] : []
        }
    }

    /// Keeps category information while filtering rows by removal safety.
    /// Safe to Remove uses the safe rows. The CLI also reports the remaining rows.
    public func filtered(safeToRemove wantSafe: Bool) -> ScanCategoryResult {
        var copy = self
        copy.entries = tileRows(safeToRemove: wantSafe)
        copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
        copy.holdsOnlySafeRows = wantSafe
        if copy.entries.isEmpty, availability == .available { copy.availability = .empty }
        return copy
    }

    /// Set on the copy `filtered(safeToRemove: true)` returns. Its rows are safe by
    /// construction, and one of them can be a cache lifted out of an application,
    /// whose category is not a safe one — so the category cannot answer for it.
    public private(set) var holdsOnlySafeRows = false

    /// Whether a top-level row of this category is counted under Safe to remove,
    /// which is what its green badge says. A child's badge asks
    /// `FileEntry.regeneratesSafely`.
    public func isCountedSafe(_ entry: FileEntry) -> Bool {
        holdsOnlySafeRows || countsAsSafe(entry)
    }

    /// A child the parent's own row does not speak for — see
    /// `FileEntry.regeneratesSafely`, which the Scanner's badge reads too.
    private static func isSafeChild(_ child: FileEntry) -> Bool {
        child.regeneratesSafely
    }

    /// Checks whether the row itself is safe to remove.
    /// Running applications keep their rows outside Safe to Remove and automatic selection.
    private func countsAsSafe(_ entry: FileEntry) -> Bool {
        guard entry.inUseBy == nil else { return false }
        guard entry.children.filter(\.isGitWorktree).allSatisfy(\.regeneratesSafely) else { return false }
        if entry.isGitWorktree { return entry.regeneratesSafely }
        return categoryID.isSafe && entry.isRegenerable
    }

    /// Storage outside Safe to Remove, retained for the CLI summary.
    /// Safe rows and these remaining rows count each byte once.
    /// Categories without rows retain their aggregate total.
    public var needsReviewBytes: Int64 {
        // A category with no rows keeps its own total: that is a scanner reporting an
        // aggregate it never broke into rows, Docker being the one that does it.
        guard !entries.isEmpty else { return categoryID.isSafe ? 0 : totalBytes }
        return tileRows(safeToRemove: false).reduce(0) { $0 + $1.displayBytes }
    }

    public init(
        categoryID: CategoryID,
        totalBytes: Int64 = 0,
        entries: [FileEntry] = [],
        availability: CategoryAvailability = .available,
        unreadableCount: Int = 0,
        applicationLeftoverPlan: OrphanedAppLeftoverPlan? = nil
    ) {
        self.categoryID = categoryID
        self.totalBytes = totalBytes
        self.entries = entries
        self.availability = availability
        self.unreadableCount = unreadableCount
        self.applicationLeftoverPlan = applicationLeftoverPlan
    }

    /// Drops entries too small to be worth a row, and recomputes the total.
    ///
    /// A cleaner offering to reclaim 200 KB wastes a line of the user's attention on
    /// something that will never matter. Removing them also keeps the byte formatter
    /// away from its degenerate case.
    ///
    /// This filter applies only to entry-backed categories. Docker reports totals
    /// from its own accounting, so the filter leaves Docker rows intact.
    public func filteringNoise(below floor: Int64) -> Self {
        // Docker's rows are manual-removal aggregates: `reclaimableBytes` is zero
        // by definition, so recomputing the total from it would erase the `system
        // df` figure the category exists to show.
        guard categoryID != .docker,
              categoryID != .applicationLeftovers,
              !entries.isEmpty
        else { return self }
        var copy = self
        copy.entries = entries.filter { entry in
            if let command = entry.toolCommand, case .simulatorRuntimeAbsent = command.expectedResult { return true }
            if categoryID == .xcode, entry.protectionReason == .inventory { return true }
            return entry.totalBytesIncludingChildren >= floor || entry.worktreeCount > 0
        }
        copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
        // Everything it found was noise — that is "nothing worth cleaning", not a
        // category with an empty table.
        if copy.entries.isEmpty, availability == .available {
            copy.availability = .empty
        }
        return copy
    }

    /// A category that measured zero renders disabled, with no disclosure triangle.
    public static func empty(_ id: CategoryID) -> Self {
        ScanCategoryResult(categoryID: id, availability: .empty)
    }

    public static func unavailable(_ id: CategoryID, reason: String) -> Self {
        ScanCategoryResult(categoryID: id, availability: .unavailable(reason: reason))
    }
}
