import Foundation
import Observation
import MoppoCore
import MoppoPlans

/// Keeps an external proposal separate from the user's current Cleanup selection.
@MainActor
@Observable
final class SavedPlanModel {
    enum Phase { case idle, loading, reviewing, confirming, permanentConfirmation, removing, stopping, finished, failed }
    private(set) var phase: Phase = .idle
    private(set) var handoff: PlanHandoff?
    private(set) var review: PlanReview?
    private(set) var outcome: PlanOutcome?
    private(set) var message: String?
    private(set) var otherRequestMessage: String?
    private(set) var completedItems = 0
    private(set) var permanentIndex = 0
    @ObservationIgnored private let operations: OperationCoordinator
    @ObservationIgnored private let services: SavedPlanServices
    @ObservationIgnored private var operation: OperationCoordinator.Operation?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored var didRemove: () async -> Void = {}

    init(operations: OperationCoordinator, services: SavedPlanServices = SavedPlanServices()) {
        self.operations = operations
        self.services = services
    }

    var isPresented: Bool { phase != .idle }
    var canClose: Bool { phase != .removing && phase != .stopping }
    /// Items without Put Back recovery. The user confirms each one separately.
    var permanentEntries: [FileEntry] {
        guard let review else { return [] }
        return zip(review.items, review.entries).filter { $0.0.recovery == "permanent" }.map(\.1)
    }
    private var permanentItemIds: Set<String> { review?.permanentItemIds ?? [] }

    func open(_ request: PlanHandoff) {
        if isPresented {
            guard handoff != request else { return }
            otherRequestMessage = "Another plan was requested. Finish or cancel this review, then open the other plan again."
            _ = try? services.recordReview(request, .blocked, "review_busy")
            return
        }
        handoff = request
        message = nil
        otherRequestMessage = nil
        review = nil
        outcome = nil
        phase = .loading
        guard let operation = operations.begin(.cleanupPlanReview, cancel: { [weak self] in self?.cancel() }) else {
            fail(PlanExecutionError.busy)
            return
        }
        self.operation = operation
        task = Task { [weak self, services] in
            do {
                let review = try await services.inspect(request)
                try Task.checkCancellation()
                guard let self else { return }
                self.review = review
                self.phase = .reviewing
                self.task = nil
            } catch {
                guard let self else { return }
                self.task = nil
                if error is CancellationError || Task.isCancelled { self.finishCancellation() }
                else { self.fail(error) }
            }
        }
    }

    func acceptProposal() {
        guard phase == .reviewing, review != nil else { return }
        phase = .confirming
    }

    func confirmRemoval() {
        guard phase == .confirming else { return }
        if permanentEntries.isEmpty { startRemoval() }
        else { permanentIndex = 0; phase = .permanentConfirmation }
    }

    func confirmPermanentRemoval() {
        guard phase == .permanentConfirmation else { return }
        if permanentIndex + 1 < permanentEntries.count { permanentIndex += 1 }
        else { startRemoval() }
    }

    func cancel() {
        guard canClose else { return }
        if task != nil { phase = .stopping; task?.cancel(); return }
        if phase == .finished || phase == .failed { dismiss(); return }
        finishCancellation()
    }

    func stopRemoval() {
        guard phase == .removing else { return }
        phase = .stopping
        task?.cancel()
    }

    private func startRemoval() {
        guard let review else { return }
        finishOperation()
        guard let operation = operations.begin(.cleanupRemoval) else { fail(PlanExecutionError.busy); return }
        self.operation = operation
        phase = .removing
        completedItems = 0
        let confirmed = permanentItemIds
        task = Task { [weak self, services] in
            do {
                // Removal starts only after the user confirmed every permanent item.
                let result = try await services.execute(review, confirmed) { [weak self] done, _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.review?.revision == review.revision,
                              self.phase == .removing || self.phase == .stopping else { return }
                        self.completedItems = done
                    }
                }
                guard let self else { return }
                self.outcome = result
                self.phase = .finished
                self.task = nil
                self.finishOperation()
                if result.items.contains(where: { $0.removedCount > 0 || $0.status == .unknown }) { await self.didRemove() }
            } catch {
                guard let self else { return }
                self.task = nil
                // A failed outcome write can follow file changes. Never claim that nothing was removed.
                if error is CancellationError { self.finishCancellation() }
                else { self.fail(error) }
            }
        }
    }

    private func finishCancellation() {
        if let handoff {
            do { outcome = try services.recordReview(handoff, .cancelled, "review_cancelled") }
            catch {
                finishOperation()
                phase = .failed
                message = "Review cancelled. No removal started. Moppo could not save the cancellation record."
                return
            }
        }
        dismiss()
    }

    private func fail(_ error: any Error) {
        finishOperation()
        phase = .failed
        let code = (error as? PlanValidationError)?.rawValue ?? (error as? PlanExecutionError)?.rawValue
            ?? (error as? RecordStoreError).map { "record_" + String(describing: $0) }
            ?? (error as? ScanConfiguration.ConfigurationError).map { _ in "invalid_settings" } ?? "review_failed"
        if let handoff { _ = try? services.recordReview(handoff, .failed, code) }
        if error as? PlanExecutionError == .busy {
            message = "Another operation is active. Wait for it to finish, then open the plan again."
        } else if error is ScanConfiguration.ConfigurationError {
            message = "Scan settings are invalid. Review categories and exclusions in Settings, then request the plan again."
        } else if error as? PlanValidationError == .unsupportedTarget {
            message = "This plan needs a specialized review. Use the existing Cleanup or App Uninstaller controls for these items."
        } else {
            message = "Moppo could not complete this plan. It may be expired, changed, or unavailable. Check plan outcomes and Cleanup History."
        }
    }

    private func finishOperation() {
        if let operation { operations.finish(operation) }
        operation = nil
    }

    private func dismiss() {
        finishOperation()
        phase = .idle
        handoff = nil
        review = nil
        message = nil
        otherRequestMessage = nil
    }
}
