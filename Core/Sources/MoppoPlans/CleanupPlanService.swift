import Foundation
import MoppoCore

public enum PlanValidationError: String, Error, Sendable {
    case invalidSelection = "invalid_selection"
    case scanChanged = "scan_changed"
    case evidenceUnavailable = "evidence_unavailable"
    case exclusionsChanged = "exclusions_changed"
    case categoryDisabled = "category_disabled"
    case unknownItem = "unknown_item"
    case protectedItem = "protected_item"
    case excludedItem = "excluded_item"
    case overlappingItems = "overlapping_items"
    case missingItem = "missing_item"
    case changedTarget = "changed_target"
    case unsupportedTarget = "unsupported_target"
    case incompleteScan = "incomplete_scan"
    case planChanged = "plan_changed"
}

/// A review is an immutable snapshot. It does not change application selection.
public struct PlanReview: Sendable {
    public let plan: CleanupPlan
    public let revision: String
    public let items: [ScanReport.Item]
    public let scanAllocatedBytes: Int64?
    public let entries: [FileEntry]
    public let expectedIdentities: [FileEntry.ID: String]
    /// Each selected item and its checked children, in the order of `items`.
    let targets: [[ScanReport.Item]]
    let exclusionsRevision: String
    /// Allocation and shared storage do not establish how much space removal will free.
    public var verifiedRecoverableBytes: Int64? { nil }
    /// Items that have no Put Back recovery. Each one needs separate confirmation.
    public var permanentItemIds: Set<String> { Set(items.filter { $0.recovery == "permanent" }.map(\.id)) }
}

/// Shared by terminal and application clients. No method removes cleanup targets.
public struct CleanupPlanService: Sendable {
    public typealias Configuration = @Sendable () throws -> ScanConfiguration
    public typealias Scanner = @Sendable (ScanConfiguration) async throws -> ScanResults
    public let scans: ScanStore
    public let plans: PlanStore
    private let configuration: Configuration
    private let scanner: Scanner
    private let failure = FailedItem()

    /// The selected item that failed the most recent validation, or nil when no single item failed.
    /// Clients use it to name the item in an error. It does not change the thrown error.
    public var lastFailedItemId: String? { failure.id }

    public init(scans: ScanStore = ScanStore(), plans: PlanStore = PlanStore(),
                configuration: @escaping Configuration, scanner: @escaping Scanner) {
        self.scans = scans
        self.plans = plans
        self.configuration = configuration
        self.scanner = scanner
    }

    public func create(scanId: String, scanRevision: String, itemIds: [String], now: Date = Date()) async throws -> PlanReview {
        guard RecordDigest.isValid(scanRevision), !itemIds.isEmpty, itemIds.count <= 500,
              Set(itemIds).count == itemIds.count,
              itemIds.allSatisfy({ ScanStore.validId($0, prefix: "item_") })
        else { throw PlanValidationError.invalidSelection }
        let (report, revision) = try scans.loadWithRevision(scanId, now: now)
        guard revision == scanRevision else { throw PlanValidationError.scanChanged }
        let plan = CleanupPlan(scan: report, revision: scanRevision, itemIds: itemIds, now: now)
        let review = try await validate(plan, now: now)
        try Task.checkCancellation()
        try plans.save(plan, now: now)
        return review
    }

    public func inspect(_ planId: String, now: Date = Date()) async throws -> PlanReview {
        let plan = try plans.load(planId, now: now)
        let review = try await validate(plan, now: now)
        try unchanged(review, now: now)
        return review
    }

    /// Run again after confirmation and immediately before the owning removal service.
    /// The removal service must retain its identity, ownership, and eligibility checks.
    public func revalidate(_ review: PlanReview, now: Date = Date()) async throws -> PlanReview {
        try unchanged(review, now: now)
        let current = try await validate(review.plan, now: now)
        try unchanged(review, now: now)
        return current
    }

    /// Checks one remaining item after earlier items have finished. Use the result of `revalidate`.
    /// This check does not scan again. It confirms the plan, settings, and target identities.
    public func recheck(_ review: PlanReview, itemId: String, now: Date = Date()) throws {
        guard let index = review.items.firstIndex(where: { $0.id == itemId }) else { throw PlanValidationError.unknownItem }
        try unchanged(review, now: now)
        let settings = try configuration()
        guard try settings.exclusionsRevision == review.exclusionsRevision else { throw PlanValidationError.exclusionsChanged }
        guard let category = CategoryID(rawValue: review.items[index].category),
              settings.enabledCategories.contains(category) else { throw PlanValidationError.categoryDisabled }
        let context = ScanContext(excludedPaths: settings.excludedPaths, excludedPatterns: settings.excludedPatterns)
        for target in review.targets[index] {
            guard let path = target.path, let evidence = target.evidence else { throw PlanValidationError.unsupportedTarget }
            let url = URL(fileURLWithPath: path)
            guard !context.isExcluded(url), !context.isExcluded(url.resolvingSymlinksInPath()) else {
                throw PlanValidationError.excludedItem
            }
            guard evidence.matchesFile(at: url) else { throw PlanValidationError.changedTarget }
        }
    }

