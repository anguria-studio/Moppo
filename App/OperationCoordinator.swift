import Foundation
import Observation
import MoppoPlans

/// Prevents conflicting operations and tracks each operation until it finishes.
@MainActor
@Observable
final class OperationCoordinator {
    enum Kind: CaseIterable {
        case photoScan, photoDeletion, fileScan, fileRemoval, cleanupScan, cleanupRemoval, cleanupQuit
        case cleanupPlanReview
        case appUninstallPlanning, appUninstall, appLeftoverRemoval
        case emptyTrash, trashRestoration, storageMeasurement, storageRemoval
        case updateInstallation

        var changesFiles: Bool {
            switch self {
            case .photoDeletion, .fileRemoval, .cleanupRemoval, .appUninstall, .appLeftoverRemoval,
                 .emptyTrash, .trashRestoration, .storageRemoval, .updateInstallation: true
            default: false
            }
        }
    }

    struct Operation: Equatable {
        fileprivate let id = UUID()
        let kind: Kind
    }

    struct BlockedAction: Equatable, Identifiable {
        let id = UUID()
        let operation: Operation
        let expiresAt: ContinuousClock.Instant
        var externalMessage: String? = nil

        var message: String {
            if let externalMessage { return externalMessage }
            return switch operation.kind {
            case .cleanupPlanReview: "A saved cleanup plan is open. Finish or cancel its review."
            case .cleanupScan: "Cleanup scan is running. Wait for it to finish, or stop the scan."
            case .fileScan: "Duplicate file scan is running. Wait for it to finish, or stop the scan."
            case .photoScan: "Duplicate photo scan is running. Wait for it to finish, or stop the scan."
            case .storageMeasurement: "Storage Explorer scan is running. Wait for it to finish, or stop the scan."
            case .appUninstallPlanning: "Moppo is checking selected apps. Wait for it to finish, or stop the check."
            case .cleanupQuit: "Moppo is waiting for applications to quit. Wait for it to finish, or cancel the wait."
            case .cleanupRemoval, .fileRemoval, .storageRemoval, .appLeftoverRemoval:
                "Moppo is removing files. Wait for it to finish."
            case .photoDeletion: "Moppo is removing photos. Wait for it to finish."
            case .appUninstall: "Moppo is uninstalling applications. Wait for it to finish."
            case .emptyTrash: "Moppo is emptying the Trash. Wait for it to finish."
            case .trashRestoration: "Moppo is restoring items. Wait for it to finish."
            case .updateInstallation: "Moppo is preparing an update. Wait for it to finish."
            }
        }
    }

    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var cancelActiveOperation: (() -> Void)?
    @ObservationIgnored private var terminationReady: (() -> Void)?
    @ObservationIgnored private let acquireRemovalLease: () throws -> PlanExecutionLease?
    @ObservationIgnored private var removalLease: PlanExecutionLease?

    init(now: @escaping () -> ContinuousClock.Instant = { .now },
         acquireRemovalLease: @escaping () throws -> PlanExecutionLease? = { nil }) {
        self.now = now
        self.acquireRemovalLease = acquireRemovalLease
    }

    private(set) var activeOperation: Operation?
    private(set) var blockedAction: BlockedAction?
    private(set) var isTerminating = false

    var isBusy: Bool { activeOperation != nil || isTerminating }

    func begin(_ kind: Kind, cancel: (() -> Void)? = nil) -> Operation? {
        guard !isBusy else { return nil }
        let operation = Operation(kind: kind)
        if kind.changesFiles {
            do { removalLease = try acquireRemovalLease() }
            catch {
                blockedAction = BlockedAction(operation: operation, expiresAt: now() + .seconds(8),
                    externalMessage: error as? PlanExecutionError == .busy
                        ? "Another Moppo client is changing files. Wait for it to finish."
                        : "Moppo could not lock cleanup operations. No files were changed.")
                return nil
            }
        }
        blockedAction = nil
        cancelActiveOperation = cancel
        activeOperation = operation
        return operation
    }

    /// Stops a cancellable operation and prevents new work until the app quits.
    func cancelForTermination(whenReady: @escaping () -> Void) -> Bool {
        guard !isTerminating else { return true }
        guard let cancelActiveOperation else { return false }
        isTerminating = true
        terminationReady = whenReady
        cancelActiveOperation()
        return true
    }

    /// Reports the active operation without changing or queuing the requested action.
    func explainBlockedAction() -> Bool {
        guard let operation = activeOperation else { return false }
        let instant = now()
        if let blockedAction, blockedAction.operation == operation, blockedAction.expiresAt > instant {
            return true
        }
        blockedAction = BlockedAction(operation: operation, expiresAt: instant + .seconds(8))
        return true
    }

    func dismissBlockedAction(_ id: BlockedAction.ID? = nil) {
        if let id, blockedAction?.id != id { return }
        blockedAction = nil
    }

    /// An earlier task cannot release a later operation.
    func finish(_ operation: Operation) {
        guard activeOperation == operation else { return }
        activeOperation = nil
        removalLease = nil
        blockedAction = nil
        cancelActiveOperation = nil
        let ready = terminationReady
        terminationReady = nil
        ready?()
    }
}
