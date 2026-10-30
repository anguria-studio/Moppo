import CryptoKit
import Darwin
import Foundation
import MoppoCore

/// Revisions detect changes. They are not signatures or removal permissions.
public enum RecordDigest {
    public static func of<T: Encodable>(_ value: T) throws -> String {
        SHA256.hash(data: try ScanReport.encoder().encode(value)).map { String(format: "%02x", $0) }.joined()
    }

    public static func isValid(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

struct PlanEvidence: Codable, Sendable, Equatable {
    let identity: String?
    var version: String?
    let isRemovalLocked: Bool
    let isDirectory: Bool
    let removesAsUnit: Bool
    let command: String?
    let runningOwner: String?

    init(_ entry: FileEntry) {
        identity = entry.url.isFileURL ? FileIdentity.of(entry.url) : nil
        version = Self.fileVersion(entry.url)
        isRemovalLocked = entry.isRemovalLocked
        isDirectory = (try? entry.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        removesAsUnit = entry.removesAsUnit
        command = entry.toolCommand?.command
        runningOwner = entry.inUseBy.map { $0.bundlePath + "\n" + $0.name }
    }

    /// Directory contents change during ordinary use. A directory must keep its identity and type.
    /// A regular file must also keep its version.
    func matchesFile(at url: URL) -> Bool {
        guard identity == FileIdentity.of(url), let current = Self.fileVersion(url) else { return false }
        return isDirectory ? Self.isDirectoryNode(url) : version == current
    }

    /// Fields that identify a reviewed target. Directory versions change when the directory contents change.
    var reviewed: PlanEvidence {
        var copy = self
        if isDirectory { copy.version = nil }
        return copy
    }

    private static func isDirectoryNode(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func fileVersion(_ url: URL) -> String? {
        guard url.isFileURL else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG || info.st_mode & S_IFMT == S_IFDIR else { return nil }
        // Resolve aliases for comparison only. Removal must use the freshly scanned entry.
        let fields = [url.resolvingSymlinksInPath().path, String(info.st_mode), String(info.st_size),
                      String(info.st_mtimespec.tv_sec), String(info.st_mtimespec.tv_nsec),
                      String(info.st_ctimespec.tv_sec), String(info.st_ctimespec.tv_nsec)]
        return try? RecordDigest.of(fields)
    }
}

extension ScanConfiguration {
    var exclusionsRevision: String {
        get throws {
            try RecordDigest.of([excludedPaths.sorted(), excludedPatterns.sorted()])
        }
    }
}
