import AppKit
import MoppoCore
import MoppoPlans

public enum PlanAppLauncher {
    @MainActor
    public static func open(_ handoff: PlanHandoff) async throws {
        let executable = Bundle.main.executableURL?.resolvingSymlinksInPath()
        let embeddedApp = executable?.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let app: URL?
        if let embeddedApp, embeddedApp.pathExtension == "app",
           Bundle(url: embeddedApp)?.bundleIdentifier == ScanConfiguration.applicationDomain {
            app = embeddedApp
        } else {
            app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ScanConfiguration.applicationDomain)
        }
        guard let app else { throw CLIError(69, "app_unavailable", "Moppo is not installed. Install the app before requesting app review.") }
        let otherCopy = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == ScanConfiguration.applicationDomain
                && $0.bundleURL?.resolvingSymlinksInPath() != app.resolvingSymlinksInPath()
        }
        guard !otherCopy else {
            throw CLIError(69, "app_copy_running", "Another Moppo copy is running. Quit that copy, then request app review again.")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.arguments = handoff.launchArguments
        do { _ = try await NSWorkspace.shared.open([handoff.url], withApplicationAt: app, configuration: configuration) }
        catch { throw CLIError(69, "app_launch_failed", "Moppo could not open the plan review. Open the app, then try again.") }
    }
}
