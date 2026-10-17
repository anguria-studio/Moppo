import AppKit
import MoppoCore

/// Supplies application state and normal quit requests to Cleanup.
@MainActor
struct CleanupApplications {
    var stillRunning: @MainActor ([FileEntry.RunningOwner]) -> [FileEntry.RunningOwner] = ApplicationRuntime.stillRunning
    var quit: @MainActor ([FileEntry.RunningOwner]) async -> [FileEntry.RunningOwner] = ApplicationRuntime.quit
    var registeredIdentifiers: @MainActor (Set<String>) -> Set<String> = ApplicationRuntime.registeredApplicationBundleIdentifiers
}

@MainActor
enum ApplicationRuntime {
    /// Cleanup cannot quit Moppo or Finder to release their files.
    static func canQuitForCleanup(_ owner: FileEntry.RunningOwner) -> Bool {
        if let identifier = owner.bundleIdentifier,
           identifier == AppIdentity.bundleIdentifier || identifier == Bundle.main.bundleIdentifier
            || identifier == "com.apple.finder" { return false }
        return URL(fileURLWithPath: owner.bundlePath).standardizedFileURL.path != Bundle.main.bundleURL.standardizedFileURL.path
    }

    static func currentRunningOwners() -> [FileEntry.RunningOwner] {
        NSWorkspace.shared.runningApplications.compactMap { application in
            guard application.activationPolicy == .regular else { return nil }
            guard let url = application.bundleURL else { return nil }
            let owner = FileEntry.RunningOwner(
                name: application.localizedName
                    ?? url.deletingPathExtension().lastPathComponent,
                bundleIdentifier: application.bundleIdentifier,
                bundlePath: url.path
            )
            return canQuitForCleanup(owner) ? owner : nil
        }
    }
    private static func processes(of owner: FileEntry.RunningOwner) -> [NSRunningApplication] {
        let path = URL(fileURLWithPath: owner.bundlePath).standardizedFileURL.path
        return NSWorkspace.shared.runningApplications.filter { application in
            if let identifier = owner.bundleIdentifier,
               application.bundleIdentifier == identifier { return true }
            guard let url = application.bundleURL?.standardizedFileURL else { return false }
            return url.path == path || url.path.hasPrefix(path + "/")
        }
    }
    static func stillRunning(
        _ owners: [FileEntry.RunningOwner]
    ) -> [FileEntry.RunningOwner] {
        var seen: Set<FileEntry.RunningOwner> = []
        return owners.filter { seen.insert($0).inserted && !processes(of: $0).isEmpty }
    }
    static func registeredApplicationBundleIdentifiers(
        for candidates: Set<String>
    ) -> Set<String> {
        let fileManager = FileManager.default
        return OrphanedAppLeftoverPlanner.registeredApplicationBundleIdentifiers(
            for: candidates,
            running: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            isInstalled: { identifier in
                guard let application = NSWorkspace.shared.urlForApplication(
                    withBundleIdentifier: identifier
                ) else { return false }
                return fileManager.fileExists(atPath: application.path)
            }
        )
    }

    static func quit(_ owners: [FileEntry.RunningOwner]) async -> [FileEntry.RunningOwner] {
        let requested = owners.filter(canQuitForCleanup)
        for owner in requested {
            for process in processes(of: owner) {
                guard !Task.isCancelled else { return stillRunning(owners) }
                guard process.processIdentifier != ProcessInfo.processInfo.processIdentifier else { continue }
                process.terminate()
            }
        }
        for _ in 0..<300 where !stillRunning(requested).isEmpty {
            do { try await Task.sleep(for: .milliseconds(100)) }
            catch { break }
        }
        return stillRunning(owners)
    }
}
