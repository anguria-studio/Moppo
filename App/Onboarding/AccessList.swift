import SwiftUI

/// Shares permission controls between onboarding and Settings.
struct AccessList: View {
    let access: AccessModel
    var animateEntrance = false

    var body: some View {
        VStack(spacing: 10) {
            permission(.disk, title: "Full Disk Access",
                detail: "Enabling this lets Moppo scan more of your Mac.",
                symbol: "externaldrive")
                .modifier(OnboardingEntrance(index: 3, enabled: animateEntrance))
            permission(.photos, title: "Photos Library", detail: "Useful if you want to scan for duplicates.", symbol: "photo")
                .modifier(OnboardingEntrance(index: 4, enabled: animateEntrance))
            permission(.notifications, title: "Notifications", detail: "Get notified when your Mac has little space left.", symbol: "bell")
                .modifier(OnboardingEntrance(index: 5, enabled: animateEntrance))

            if access.openedDiskSettings, access.disk != .allowed {
                Text("If macOS asks you to quit Moppo, quit and reopen it after you enable access.")
                    .font(.system(size: 12))
                    .foregroundStyle(Token.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error = access.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Token.Text.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            await access.refresh()
            guard !access.isPreview else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                await access.refresh()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await access.refresh() }
        }
    }

    private func permission(
        _ permission: AccessModel.Permission, title: String, detail: String, symbol: String
    ) -> some View {
        let status = access.status(for: permission)
        let isUnavailable = status == .restricted || status == .unavailable || status == .checking
        let actionLabel = status.permitsAccess || isUnavailable ? status.label : "Enable"
        let hint = isUnavailable ? status.label : (status == .undecided
            ? "Enable \(title)" : "Open \(title) in System Settings")
        return PermissionRow(
            title: title, detail: detail, symbol: symbol,
            status: access.requesting == permission ? "Checking" : actionLabel,
            isEnabled: status.permitsAccess || isUnavailable,
            settingsHint: hint,
            accessibilityStatus: status.label
        ) {
            Task { await access.performAction(for: permission) }
        }
        .disabled(isUnavailable || access.requesting != nil)
    }
}

struct AccessPane: View {
    let access: AccessModel

    var body: some View {
        PrefPane {
            VStack(alignment: .leading, spacing: 6) {
                Text("Choose what Moppo can access").font(.system(size: 20, weight: .semibold))
                Text("All access is optional. Full Disk Access lets Moppo scan more of your Mac.")
                    .font(.system(size: 13)).foregroundStyle(Token.Text.secondary)
            }
            AccessList(access: access)
        }
    }
}
