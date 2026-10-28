import Foundation

/// The method that owns removal of a Cleanup row.
public enum RemovalMethod: Sendable, Equatable {
    case trash
    case toolCommand(ToolCommandRemoval)
}

/// A fixed command and the identities captured during its review.
public struct ToolCommandRemoval: Sendable, Equatable {
    public enum ExpectedResult: Sendable, Equatable {
        case targetAbsent
    }

    struct PathIdentity: Sendable, Equatable {
        let path: String
        let identity: String
    }

    public let targetURL: URL
    public let executable: String?
    public let arguments: [String]
    public let environment: [String: String]
    public let expectedResult: ExpectedResult
    let timeout: Duration
    let protectedPatterns: [String]
    private let paths: [PathIdentity]?
    private let resolvedExecutable: String?
    private let executableIdentity: String?

    init(targetURL: URL, executable: String?, arguments: [String], environment: [String: String],
         expectedResult: ExpectedResult, timeout: Duration = .seconds(120), protectedPatterns: [String] = []) {
        self.targetURL = targetURL.standardizedFileURL
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.expectedResult = expectedResult
        self.timeout = timeout
        self.protectedPatterns = protectedPatterns
        paths = Self.directoryIdentities(targetURL)
        resolvedExecutable = executable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        executableIdentity = resolvedExecutable.flatMap(Self.executableVersion)
    }

    public static func resolveGo() -> String? {
        ["/opt/homebrew/bin/go", "/usr/local/bin/go", "/usr/local/go/bin/go"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }

    public static func goModuleCache(at url: URL, executable: String?, protectedPatterns: [String] = []) -> Self {
        Self(targetURL: url, executable: executable, arguments: ["clean", "-modcache"], environment: [
            "GOMODCACHE": url.standardizedFileURL.path,
            "GOENV": "off", "GOTOOLCHAIN": "local", "GOWORK": "off", "GOFLAGS": "",
        ], expectedResult: .targetAbsent, protectedPatterns: protectedPatterns)
    }

    public var lockReason: String? {
        guard let executable, executableIdentity != nil,
              FileManager.default.isExecutableFile(atPath: executable) else {
            return "The removal tool is missing. Install the tool, then scan again."
        }
        guard paths != nil else { return "The cache path could not be verified. Scan again before removal." }
        return nil
    }

    /// Display text only. The runner receives the executable and arguments separately.
    public var command: String {
        let values = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.quoted($0.value))" }
            + [Self.quoted(executable ?? "go")] + arguments.map(Self.quoted)
        return values.joined(separator: " ")
    }

    func isStillValid() -> Bool {
        guard lockReason == nil, let executable, let resolvedExecutable,
              URL(fileURLWithPath: executable).resolvingSymlinksInPath().path == resolvedExecutable,
              Self.executableVersion(resolvedExecutable) == executableIdentity,
              let paths, paths == Self.directoryIdentities(targetURL) else { return false }
        return true
    }

    func targetIsAbsentAfterRemoval() -> Bool {
        guard let paths, FileIdentity.isAbsent(targetURL) else { return false }
        return paths.dropFirst().allSatisfy {
            FileIdentity.of(URL(fileURLWithPath: $0.path)) == $0.identity
        }
    }

    func removalIsVerified() -> Bool {
        switch expectedResult {
        case .targetAbsent: targetIsAbsentAfterRemoval()
        }
    }

    func targetIsUnchangedAfterRemoval() -> Bool {
        guard let paths else { return false }
        return paths == Self.directoryIdentities(targetURL)
    }

    private static func directoryIdentities(_ url: URL) -> [PathIdentity]? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        var current = URL(fileURLWithPath: FileIdentity.physicalPath(url.standardizedFileURL.path))
        var result: [PathIdentity] = []
        while true {
            var info = stat()
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  let identity = FileIdentity.of(current) else { return nil }
            result.append(.init(path: current.path, identity: identity))
            if current.path == "/" { return result }
            current.deleteLastPathComponent()
        }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func executableVersion(_ path: String) -> String? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
    }
}

/// A command result with measured storage and permanent removal details.
public struct ToolCommandRemovalResult: Sendable, Equatable, Codable {
    public enum Status: String, Sendable, Codable {
        case completed, failed, timedOut, cancelled, notStarted
    }

    public let targetID: String
    public let name: String
    public let command: String
    public var status: Status = .notStarted
    public var exitStatus: Int32?
    public var terminationSignal: Int32?
    public var standardError = ""
    public var beforeBytes: Int64?
    public var afterBytes: Int64?
    public var freedBytes: Int64?
    public var failureReason: String?

    public var removedBytes: Int64? {
        guard let beforeBytes, let afterBytes else { return nil }
        return max(0, beforeBytes - afterBytes)
    }

    public var summary: String {
        var parts = [status == .completed ? "\(name) was removed permanently." : "\(name): \(failureReason ?? "Removal did not finish.")"]
        if let removedBytes {
            parts.append("Cache storage decreased by \(ByteFormatting.string(removedBytes)).")
        }
        if let freedBytes {
            parts.append("Verified disk space recovery: \(ByteFormatting.string(freedBytes)).")
        } else if beforeBytes != nil {
            parts.append("Disk space recovery could not be verified.")
        }
        if status == .completed, let failureReason { parts.append(failureReason) }
        if let exitStatus { parts.append("Exit status: \(exitStatus).") }
        if let terminationSignal { parts.append("Terminated by signal \(terminationSignal).") }
        if !standardError.isEmpty {
            parts.append(String(standardError.prefix(512)) + (standardError.count > 512 ? "…" : ""))
        }
        return parts.joined(separator: "\n")
    }
}
