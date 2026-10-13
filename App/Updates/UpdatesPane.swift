import SwiftUI

/// Shows update preferences and the state of an approved installation.
struct UpdatesPane: View {
    @Bindable var updates: UpdateController

    var body: some View {
        PrefPane {
            PrefSection("Updates") {
                PrefToggleRow(
                    title: "Check for updates automatically",
                    description: "Moppo asks before it installs an update.",
                    isOn: $updates.automaticallyChecksForUpdates
                )
                .disabled(!updates.isAvailable)
                PrefDivider()
                PrefRow(
                    title: "Check for updates",
                    description: updates.installation.isWaiting
                        ? "Installation will start after the current operation finishes."
                        : updates.statusMessage
                ) {
                    Button("Check Now", action: updates.checkForUpdates)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!updates.canCheckForUpdates)
                }
            }
        }
    }
}
