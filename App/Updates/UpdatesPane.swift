import SwiftUI

/// Shows update preferences and the state of an approved installation.
struct UpdatesPane: View {
    @Bindable var updates: UpdateController

    var body: some View {
        PrefPane {
            PrefSection(String(localized: "Updates")) {
                PrefToggleRow(
                    title: String(localized: "Check for updates automatically"),
                    description: String(localized: "Moppo asks before it installs an update."),
                    isOn: $updates.automaticallyChecksForUpdates
                )
                .disabled(!updates.isAvailable)
                PrefDivider()
                PrefRow(
                    title: String(localized: "Check for updates"),
                    description: updates.installation.isWaiting
                        ? String(localized: "Installation will start after the current operation finishes.")
                        : updates.statusMessage
                ) {
                    Button("Check Now", action: updates.checkForUpdates)
                        .buttonStyle(SecondaryButtonStyle(fill: Token.Fill.buttonOnCard))
                        .disabled(!updates.canCheckForUpdates)
                }
            }
        }
    }
}
