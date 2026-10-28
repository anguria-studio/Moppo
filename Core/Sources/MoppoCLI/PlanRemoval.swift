import Foundation
import MoppoCore
import MoppoPlans

/// Removes a saved plan at one exact revision.
/// Trash removals need no prompt because Put Back can restore them.
/// Permanent removals need authentication by the Mac user.
enum PlanRemoval {
    typealias Authenticate = @Sendable (String) async throws -> Bool

    static func run(planId: String, revision: String, validation: CleanupPlanService, outcomes: PlanOutcomeStore,
                    authenticate: Authenticate,
                    execution: @Sendable (CleanupPlanService, PlanOutcomeStore) -> PlanExecutionService) async throws -> PlanOutcome {
        let review = try await validation.inspect(planId)
        guard review.revision == revision else { throw PlanValidationError.planChanged }
        try PlanExecutionService.checkSupported(review)
        let handoff = try PlanHandoff(planId: planId, revision: review.revision)
        var executionStarted = false
        do {
            let permanent = review.permanentItemIds
            if !permanent.isEmpty {
                let reason = permanent.count == 1
                    ? "permanently remove 1 item from a saved cleanup plan"
                    : "permanently remove \(permanent.count) items from a saved cleanup plan"
                guard try await authenticate(reason) else {
                    return try outcomes.recordReview(handoff, status: .cancelled, reason: "authentication_rejected")
                }
            }
            try Task.checkCancellation()
            executionStarted = true
            return try await execution(validation, outcomes).execute(review, confirmed: true, permanentItemIds: permanent)
        } catch is CancellationError where !executionStarted {
            return try outcomes.recordReview(handoff, status: .cancelled, reason: "cancelled")
        } catch {
            // Execution can have changed files. Its durable records remain the source of outcome information.
            if let records = try? outcomes.outcomes(planId: planId),
               !records.contains(where: { $0.planRevision == review.revision && ($0.status == .started || !$0.items.isEmpty) }) {
                let failure = CLIError.from(error, removal: true)
                let status: PlanOutcome.Status = error is CancellationError ? .cancelled
                    : error as? PlanExecutionError == .busy ? .blocked : .failed
                _ = try? outcomes.recordReview(handoff, status: status, reason: failure.code)
            }
            throw error
        }
    }
}
