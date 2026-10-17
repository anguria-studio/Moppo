import Foundation

/// Progress for the toolbar's `Measuring {n}%` readout.
public struct ScanProgress: Sendable, Equatable {
    /// 0...100, weighted by completed categories.
    public var percent: Int
    public var completedCategories: Int
    public var totalCategories: Int
    public var phase: String? = nil
}

/// Everything a finished scan produced.
public struct ScanResults: Sendable, Equatable {
    public var categories: [ScanCategoryResult]
    public var startedAt: Date
    public var finishedAt: Date

    /// Public so views can build sample results for SwiftUI previews without
    /// running a real scan against the user's disk.
    public init(categories: [ScanCategoryResult], startedAt: Date, finishedAt: Date) {
        self.categories = categories
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var totalBytes: Int64 {
        categories.reduce(0) { $0 + $1.totalBytes }
    }

    /// The Dashboard's "Safe to Remove" tile. It includes cache data that
    /// regenerates and application leftovers that have no installed owner.
    ///
    /// Judged per entry, not per category. A safe category can still hold the one
    /// thing that does not come back — an `.xcarchive` with a shipped build's only
    /// dSYMs — and the tile's promise, "removal loses nothing", has to hold for
    /// every row it counts.
    public var safeToRemoveBytes: Int64 {
        categories.reduce(0) { $0 + $1.safeToRemoveBytes }
    }

    /// The "Needs review" tile: large files, unused apps, and anything in a safe
    /// category that does not regenerate — the user decides.
    public var needsReviewBytes: Int64 {
        categories.reduce(0) { $0 + $1.needsReviewBytes }
    }

    /// Categories with something to show, in the design's fixed order.
    public var actionableCategories: [ScanCategoryResult] {
        categories.filter { $0.availability.isActionable && $0.totalBytes > 0 }
    }
}

/// Runs the category scanners.
///
/// An actor because re-entrancy has to be impossible: the design triggers a scan
/// from three places (toolbar button, Dashboard status bar, Scan menu) and requires
/// that "a scan already running ignores further triggers".
public actor ScanCoordinator {

    /// Relative cost, so the progress bar advances at a believable rate. Applications
    /// is by far the slowest — it measures every bundle plus its scattered leftovers.
    private static let weights: [CategoryID: Double] = [
        .documentsAndFiles: 3.0,
        .applications: 4.0,
        .applicationLeftovers: 1.0,
        .aiTools: 2.0,
        .hiddenSystemData: 2.0,
        .systemCaches: 1.0,
        .packageManagers: 1.0,
        .xcode: 1.0,
        .docker: 0.5
    ]

    /// Hides small ordinary entries. Worktree rows remain available for review.
    private static let entryNoiseFloor: Int64 = 1024 * 1024

    private let scanners: [any CategoryScanner]
    private var runningTask: Task<ScanResults, Error>?

    public init(scanners: [any CategoryScanner]) {
        self.scanners = scanners
    }

    /// Standard categories in display order. Scanners run concurrently.
    public static func standard() -> ScanCoordinator {
        ScanCoordinator(scanners: [
            DocumentsFilesScanner(),
            ApplicationsScanner(),
            ApplicationLeftoversScanner(),
            AIToolsScanner(),
            HiddenDataScanner(),
            SystemCachesScanner(),
            PackageManagerScanner(),
            XcodeScanner(),
            DockerScanner()
        ])
    }

    public var isScanning: Bool { runningTask != nil }

    /// Starts a scan, or returns the one already in flight.
    ///
    /// - Parameters:
    ///   - enabled: categories switched on in Preferences. A disabled category is
    ///     never measured — the design is explicit that "off" means *not measured*,
    ///     not *deleted*.
    ///   - onProgress: weighted 0...100 for the toolbar.
    ///   - onCategory: fired as each category finishes so its row fills in
    ///     incrementally rather than everything appearing at the end.
    ///   - onCategoryTiming: reports elapsed time, including failed or cancelled categories.
    ///     This callback can run concurrently.
    public func scan(
        enabled: Set<CategoryID>? = nil,
        context: ScanContext = ScanContext(),
        onProgress: (@Sendable (ScanProgress) -> Void)? = nil,
        onCategory: (@Sendable (ScanCategoryResult) -> Void)? = nil,
        onCategoryTiming: (@Sendable (CategoryID, Duration) -> Void)? = nil
    ) async throws -> ScanResults {
        try Task.checkCancellation()
        if let runningTask { return try await runningTask.value }

        let active = scanners.filter { enabled?.contains($0.id) ?? true }
        ScanDiagnostics.current?.record("categories_enabled", details: ["categories": active.map { $0.id.rawValue }.joined(separator: ",")])
        let task = Task { [active] in
            try await Self.run(
                active,
                context: context,
                onProgress: onProgress,
                onCategory: onCategory,
                onCategoryTiming: onCategoryTiming
            )
        }
        runningTask = task
        defer { runningTask = nil }
        return try await withTaskCancellationHandler {
            let results = try await task.value
            try Task.checkCancellation()
            return results
        } onCancel: {
            task.cancel()
        }
    }

    /// Requests cancellation. The scan stays active until its workers finish.
    public func cancel() {
        runningTask?.cancel()
    }

    private static func run(
        _ scanners: [any CategoryScanner],
        context: ScanContext,
        onProgress: (@Sendable (ScanProgress) -> Void)?,
        onCategory: (@Sendable (ScanCategoryResult) -> Void)?,
        onCategoryTiming: (@Sendable (CategoryID, Duration) -> Void)?
    ) async throws -> ScanResults {
        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin("scan_categories")
        var diagnosticOutcome = "failed"
        defer { diagnostics?.end(span, outcome: Task.isCancelled ? "cancelled" : diagnosticOutcome) }
        let startedAt = Date()
        let totalWeight = scanners.reduce(0.0) { $0 + (weights[$1.id] ?? 1.0) }
        let reservation = CloudWorkerReservation()
        defer { reservation.restore() }
        var scanContext = context
        scanContext.measurer.cloudWorkerReservation = reservation
        let context = scanContext
        let tracker = ProgressTracker(totalWeight: totalWeight, categories: scanners.map(\.id),
                                      reservation: reservation, diagnostics: diagnostics, onProgress: onProgress)

        var results: [ScanCategoryResult] = []

        try await withThrowingTaskGroup(of: ScanCategoryResult.self) { group in
            for scanner in scanners {
                group.addTask {
                    let categoryDiagnostics = diagnostics?.forCategory(scanner.id.rawValue)
                    return try await ScanDiagnostics.$current.withValue(categoryDiagnostics) {
                        let started = ContinuousClock.now
                        let categorySpan = categoryDiagnostics?.begin("category")
                        var outcome = "failed"
                        defer {
                            onCategoryTiming?(scanner.id, started.duration(to: .now))
                            categoryDiagnostics?.end(categorySpan, outcome: outcome)
                        }
                        do {
                            var categoryContext = context
                            categoryContext.onPhase = { phase in
                                categoryDiagnostics?.record("scan_phase", details: ["phase": phase])
                                tracker.setPhase(phase, for: scanner.id)
                            }
                            let result = try await scanner.scan(context: categoryContext)
                            outcome = "completed"
                            categoryDiagnostics?.update(categorySpan, details: ["entries": "\(result.entries.count)",
                                "total_bytes": "\(result.totalBytes)", "unreadable_count": "\(result.unreadableCount)",
                                "availability": "\(result.availability)"])
                            return result
                        } catch is CancellationError {
                            outcome = "cancelled"
                            throw CancellationError()
                        } catch {
                            categoryDiagnostics?.update(categorySpan, details: ["error": "\(error)"])
                            // One category failure must not lose the whole scan. The row
                            // reports that category as unavailable and gives the reason.
                            return .unavailable(scanner.id, reason: Self.describe(error))
                        }
                    }
                }
            }

            for try await raw in group {
                // Apply this centrally so all scanners share one definition of
                // "too small to bother the user with".
                let result = raw.filteringNoise(below: Self.entryNoiseFloor)
                results.append(result)
                onCategory?(result)
                let weight = weights[result.categoryID] ?? 1.0
                tracker.advance(category: result.categoryID, by: weight)
            }
        }

        // An exact application-leftover group owns its paths. Remove each
        // overlapping generic row before the user can select the same path through
        // a cleanup route that does not repeat the owner and identity checks. If a
        // generic row contains a leftover path, remove the full row. Keeping that
        // parent would also remove the protected child when cleanup removes it.
        let finalization = diagnostics?.begin("result_finalization")
        defer { diagnostics?.end(finalization) }
        results = removingApplicationLeftoverOverlaps(from: results)
        results = removingAIToolOverlaps(from: results)
        results = removingInstalledApplicationOverlaps(from: results)

        // Present in the design's fixed order, not completion order.
        let order = CategoryID.allCases
        results.sort {
            (order.firstIndex(of: $0.categoryID) ?? 0) < (order.firstIndex(of: $1.categoryID) ?? 0)
        }

        for result in results {
            let category = diagnostics?.forCategory(result.categoryID.rawValue)
            category?.record("category_result_rows", details: [
                "entries": "\(result.entries.count)",
                "worktrees": "\(result.entries.reduce(0) { $0 + $1.worktreeCount })"
            ])
            for entry in result.entries {
                for row in [entry] + entry.children where row.isGitWorktree {
                    category?.record("worktree_visible_row", details: [
                        "path": row.url.path, "parent": entry.url.path,
                        "allocated_bytes": "\(row.allocatedBytes)",
                        "review_status": row.gitWorktreeReview?.statusLabel ?? "Unknown"
                    ])
                }
            }
        }
        diagnosticOutcome = "completed"
        return ScanResults(categories: results, startedAt: startedAt, finishedAt: Date())
    }

    /// AI storage owns its paths unless an application-leftover review owns them.
    static func removingAIToolOverlaps(from results: [ScanCategoryResult]) -> [ScanCategoryResult] {
        let claimed = results.first { $0.categoryID == .aiTools }?.claimedStoragePaths ?? []
        guard !claimed.isEmpty else { return results }
        func overlaps(_ entry: FileEntry) -> Bool {
            claimed.contains { ApplicationsScanner.overlaps(entry.url.standardizedFileURL.path, $0) }
        }
        return results.map { result in
            guard result.categoryID != .aiTools,
                  result.categoryID != .applicationLeftovers,
                  result.entries.contains(where: { overlaps($0) || $0.children.contains(where: overlaps) })
            else { return result }
            var copy = result
            copy.entries = result.entries.compactMap { original in
                if original.kind != .appBundle && original.removalAction == nil && overlaps(original) { return nil }
                var entry = original
                entry.children.removeAll(where: overlaps)
                if entry.removalAction != nil {
                    guard let first = entry.children.first else { return nil }
                    entry.url = first.url
                    entry.childCount = entry.children.count
                }
                return entry
            }
            copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
            if copy.entries.isEmpty, copy.availability == .available { copy.availability = .empty }
            return copy
        }
    }

    static func removingApplicationLeftoverOverlaps(
        from results: [ScanCategoryResult]
    ) -> [ScanCategoryResult] {
        let leftoverPaths = results
            .first(where: { $0.categoryID == .applicationLeftovers })?
            .entries
            .flatMap(\.children)
            .map { $0.url.standardizedFileURL.path } ?? []
        guard !leftoverPaths.isEmpty else { return results }

        func overlapsLeftover(_ entry: FileEntry) -> Bool {
            let path = entry.url.standardizedFileURL.path
            return leftoverPaths.contains { leftover in
                path == leftover
                    || path.hasPrefix(leftover + "/")
                    || leftover.hasPrefix(path + "/")
            }
        }

        return results.map { result in
            guard result.categoryID != .applicationLeftovers,
                  !result.entries.isEmpty
            else { return result }

            var copy = result
            copy.entries = result.entries.compactMap { original in
                guard !overlapsLeftover(original) else { return nil }
                var entry = original
                entry.children.removeAll(where: overlapsLeftover)
                return entry
            }
            copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
            if copy.entries.isEmpty, copy.availability == .available {
                copy.availability = .empty
            }
            return copy
        }
    }

    /// An installed application's row owns the caches listed under it.
    ///
    /// `~/Library/Caches/<bundle id>` is a child of its application's row and also
    /// an immediate child of `~/Library/Caches`, which System Caches lists whole.
    /// Both categories offered it, and both halves count towards Safe to remove: on
    /// this Mac on 19 Sep 2026 Spotify's 199.3 MB cache and Surfshark's were each
    /// promised twice. `moppo-cli scan` said "categories are disjoint" throughout,
    /// because it compared rows and never looked at children.
    ///
    /// The application keeps the path and the generic row goes, for two reasons.
    /// Children are what is removed alongside the application, so the uninstaller's
    /// list would otherwise lose a folder that is plainly the application's. And the
    /// application's row knows its running owner by bundle path, which is ground
    /// truth; System Caches can only guess an owner from a folder name.
    ///
    /// Only a regenerable, unlocked child claims anything. A container or support
    /// folder is user data and locked, and a generic row inside one — Mail Downloads
    /// inside Mail's container — is the removable part of it, not a duplicate.
    static func removingInstalledApplicationOverlaps(
        from results: [ScanCategoryResult]
    ) -> [ScanCategoryResult] {
        let claimed = results
            .first(where: { $0.categoryID == .applications })?
            .entries
            .flatMap(\.children)
            .filter { $0.isRegenerable && !$0.isRemovalLocked }
            .map { $0.url.standardizedFileURL.path } ?? []
        guard !claimed.isEmpty else { return results }

        func isClaimed(_ entry: FileEntry) -> Bool {
            let path = entry.url.standardizedFileURL.path
            return claimed.contains { path == $0 || path.hasPrefix($0 + "/") }
        }

        return results.map { result in
            guard result.categoryID != .applications,
                  result.categoryID != .applicationLeftovers,
                  result.entries.contains(where: isClaimed)
            else { return result }

            var copy = result
            copy.entries.removeAll(where: isClaimed)
            copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
            if copy.entries.isEmpty, copy.availability == .available {
                copy.availability = .empty
            }
            return copy
        }
    }

    private static func describe(_ error: Error) -> String {
        if let processError = error as? ProcessError {
            switch processError {
            case .executableMissing(let path):
                return "Required tool not found at \(path)."
            case .timedOut:
                return "Timed out while measuring. Try again."
            case .failed:
                return "Could not be measured."
            }
        }
        return "Could not be measured."
    }
}

/// Serializes category completion and phase updates for the progress display.
private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalWeight: Double
    private let totalCategories: Int
    private let reservation: CloudWorkerReservation
    private let diagnostics: ScanDiagnostics.Context?
    private let onProgress: (@Sendable (ScanProgress) -> Void)?
    private var remaining: Set<CategoryID>
    private var phases: [CategoryID: String] = [:]
    private var completedWeight = 0.0
    private var previousProgress: ScanProgress?
    private var releasedCloudWorkers = false

