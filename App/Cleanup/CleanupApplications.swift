import AppKit
import MoppoCore
import MoppoScan

/// Supplies application state and normal quit requests to Cleanup.
@MainActor
struct CleanupApplications {
    var stillRunning: @MainActor ([FileEntry.RunningOwner]) -> [FileEntry.RunningOwner] = ApplicationRuntime.stillRunning
    var quit: @MainActor ([FileEntry.RunningOwner]) async -> [FileEntry.RunningOwner] = ApplicationRuntime.quit
    var registeredIdentifiers: @MainActor (Set<String>) -> Set<String> = ApplicationRuntime.registeredApplicationBundleIdentifiers
}

@MainActor
enum ApplicationRuntime {
    static func canQuitForCleanup(_ owner: FileEntry.RunningOwner) -> Bool {
        ScanEnvironment.canQuitForCleanup(owner)
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
    static func registeredApplicationBundleIdentifiers(for candidates: Set<String>) -> Set<String> {
        ScanEnvironment.registeredApplicationBundleIdentifiers(for: candidates)
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
