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
        let log = try ScanDiagnostics(directory: directory, metadata: [
            "app_version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "app_build": bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "app_path": bundle.bundlePath,
            "enabled_categories": preferences.enabledCategories?.map(\.rawValue).sorted().joined(separator: ",") ?? "all",
            "excluded_paths": preferences.excludedPaths.joined(separator: "\n"),
            "excluded_patterns": preferences.excludedPatterns.joined(separator: "\n"),
            "full_disk_access": "\(FullDiskAccess.isGranted)"
        ])
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

    @MainActor
    static func reveal() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }
}
