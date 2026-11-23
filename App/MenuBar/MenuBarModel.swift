import Foundation
import Observation
import MoppoCore

/// Keeps menu bar results and requested work independent of the panel lifetime.
@MainActor
@Observable
final class MenuBarModel {
    struct Status: Equatable {
        let message: String
        var isFailure = false
    }

    private(set) var isRefreshing = false
    private(set) var status: Status?

    func canStart(in app: AppModel) -> Bool {
        !isRefreshing && !app.isShowingWelcome && !app.isBusyWithDisk && app.cleanup.pendingCleanUp == nil
    }

    func refresh(in app: AppModel) {
        guard !isRefreshing, startCleanup(in: app, removeSafeToRemove: false) else { return }
        isRefreshing = true
        Task { [self, app] in
            let activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep, reason: "Menu bar refresh"
            )
            defer {
                isRefreshing = false
                ProcessInfo.processInfo.endActivity(activity)
            }
            async let volume: Void = app.dashboard.refreshVolumeInfo()
            async let trash: Void = app.recovery.loadTrash()
            await volume
            await trash
        }
    }

    func deleteSafeToRemove(in app: AppModel) {
        guard !isRefreshing else { return }
        _ = startCleanup(in: app, removeSafeToRemove: true)
    }

    private func startCleanup(in app: AppModel, removeSafeToRemove: Bool) -> Bool {
        do {
            try app.startCleanup(removeSafeToRemove: removeSafeToRemove)
            return true
        } catch {
            status = Status(message: error.localizedDescription, isFailure: true)
            return false
        }
    }

    func handleCleanupEvent(_ event: CleanupModel.Event, cleanup: CleanupModel, operations: OperationCoordinator) {
        switch event {
        case .scanStarted:
            status = nil
        case .scanFinished(let completed, let removeSafeToRemove):
            guard status?.isFailure != true else { return }
            if !completed {
                status = Status(message: String(localized: "Scan stopped. No items were removed."))
            } else if removeSafeToRemove, cleanup.showsOutdatedResultsNotice {
                status = Status(message: String(localized: "Scan settings changed. No items were removed."), isFailure: true)
            } else if removeSafeToRemove, !cleanup.isRemoving {
                if let blocked = operations.blockedAction {
                    status = Status(message: blocked.message, isFailure: true)
                } else {
                    status = Status(message: String(localized: "No Safe to Remove items were removed."))
                }
            } else if !removeSafeToRemove {
                status = Status(message: String(localized: "Scan complete."))
            }
        case .removed(let outcome):
            let remaining = outcome.failed.count + outcome.skippedWorktrees.count
            let needsReview = remaining > 0 || outcome.toolCommandResults.contains(where: \.needsAttention)
            let removedBytes = ByteFormatting.localizedString(outcome.removedBytes)
            status = Status(
                message: needsReview
                    ? String(localized: "\(removedBytes) removed. Some items need review in Moppo.")
                    : String(localized: "\(removedBytes) removed."),
                isFailure: needsReview
            )
        case .failure(_, let message):
            status = Status(message: message, isFailure: true)
        default:
            break
        }
    }
}
