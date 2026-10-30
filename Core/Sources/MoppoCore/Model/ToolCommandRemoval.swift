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
        case simulatorRuntimeAbsent(SimulatorRuntimeReview)
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
    private let scriptURL: URL?
    private let scriptIdentity: String?

    init(targetURL: URL, executable: String?, arguments: [String], environment: [String: String],
         expectedResult: ExpectedResult, timeout: Duration = .seconds(120), protectedPatterns: [String] = [],
         scriptURL: URL? = nil) {
        self.targetURL = targetURL.standardizedFileURL
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.expectedResult = expectedResult
        self.timeout = timeout
        self.protectedPatterns = protectedPatterns
        let fileTarget: Bool
        if case .simulatorRuntimeAbsent = expectedResult { fileTarget = true } else { fileTarget = false }
        paths = Self.pathIdentities(targetURL, fileTarget: fileTarget)
        resolvedExecutable = executable.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        executableIdentity = resolvedExecutable.flatMap(Self.fileVersion)
        self.scriptURL = scriptURL
        scriptIdentity = scriptURL.flatMap { Self.fileVersion($0.path) }
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

    var simulatorRuntime: SimulatorRuntimeReview? {
        if case .simulatorRuntimeAbsent(let review) = expectedResult { return review }
        return nil
    }

    static func simulatorRuntime(_ review: SimulatorRuntimeReview, fallbackURL: URL,
                                 protectedPatterns: [String]) -> Self {
        Self(targetURL: review.runtime.backingURL ?? fallbackURL, executable: "/usr/bin/xcrun",
            arguments: ["simctl", "runtime", "delete", review.runtime.identifier],
            environment: ["DEVELOPER_DIR": review.developerDirectory], expectedResult: .simulatorRuntimeAbsent(review),
            protectedPatterns: protectedPatterns)
    }

    static func homebrewVersion(_ version: HomebrewFormulaVersion, executable: String,
                                protectedPatterns: [String] = []) -> Self {
        let script = HomebrewFormulaVersions.scriptURL
        return Self(targetURL: URL(fileURLWithPath: version.path), executable: executable,
            arguments: ["ruby", script.path, "remove", version.path, version.token],
            environment: HomebrewFormulaVersions.environment, expectedResult: .targetAbsent,
            protectedPatterns: protectedPatterns, scriptURL: script)
    }

    public var isHomebrewVersion: Bool {
        guard let scriptURL else { return false }
        return scriptURL == HomebrewFormulaVersions.scriptURL
    }

    public var lockReason: String? {
        guard let executable, executableIdentity != nil,
              FileManager.default.isExecutableFile(atPath: executable) else {
            return "The removal tool is missing. Install the tool, then scan again."
        }
        if let runtime = simulatorRuntime {
            if let reason = runtime.protectionExplanation { return reason }
            guard runtime.toolsAreUnchanged else { return "The Xcode toolchain changed. Scan again before removal." }
        }
        guard scriptURL == nil || scriptIdentity != nil else {
            return "The removal script is missing. Install Moppo again before removal."
        }
        guard paths != nil else { return "Moppo could not verify the item path. Scan again before removal." }
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
              Self.fileVersion(resolvedExecutable) == executableIdentity,
              scriptURL.map({ Self.fileVersion($0.path) == scriptIdentity }) ?? true,
              let paths, paths == Self.pathIdentities(targetURL, fileTarget: simulatorRuntime != nil) else { return false }
        return true
    }

    func targetIsAbsentAfterRemoval() -> Bool {
        guard let paths, FileIdentity.isAbsent(targetURL) else { return false }
        return paths.dropFirst().allSatisfy {
            let url = URL(fileURLWithPath: $0.path)
            return FileIdentity.of(url) == $0.identity || (simulatorRuntime != nil && FileIdentity.isAbsent(url))
        }
    }

    func removalIsVerified() -> Bool {
        switch expectedResult {
        case .targetAbsent: targetIsAbsentAfterRemoval()
        case .simulatorRuntimeAbsent: false
        }
    }

    func targetIsUnchangedAfterRemoval() -> Bool {
        guard let paths else { return false }
        return paths == Self.pathIdentities(targetURL, fileTarget: simulatorRuntime != nil)
    }

    private static func pathIdentities(_ url: URL, fileTarget: Bool) -> [PathIdentity]? {
        guard url.isFileURL, url.path.hasPrefix("/") else { return nil }
        var current = URL(fileURLWithPath: FileIdentity.physicalPath(url.standardizedFileURL.path))
        var result: [PathIdentity] = []
        while true {
            var info = stat()
            let isFile = result.isEmpty && fileTarget
            guard lstat(current.path, &info) == 0, info.st_mode & S_IFMT == (isFile ? S_IFREG : S_IFDIR),
                  let identity = FileIdentity.of(current) else { return nil }
            let version = isFile ? fileVersion(current.path) : identity
            guard let version else { return nil }
            result.append(.init(path: current.path, identity: version))
            if current.path == "/" { return result }
            current.deleteLastPathComponent()
        }
    }

    private static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func fileVersion(_ path: String) -> String? {
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
    public var remainingStorageReason: String?

    public var removedBytes: Int64? {
        guard let beforeBytes, let afterBytes else { return nil }
        return max(0, beforeBytes - afterBytes)
    }

    /// True when the result has a failure, retained storage, or unverified disk space recovery.
    public var needsAttention: Bool {
        status != .completed || failureReason != nil || remainingStorageReason != nil
            || (beforeBytes != nil && freedBytes == nil)
    }

    public var summary: String {
        let completed = remainingStorageReason == nil
            ? "\(name) was removed permanently."
            : "\(name) is no longer installed. Cleanup is incomplete."
        var parts = [status == .completed ? completed : "\(name): \(failureReason ?? "Removal did not finish.")"]
        if let remainingStorageReason {
            parts.append(remainingStorageReason)
            parts.append("This space remains on disk.")
        }
        if let removedBytes, removedBytes > 0 {
            parts.append("Item storage decreased by \(ByteFormatting.string(removedBytes)).")
        }
        if let freedBytes {
            parts.append("Verified disk space recovery: \(ByteFormatting.string(freedBytes)).")
        } else if beforeBytes != nil, remainingStorageReason == nil {
            parts.append("Disk space recovery could not be verified.")
        }
        if status == .completed, let failureReason { parts.append(failureReason) }
        if let exitStatus, exitStatus != 0 { parts.append("Exit status: \(exitStatus).") }
        if let terminationSignal { parts.append("Terminated by signal \(terminationSignal).") }
        if !standardError.isEmpty {
            parts.append(String(standardError.prefix(512)) + (standardError.count > 512 ? "…" : ""))
        }
        return parts.joined(separator: "\n")
    }
}
