import Foundation
import MoppoCore
import MoppoPlans
import MoppoScan

struct SavedPlanServices: Sendable {
    let inspect: @Sendable (PlanHandoff) async throws -> PlanReview
    /// The set contains each permanent item that the user confirmed.
    let execute: @Sendable (PlanReview, Set<String>, @escaping @Sendable (Int, Int) -> Void) async throws -> PlanOutcome
    let recordReview: @Sendable (PlanHandoff, PlanOutcome.Status, String?) throws -> PlanOutcome

    init(validation: CleanupPlanService = CleanupPlanService(configuration: { try ScanConfiguration.current() },
            scanner: { try await ScanEnvironment.scan($0) }),
         outcomes: PlanOutcomeStore = PlanOutcomeStore(), executor: PlanExecutionService? = nil) {
        let execution = executor ?? PlanExecutionService(validation: validation, outcomes: outcomes)
        inspect = { handoff in
            let saved = try validation.plans.load(handoff.planId)
            guard try RecordDigest.of(saved) == handoff.revision else { throw PlanValidationError.planChanged }
            let review = try await validation.inspect(handoff.planId)
            guard review.revision == handoff.revision else { throw PlanValidationError.planChanged }
            try PlanExecutionService.checkSupported(review)
            return review
        }
        execute = { review, permanentItemIds, progress in
            try await execution.execute(review, confirmed: true, permanentItemIds: permanentItemIds, progress: progress)
        }
        recordReview = { try outcomes.recordReview($0, status: $1, reason: $2) }
    }
}
