import Foundation
import Observation

/// Waits for active work and reserves the app before update installation.
@MainActor
@Observable
final class UpdateInstallationGate {
    private let operations: OperationCoordinator
    @ObservationIgnored private var pendingInstallation: (() -> Void)?
    @ObservationIgnored private var installationOperation: OperationCoordinator.Operation?
    private(set) var isWaiting = false

    init(operations: OperationCoordinator) { self.operations = operations }

    func schedule(_ install: @escaping () -> Void) {
        guard installationOperation == nil else { return }
        pendingInstallation = install
        isWaiting = operations.isBusy
        Task { @MainActor [weak self] in self?.resumeWhenIdle() }
    }

    func cancel() {
        pendingInstallation = nil
        isWaiting = false
        if let installationOperation { operations.finish(installationOperation) }
        installationOperation = nil
    }

    private func resumeWhenIdle() {
        guard pendingInstallation != nil else { return }
        if operations.isBusy {
            isWaiting = true
            withObservationTracking {
                _ = operations.activeOperation
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in self?.resumeWhenIdle() }
            }
            return
        }
        guard let operation = operations.begin(.updateInstallation) else { return }
        installationOperation = operation
        isWaiting = false
        let install = pendingInstallation
        pendingInstallation = nil
        install?()
    }
}
