import Foundation
import MoppoCore

public enum PlanExecutionError: String, Error, Sendable {
    case busy = "execution_busy"
    case confirmationRequired = "confirmation_required"
    case alreadyAttempted = "already_attempted"
}

/// Runs confirmed plans through the existing removal service and stores the outcome.
public struct PlanExecutionService: Sendable {
    public typealias Remover = @Sendable (FileEntry, [FileEntry.ID: String], [FileEntry.ID: ToolCommandRemoval]) async throws -> CleanupOutcome
    private let validation: CleanupPlanService
    public let outcomes: PlanOutcomeStore
    private let lockDirectory: URL
    private let history: RemovalLog
    private let remove: Remover

    public init(validation: CleanupPlanService, outcomes: PlanOutcomeStore = PlanOutcomeStore(),
                lockDirectory: URL = PlanExecutionLease.defaultDirectory,
                history: RemovalLog = RemovalLog(),
                remove: @escaping Remover = { entry, identities, commands in
                    try await CleanupService().remove(entries: [entry], trashFirst: true, keepReceipt: true,
                        expectedIdentities: identities, confirmedToolCommands: commands)
                }) {
        self.validation = validation
        self.outcomes = outcomes
        self.lockDirectory = lockDirectory
        self.history = history
        self.remove = remove
    }

    /// Call only after confirmation. `permanentItemIds` must contain each permanent item that the user confirmed.
    /// This method does not authenticate a human operator.
    public func execute(_ reviewed: PlanReview, confirmed: Bool, permanentItemIds: Set<String>,
                        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> PlanOutcome {
        guard confirmed, reviewed.permanentItemIds.isSubset(of: permanentItemIds) else {
            throw PlanExecutionError.confirmationRequired
        }
        try Self.checkSupported(reviewed)
        let lease = try PlanExecutionLease(directory: lockDirectory)
        defer { withExtendedLifetime(lease) {} }
        let handoff = try PlanHandoff(planId: reviewed.plan.planId, revision: reviewed.revision)
        guard try !outcomes.outcomes(planId: handoff.planId).contains(where: {
            $0.planRevision == handoff.revision && ($0.status == .started || !$0.items.isEmpty)
        }) else { throw PlanExecutionError.alreadyAttempted }
        let current = try await validation.revalidate(reviewed)
        try Task.checkCancellation()
        let started = PlanOutcome(handoff: handoff, status: .started)
        // A durable start record is required before any file changes.
        try outcomes.save(started)
        var results: [PlanOutcome.Item] = []
        var historyUnavailable = false
        func recordSkipped(_ entry: FileEntry) {
            do { try history.append(entries: [entry], disposition: .skipped) }
            catch { historyUnavailable = true }
        }
        for (index, item) in reviewed.items.enumerated() {
            progress(index, reviewed.items.count)
            if Task.isCancelled {
                results.append(Self.skipped(item.id, status: .cancelled, reason: "cancelled"))
                continue
            }
            var removalStarted = false
            do {
                // The full check above scanned once. Each item only needs its targets to remain unchanged.
                try validation.recheck(current, itemId: item.id)
                try Task.checkCancellation()
                let entry = current.entries[index]
                let original = reviewed.entries[index]
                guard entry.toolCommand == original.toolCommand else { throw PlanValidationError.changedTarget }
                let commands = original.toolCommand.map { [entry.id: $0] } ?? [:]
                let remove = self.remove
                let identities = current.expectedIdentities
                // Finish this item before cancellation stops the next item. Preserve its receipt and result.
                removalStarted = true
                let outcome = try await Task.detached {
                    try await remove(entry, identities, commands)
                }.value
                let failed = !outcome.failed.isEmpty || !outcome.skippedWorktrees.isEmpty
                let status: PlanOutcome.ItemStatus = failed ? (outcome.removedCount > 0 ? .partial : .failed)
                    : outcome.removedCount == 0 ? .skipped : outcome.deletedCount > 0 ? .deleted : .trashed
                if status == .skipped { recordSkipped(original) }
                results.append(.init(itemId: item.id, status: status,
                    reason: failed ? "removal_failed" : outcome.removedCount == 0 ? "not_removed" : nil,
                    removedCount: outcome.removedCount, trashedCount: outcome.trashedCount, deletedCount: outcome.deletedCount,
                    removedBytes: outcome.removedBytes, privateBytes: outcome.freedBytes,
                    unmeasuredCount: outcome.unreportedFreedCount))
            } catch {
                let status: PlanOutcome.ItemStatus = removalStarted ? .unknown : error is CancellationError ? .cancelled : .skipped
                let reason = removalStarted ? "outcome_unknown"
                    : (error as? PlanValidationError)?.rawValue ?? (error is CancellationError ? "cancelled" : "validation_failed")
                if status == .skipped { recordSkipped(reviewed.entries[index]) }
                results.append(Self.skipped(item.id, status: status, reason: reason))
            }
        }
        progress(reviewed.items.count, reviewed.items.count)
        let completed = results.allSatisfy { $0.status == .trashed || $0.status == .deleted }
        let cancelled = results.allSatisfy { $0.status == .cancelled }
        let status: PlanOutcome.Status = completed ? .completed : cancelled ? .cancelled : .partial
        let outcome = PlanOutcome(handoff: handoff, runId: started.runId, status: status,
                                  reason: historyUnavailable ? "history_unavailable" : nil, items: results)
        try outcomes.save(outcome)
        return outcome
    }

    /// Specialized app workflows retain their existing review screens.
    public static func checkSupported(_ review: PlanReview) throws {
        func check(_ entry: FileEntry, child: Bool) throws {
            guard entry.gitWorktreeReview == nil, entry.soundLibrary == nil, entry.xcodeBuildCacheReview == nil,
                  entry.codexSession == nil,
                  !child || entry.toolCommand == nil else { throw PlanValidationError.unsupportedTarget }
            for child in entry.children { try check(child, child: true) }
        }
        for entry in review.entries { try check(entry, child: false) }
    }

    private static func skipped(_ id: String, status: PlanOutcome.ItemStatus, reason: String) -> PlanOutcome.Item {
        .init(itemId: id, status: status, reason: reason, removedCount: 0, trashedCount: 0, deletedCount: 0,
              removedBytes: 0, privateBytes: 0, unmeasuredCount: 0)
    }
}
