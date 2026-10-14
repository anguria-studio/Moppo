import Foundation
import Observation

/// Prevents conflicting operations and tracks each operation until it finishes.
@MainActor
@Observable
final class OperationCoordinator {
    enum Kind: CaseIterable {
        case photoScan, photoDeletion, fileScan, fileRemoval, cleanupScan, cleanupRemoval, cleanupQuit
        case appUninstallPlanning, appUninstall, appLeftoverRemoval
        case emptyTrash, trashRestoration, storageMeasurement, storageRemoval
        case updateInstallation
    }

    struct Operation: Equatable {
        fileprivate let id = UUID()
        let kind: Kind
    }

    struct BlockedAction: Equatable, Identifiable {
        let id = UUID()
        let operation: Operation
        let expiresAt: ContinuousClock.Instant

        var message: String {
            switch operation.kind {
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

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    private(set) var activeOperation: Operation?
    private(set) var blockedAction: BlockedAction?

    var isBusy: Bool { activeOperation != nil }

    func begin(_ kind: Kind) -> Operation? {
        guard !isBusy else { return nil }
        let operation = Operation(kind: kind)
        activeOperation = operation
        return operation
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
        blockedAction = nil
    }
}
