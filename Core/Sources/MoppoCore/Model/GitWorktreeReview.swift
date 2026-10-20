import Foundation

/// Records local work and the checks needed before worktree removal.
public struct GitWorktreeReview: Sendable, Equatable {
    public enum Check: Sendable, Equatable {
        case clear, found(String), unknown(String)

        public var reason: String? {
            if case .unknown(let reason) = self { return reason }
            return nil
        }
    }

    public enum Outcome: String, Sendable {
        case inUse = "In use"
        case uncommittedChanges = "Uncommitted changes"
        case unpushedCommits = "Unpushed commits"
        case hasLocalFiles = "Has local files"
        case couldNotVerify = "Couldn't verify"
        case safeToRemove = "Safe to remove"

        public var isProblem: Bool { self != .couldNotVerify && self != .safeToRemove }
    }

    public struct File: Sendable, Equatable, Identifiable {
        public enum Status: String, Sendable { case changed = "Changed", untracked = "Untracked", ignored = "Ignored" }
        public var path: String
        public var status: Status
        public var allocatedBytes: Int64 = 0
        public var regeneratesSafely: Bool?
        public var canRemoveWhenMerged = false
        public var id: String { path }
        public init(path: String, status: Status, allocatedBytes: Int64 = 0, regeneratesSafely: Bool? = nil) {
            self.path = path
            self.status = status
            self.allocatedBytes = allocatedBytes
            self.regeneratesSafely = regeneratesSafely
        }
    }

    public var branch = "Branch unknown"
    public var status: FileEntry.GitWorktreeStatus = .unavailable
    public var pushStatus: FileEntry.GitWorktreePushStatus = .unknown
    public var mergedInto: String?
    public var mergePullRequestNumber: Int?
    public var mergeIssue = "The merge was not checked."
    public var localFiles: [File] = []
    public var ignoredFiles: [File] = []
    public var filesChecked = false
    public var filesIssue = "Git file status was not checked."
    public var ignoredFilesIssue = "Ignored files could not be read."
    public var pushIssue = "The remote comparison was not checked."
    public var lastFetchDate: Date?
    public var locks: Check = .unknown("Git locks were not checked.")
    public var activity: Check = .unknown("Open files and processes were not checked.")
    var verifiedGeneratedProjects: Set<URL> = []
    var mergeCandidate: GitHubMergeVerifier.Candidate?

    public init() {}

    public var ignoredBytes: Int64 { ignoredFiles.reduce(0) { $0 + $1.allocatedBytes } }
    public var mergeCheck: Check { mergedInto == nil ? .unknown(mergeIssue) : .clear }
    public var regenerableIgnoredFiles: [File] { ignoredFiles.filter { $0.regeneratesSafely == true } }
    public var localIgnoredFiles: [File] { ignoredFiles.filter { $0.regeneratesSafely == false } }
    public var unverifiedIgnoredFiles: [File] { ignoredFiles.filter { $0.regeneratesSafely == nil } }
    public var unpushedCommitCount: Int? {
        switch pushStatus {
        case .unknown: nil
        case .noUnpushedCommits: 0
        case .unpushedCommits(let count): count
        }
    }
    public var localFilesCheck: Check {
        if !localFiles.isEmpty { return .found("\(localFiles.count) \(localFiles.count == 1 ? "file" : "files")") }
        guard filesChecked, status != .unavailable else { return .unknown(filesIssue) }
        return .clear
    }

    public var ignoredFilesCheck: Check {
        let local = localIgnoredFiles.filter { !includesAfterMerge($0) }
        if !local.isEmpty { return .found(local.map(\.path).joined(separator: ", ")) }
        guard filesChecked, status != .unavailable else { return .unknown(filesIssue) }
        guard ignoredFiles.allSatisfy({ $0.regeneratesSafely == true || includesAfterMerge($0) }) else { return .unknown(ignoredFilesIssue) }
        return .clear
    }

    public func includesAfterMerge(_ file: File) -> Bool {
        mergedInto != nil && file.status == .ignored && file.canRemoveWhenMerged
    }

    public var pushCheck: Check {
        guard let count = unpushedCommitCount else { return .unknown(pushIssue) }
        if count > 0 { return .found("\(count) \(count == 1 ? "commit" : "commits")") }
        return .clear
    }

    public var outcome: Outcome {
        if case .found = locks { return .inUse }
        if case .found = activity { return .inUse }
        if status == .uncommittedChanges || !localFiles.isEmpty { return .uncommittedChanges }
        if case .found = pushCheck { return .unpushedCommits }
        if case .found = ignoredFilesCheck { return .hasLocalFiles }
        guard localFilesCheck == .clear, pushCheck == .clear, ignoredFilesCheck == .clear,
              locks == .clear, activity == .clear else { return .couldNotVerify }
        return .safeToRemove
    }

    public var isSafeToRemove: Bool { outcome == .safeToRemove }
    public var statusLabel: String { outcome.rawValue }

    static func failureReason(_ error: Error, tool: String) -> String {
        if case ProcessError.timedOut = error { return "\(tool) timed out." }
        if case ProcessError.executableMissing = error { return "\(tool) is not installed." }
        if case ProcessError.failed(_, _, let stderr) = error {
            let message = stderr.lowercased()
            if message.contains("permission denied") || message.contains("operation not permitted") {
                return "Permission to read these files was denied."
            }
        }
        if let error = error as? CocoaError, error.code == .fileReadNoPermission {
            return "Permission to read these files was denied."
        }
        return "\(tool) could not complete this check."
    }
}