    init(totalWeight: Double, categories: [CategoryID], reservation: CloudWorkerReservation,
         diagnostics: ScanDiagnostics.Context?, onProgress: (@Sendable (ScanProgress) -> Void)?) {
        self.totalWeight = max(totalWeight, 0.001)
        self.totalCategories = categories.count
        self.remaining = Set(categories)
        self.reservation = reservation
        self.diagnostics = diagnostics
        self.onProgress = onProgress
        releaseCloudWorkersIfNeeded()
    }

    func advance(category: CategoryID, by weight: Double) {
        lock.lock()
        defer { lock.unlock() }
        remaining.remove(category)
        completedWeight += weight
        releaseCloudWorkersIfNeeded()
        report()
    }

    func setPhase(_ phase: String, for category: CategoryID) {
        lock.lock()
        defer { lock.unlock() }
        guard remaining.contains(category) else { return }
        phases[category] = phase
        report()
    }

    private func releaseCloudWorkersIfNeeded() {
        guard !releasedCloudWorkers, remaining == [.hiddenSystemData] else { return }
        releasedCloudWorkers = true
        reservation.release()
        diagnostics?.record("cloud_workers_released", details: ["reason": "other_categories_finished"])
    }

    private func report() {
        let category = remaining.count == 1 ? remaining.first : nil
        let progress = ScanProgress(
            percent: min(100, Int((completedWeight / totalWeight) * 100)),
            completedCategories: totalCategories - remaining.count,
            totalCategories: totalCategories,
            phase: category.map { phases[$0] ?? "Scanning \($0.displayName)" }
        )
        guard progress != previousProgress else { return }
        previousProgress = progress
        diagnostics?.progress(progress)
        onProgress?(progress)
    }
}
