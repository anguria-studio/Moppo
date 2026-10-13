import AppKit
import SwiftUI

/// Shows a permission reset for an absent Moppo entry without running it.
struct PhotoAccessRecoveryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var didCopyCommand = false

    static let resetCommand = "tccutil reset Photos com.tommasolaterza.Moppo"
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Recover Photos Access")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Use these steps if Moppo is missing from System Settings > Privacy & Security > Photos.")
                    Text("Install the latest Moppo version before you reset access. An older build can lack the required Photos permission setting.")
                    Text("This command resets only Moppo's Photos permission. It does not grant access or change your photos.")
                    Text("1. Copy the command below.")
                    Text(Self.resetCommand)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                    Button(didCopyCommand ? "Copy Command Again" : "Copy Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.resetCommand, forType: .string)
                        didCopyCommand = true
                    }
                    Text("2. Quit Moppo.")
                    Text("3. Open Terminal.")
                    Text("4. Paste the command in Terminal.")
                    Text("5. Press Return.")
                    Text("6. Open Moppo from Applications in Finder.")
                    Text("7. Select Duplicates > Photos.")
                    Text("8. Select Allow to show the macOS permission choice.")
                    Text("If Moppo is still missing, use Help > Report a Problem in Moppo.")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Link("Read Apple's reset instructions", destination: URL(
                    string: "https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos"
                )!)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 560, height: 540)
    }
}