    private func unchanged(_ review: PlanReview, now: Date) throws {
        let current = try plans.load(review.plan.planId, now: now)
        guard try RecordDigest.of(current) == review.revision else { throw PlanValidationError.planChanged }
    }

    private func validate(_ plan: CleanupPlan, now: Date) async throws -> PlanReview {
        let validationStarted = Date()
        failure.id = nil
        try Task.checkCancellation()
        let (report, revision) = try scans.loadWithRevision(plan.scanId, now: now)
        guard revision == plan.scanRevision else { throw PlanValidationError.scanChanged }
        guard let exclusionsRevision = report.exclusionsRevision else { throw PlanValidationError.evidenceUnavailable }
        let settings = try configuration()
        guard try settings.exclusionsRevision == exclusionsRevision else { throw PlanValidationError.exclusionsChanged }
        let selected = try plan.itemIds.map { id in
            try failure.record(id) {
                guard let item = report.items.first(where: { $0.id == id }) else { throw PlanValidationError.unknownItem }
                guard let category = CategoryID(rawValue: item.category), settings.enabledCategories.contains(category)
                else { throw PlanValidationError.categoryDisabled }
                return item
            }
        }
        let selectedIds = Set(plan.itemIds)
        for item in selected {
            var parent = item.parentId
            while let id = parent {
                guard !selectedIds.contains(id) else { throw PlanValidationError.overlappingItems }
                parent = report.items.first(where: { $0.id == id })?.parentId
            }
        }
        var scanSettings = settings
        scanSettings.enabledCategories = Set(selected.compactMap { CategoryID(rawValue: $0.category) })
        let results = try await scanner(scanSettings)
        try Task.checkCancellation()
        let fresh = ScanReport(results: results, configuration: settings)
        let context = ScanContext(excludedPaths: settings.excludedPaths, excludedPatterns: settings.excludedPatterns)
        var contributions: [String: Int64] = [:]
        var directoryIdentities: Set<String> = []
        var reviewedItems: [ScanReport.Item] = []
        var targets: [[ScanReport.Item]] = []
        var entries: [FileEntry] = []
        var expectedIdentities: [FileEntry.ID: String] = [:]
        func flatten(_ entry: FileEntry) -> [FileEntry] { [entry] + entry.children.flatMap(flatten) }
        var roots: [(owner: String, path: String, isRoot: Bool)] = []
        for item in selected {
            try failure.record(item.id) {
                let oldTree = subtree(item, in: report)
                try eligible(oldTree, root: item, context: context)
                let matches = fresh.items.filter { $0.category == item.category && $0.path == item.path }
                guard !matches.isEmpty else { throw PlanValidationError.missingItem }
                guard matches.count == 1, let current = matches.first else { throw PlanValidationError.changedTarget }
                let newTree = subtree(current, in: fresh)
                try eligible(newTree, root: current, context: context)
                guard try fingerprint(oldTree) == fingerprint(newTree) else { throw PlanValidationError.changedTarget }
                // Match by path in the same category. The path is unique there because exactly one item matched.
                let candidates = results.categories.filter { $0.categoryID.rawValue == item.category }
                    .flatMap { $0.entries.flatMap(flatten) }.filter { $0.url.isFileURL && $0.url.path == current.path }
                guard candidates.count == 1, let entry = candidates.first else { throw PlanValidationError.changedTarget }
                entries.append(entry)
                reviewedItems.append(item.withMeasurements(of: current, status: .complete))
                targets.append(newTree)
                for target in newTree {
                    guard let path = target.path, let identity = target.evidence?.identity else {
                        throw PlanValidationError.unsupportedTarget
                    }
                    expectedIdentities[path] = identity
                    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                    // Separate selections must not remove nested paths through different scan groups.
                    let isRoot = target.id == current.id
                    for (owner, prior, priorIsRoot) in roots where owner != item.id {
                        if (resolved == prior && (isRoot || priorIsRoot))
                            || resolved.hasPrefix(prior + "/") || prior.hasPrefix(resolved + "/") {
                            throw PlanValidationError.overlappingItems
                        }
                    }
                    roots.append((item.id, resolved, isRoot))
                    if target.evidence?.isDirectory == true { directoryIdentities.insert(identity) }
                    contributions[identity] = max(contributions[identity] ?? 0, target.allocatedBytes)
                }
            }
        }
        // Directory totals can share files across roots. Omit an aggregate when that cannot be established.
        let canTotal = directoryIdentities.isEmpty || contributions.count == 1
        let total = try contributions.values.reduce(Int64(0)) { sum, bytes in
            let (next, overflow) = sum.addingReportingOverflow(bytes)
            guard !overflow else { throw PlanValidationError.changedTarget }
            return next
        }
        let measurer = AllocatedSizeMeasurer(followSymlinks: false, protectedPatterns: settings.excludedPatterns,
                                             detectCloudOnlyItems: true)
        var measured: Set<String> = []
        // Each checked item with the selected item that contains it.
        let checkedItems = zip(selected, targets).flatMap { owner, tree in tree.map { (owner: owner.id, item: $0) } }
        for (owner, item) in checkedItems {
            guard let path = item.path, measured.insert(path).inserted else { continue }
            let measurement = try await measurer.measure(URL(fileURLWithPath: path))
            try failure.record(owner) {
                guard !measurement.containsProtectedPattern else { throw PlanValidationError.excludedItem }
                guard measurement.unreadableCount == 0, !measurement.containsCloudOnlyItem else {
                    throw PlanValidationError.incompleteScan
                }
            }
        }
        for (owner, item) in checkedItems {
            guard let path = item.path, item.evidence?.matchesFile(at: URL(fileURLWithPath: path)) == true else {
                failure.id = owner
                throw PlanValidationError.changedTarget
            }
        }
        let completedAt = now.addingTimeInterval(Date().timeIntervalSince(validationStarted))
        guard plan.expiresAt > completedAt, report.expiresAt > completedAt else { throw RecordStoreError.expired }
        // A changed preference or replaced report during the scan invalidates this review.
        let currentSettings = try configuration()
        guard try currentSettings.exclusionsRevision == exclusionsRevision else { throw PlanValidationError.exclusionsChanged }
        guard scanSettings.enabledCategories.isSubset(of: currentSettings.enabledCategories) else {
            throw PlanValidationError.categoryDisabled
        }
        guard try scans.loadWithRevision(plan.scanId, now: now).revision == plan.scanRevision else {
            throw PlanValidationError.scanChanged
        }
        return PlanReview(plan: plan, revision: try RecordDigest.of(plan),
                          items: reviewedItems, scanAllocatedBytes: canTotal ? total : nil, entries: entries,
                          expectedIdentities: expectedIdentities, targets: targets,
                          exclusionsRevision: exclusionsRevision)
    }

