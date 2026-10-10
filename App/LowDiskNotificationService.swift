import Foundation
import UserNotifications
import MoppoCore

/// Bridges the pure threshold policy to Notification Center.
///
/// Permission requests belong to the Access screen. Background observations do not request access.
@MainActor
final class LowDiskNotificationService {
    nonisolated static let notificationIdentifier = "com.tommasolaterza.Moppo.low-disk"

    private let center: UNUserNotificationCenter
    private let defaults: UserDefaults

    private enum Key {
        static let policyState = "runtime.lowDiskNotification.policyState"
    }

    init(
        center: UNUserNotificationCenter = .current(),
        defaults: UserDefaults = .standard
    ) {
        self.center = center
        self.defaults = defaults
    }

    func observe(
        freeBytes: Int64,
        volumeName: String,
        thresholdGB: Int,
        now: Date = .now
    ) async {
        let thresholdBytes = Int64(thresholdGB) * ByteFormatting.bytesPerGB
        let decision = LowDiskNotificationPolicy.evaluate(
            freeBytes: freeBytes,
            thresholdBytes: thresholdBytes,
            now: now,
            state: loadState()
        )

        // Save the crossing before delivery. Save the delivery time only after delivery succeeds.
        let previous = loadState()
        var crossingOnly = decision.state
        crossingOnly.lastNotificationAt = previous.lastNotificationAt
        saveState(crossingOnly)
        guard decision.shouldNotify, await authorizationAllowsDelivery() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Storage is running low"
        content.body = "\(ByteFormatting.string(freeBytes)) remains on \(volumeName), "
            + "below your \(thresholdGB) GB warning threshold."
        content.sound = .default
        content.userInfo = ["destination": "dashboard"]

        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            // Reload the state because free space can change during notification delivery.
            var delivered = loadState()
            delivered.lastNotificationAt = Date()
            saveState(delivered)
        } catch {
            // Delivery failed: the cooldown has not started, and the next crossing
            // gets a real attempt.
        }
    }

    private func authorizationAllowsDelivery() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func loadState() -> LowDiskNotificationPolicy.State {
        guard let data = defaults.data(forKey: Key.policyState),
              let state = try? JSONDecoder().decode(
                LowDiskNotificationPolicy.State.self,
                from: data
              ) else { return .init() }
        return state
    }

    private func saveState(_ state: LowDiskNotificationPolicy.State) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: Key.policyState)
    }
}
