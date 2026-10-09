import Foundation
import Observation

/// Prevents conflicting operations and tracks each operation until it finishes.
@MainActor
@Observable
final class OperationCoordinator {
    enum Kind {
        case photoScan, photoDeletion, fileScan, fileRemoval, cleanupScan, cleanupRemoval, cleanupQuit
        case appUninstallPlanning, appUninstall, appLeftoverRemoval
    }

    struct Operation: Equatable {
        fileprivate let id = UUID()
        let kind: Kind
    }

    /// Includes operations that still belong to AppModel during feature extraction.
    @ObservationIgnored var hasOtherOperation: () -> Bool = { false }
    private(set) var activeOperation: Operation?

    var isBusy: Bool { activeOperation != nil || hasOtherOperation() }

    func begin(_ kind: Kind) -> Operation? {
        guard !isBusy else { return nil }
        let operation = Operation(kind: kind)
        activeOperation = operation
        return operation
    }

    /// An earlier task cannot release a later operation.
    func finish(_ operation: Operation) {
        guard activeOperation == operation else { return }
        activeOperation = nil
    }
}
