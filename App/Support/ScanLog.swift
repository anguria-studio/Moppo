import AppKit
import MoppoCore

/// Provides detailed logs only in diagnostic test builds.
enum ScanLog {
    static var isEnabled: Bool { enabled(in: .main) }

    static func enabled(in bundle: Bundle) -> Bool {
        (bundle.object(forInfoDictionaryKey: "MoppoDetailedScanLogging") as? String)?.uppercased() == "YES"
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Moppo/Scans", isDirectory: true)
    }

    private static let applicationLogName = "app-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString).jsonl"

    /// Saves app and permission events even when no scan is running.
    @MainActor
    @discardableResult
    static func recordApplicationEvent(_ event: String, details: [String: String] = [:],
                                       bundle: Bundle = .main, directory: URL = ScanLog.directory) throws -> URL? {
        guard enabled(in: bundle) else { return nil }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(applicationLogName)
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
        }
        var record = details
        record.merge([
            "event": event, "timestamp": Date().ISO8601Format(),
            "pid": "\(ProcessInfo.processInfo.processIdentifier)", "app_path": bundle.bundlePath,
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "full_disk_access": "\(FullDiskAccess.isGranted)"
        ], uniquingKeysWith: { _, value in value })
        var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        data.append(10)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
        return url
    }

    static func begin(_ preferences: CleanupModel.Preferences, bundle: Bundle = .main,
                      directory: URL = ScanLog.directory) throws -> ScanDiagnostics? {
        guard enabled(in: bundle) else { return nil }
        let log = try ScanDiagnostics(directory: directory, metadata: appMetadata(bundle).merging([
            "enabled_categories": preferences.enabledCategories?.map(\.rawValue).sorted().joined(separator: ",") ?? "all",
            "excluded_paths": preferences.excludedPaths.joined(separator: "\n"),
            "excluded_patterns": preferences.excludedPatterns.joined(separator: "\n")
        ], uniquingKeysWith: { _, value in value }))
        let span = log.context.begin("volume_information", path: NSHomeDirectory())
        if let values = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            log.context.record("volume_information", details: [
                "capacity_bytes": "\(values[.systemSize] ?? "unknown")",
                "free_bytes": "\(values[.systemFreeSize] ?? "unknown")"
            ])
        }
        log.context.end(span)
        return log
    }

    static func beginDashboard(trigger: SnapshotTrigger, bundle: Bundle = .main,
                               directory: URL = ScanLog.directory) throws -> ScanDiagnostics? {
        guard enabled(in: bundle) else { return nil }
        var metadata = appMetadata(bundle)
        metadata["app_path"] = nil
        metadata["source"] = "dashboard"
        metadata["trigger"] = trigger.rawValue
        return try ScanDiagnostics(directory: directory, metadata: metadata, maximumDetailBytes: 0)
    }

    private static func appMetadata(_ bundle: Bundle) -> [String: String] {
        [
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "app_path": bundle.bundlePath,
            "full_disk_access": "\(FullDiskAccess.isGranted)"
        ]
    }

    /// Records worktree checks outside a scan in diagnostic builds.
    /// These logs use the `worktree-review` prefix so that scan logs stay easy to find.
    static func reviewWorktrees(
        _ urls: [URL], source: String, bundle: Bundle = .main, directory: URL = ScanLog.directory,
        review: @Sendable ([URL]) async throws -> [URL: GitWorktreeReview] = {
            try await GitWorktreeReviewService().review($0)
        }
    ) async throws -> [URL: GitWorktreeReview] {
        let log = enabled(in: bundle) ? try? ScanDiagnostics(directory: directory, filePrefix: "worktree-review",
            metadata: appMetadata(bundle).merging(["source": source], uniquingKeysWith: { _, value in value })) : nil
        return try await ScanDiagnostics.$current.withValue(log?.context) {
            var outcome = "failed"
            defer {
                log?.finish(outcome: Task.isCancelled ? "cancelled" : outcome)
                log?.flush()
            }
            log?.context.record("worktree_review_requested", details: [
                "source": source, "paths": urls.map(\.path).joined(separator: "\n")
            ])
            let results = try await review(urls)
            for url in urls {
                let result = results[url] ?? GitWorktreeReview()
                log?.context.record("worktree_review_result", details: [
                    "source": source, "path": url.path, "review_status": result.statusLabel,
                    "activity": "\(result.activity)", "locks": "\(result.locks)"
                ])
            }
            outcome = "completed"
            return results
        }
    }

    @MainActor
    static func reveal() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