    private func subtree(_ root: ScanReport.Item, in report: ScanReport) -> [ScanReport.Item] {
        var ids: Set<String> = [root.id]
        var tree = [root]
        for item in report.items where item.id != root.id {
            if let parent = item.parentId, ids.contains(parent) {
                tree.append(item)
                ids.insert(item.id)
            }
        }
        return tree
    }

    private func eligible(_ tree: [ScanReport.Item], root: ScanReport.Item, context: ScanContext) throws {
        guard root.eligibility != "parent_review" else { throw PlanValidationError.invalidSelection }
        for item in tree {
            guard item.protection == nil, item.eligibility != "protected", item.evidence?.isRemovalLocked != true else {
                throw PlanValidationError.protectedItem
            }
            // A scan reports completeness per category. One unreadable folder makes every item partial.
            // Validation measures each selected tree again below and rejects unreadable or cloud-only content.
            guard item.measurementStatus == .complete || item.measurementStatus == .partial else {
                throw PlanValidationError.incompleteScan
            }
            // Removal runs a tool command only for a selected item, never for an item inside it.
            guard item.eligibility != "app_review", item.id == root.id || item.evidence?.command == nil,
                  let path = item.path, path.hasPrefix("/"),
                  let evidence = item.evidence, evidence.identity != nil, evidence.version != nil
            else { throw PlanValidationError.unsupportedTarget }
            let url = URL(fileURLWithPath: path)
            guard !context.isExcluded(url), !context.isExcluded(url.resolvingSymlinksInPath()) else {
                throw PlanValidationError.excludedItem
            }
        }
    }

    private func fingerprint(_ tree: [ScanReport.Item]) throws -> [String] {
        try tree.map { item in
            // UUIDs differ between scans. Target and review fields must still agree.
            // Sizes and directory versions can change during ordinary cache use. The review shows fresh sizes.
            struct Row: Encodable {
                let path: String?
                let parentPath: String?
                let kind: String
                let name: String?
                let reason: String
                let eligibility: String
                let safeToRemove: Bool
                let protection: String?
                let recovery: String
                let detail: String?
                let evidence: PlanEvidence?
            }
            return try RecordDigest.of(Row(path: item.path,
                parentPath: tree.first(where: { $0.id == item.parentId })?.path,
                kind: item.kind, name: item.name, reason: item.reason, eligibility: item.eligibility,
                safeToRemove: item.safeToRemove, protection: item.protection, recovery: item.recovery,
                detail: item.detail, evidence: item.evidence?.reviewed))
        }.sorted()
    }
}

/// Records the item whose check failed. Validation of one plan runs sequentially.
private final class FailedItem: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    var id: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func record<T>(_ itemId: String, _ check: () throws -> T) throws -> T {
        do { return try check() } catch { id = itemId; throw error }
    }
}
