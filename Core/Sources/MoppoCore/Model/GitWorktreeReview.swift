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

    enum CheckText: Sendable, Equatable {
        case clear, found(EngineText), unknown(EngineText)

        init(_ result: Check) {
            self = switch result {
            case .clear: .clear
            case .found(let detail): .found(.verbatim(detail))
            case .unknown(let detail): .unknown(.verbatim(detail))
            }
        }

        func result(localized: Bool) -> Check {
            switch self {
            case .clear: .clear
            case .found(let detail): .found(detail.string(localized: localized))
            case .unknown(let detail): .unknown(detail.string(localized: localized))
            }
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
        public enum Status: String, Sendable {
            case changed = "Changed"
            case untracked = "Untracked"
            case ignored = "Ignored"

            public var localizedLabel: String {
                let text: EngineText = switch self {
                case .changed: "Changed"
                case .untracked: "Untracked"
                case .ignored: "Ignored"
                }
                return text.localized
            }
        }
        public var path: String
        public var status: Status
        public var allocatedBytes: Int64 = 0
        public var regeneratesSafely: Bool?
        public var canRemoveWhenMerged = false
        /// The main checkout has a regular file with identical contents at the same path.
        public var hasMainCheckoutCopy = false
        public var id: String { path }
        public init(path: String, status: Status, allocatedBytes: Int64 = 0, regeneratesSafely: Bool? = nil) {
            self.path = path
            self.status = status
            self.allocatedBytes = allocatedBytes
            self.regeneratesSafely = regeneratesSafely
        }
    }

    var branchText: EngineText = "Branch unknown"
    public var branch: String {
        get { branchText.english }
        set { branchText = .verbatim(newValue) }
    }
    public var status: FileEntry.GitWorktreeStatus = .unavailable
    public var pushStatus: FileEntry.GitWorktreePushStatus = .unknown
    public var mergedInto: String?
    public var mergePullRequestNumber: Int?
    /// An open GitHub pull request whose head is the worktree commit. The merge is not complete.
    public var openPullRequestNumber: Int?
    var mergeIssueText: EngineText = "The merge was not checked."
    public var mergeIssue: String {
        get { mergeIssueText.english }
        set { mergeIssueText = .verbatim(newValue) }
    }
    public var localFiles: [File] = []
    public var ignoredFiles: [File] = []
    public var filesChecked = false
    var filesIssueText: EngineText = "Git file status was not checked."
    public var filesIssue: String {
        get { filesIssueText.english }
        set { filesIssueText = .verbatim(newValue) }
    }
    var ignoredFilesIssueText: EngineText = "Ignored files could not be read."
    public var ignoredFilesIssue: String {
        get { ignoredFilesIssueText.english }
        set { ignoredFilesIssueText = .verbatim(newValue) }
    }
    var pushIssueText: EngineText = "The remote comparison was not checked."
    public var pushIssue: String {
        get { pushIssueText.english }
        set { pushIssueText = .verbatim(newValue) }
    }
    public var lastFetchDate: Date?
    /// The Git metadata path that the `.git` file names when that path does not exist.
    public var missingGitData: String?
    var locksText: CheckText = .unknown("Git locks were not checked.")
    public var locks: Check {
        get { locksText.result(localized: false) }
        set { locksText = CheckText(newValue) }
    }
    public var localizedLocks: Check { locksText.result(localized: true) }
    var activityText: CheckText = .unknown("Open files and processes were not checked.")
    public var activity: Check {
        get { activityText.result(localized: false) }
        set { activityText = CheckText(newValue) }
    }
    public var localizedActivity: Check { activityText.result(localized: true) }
    var verifiedGeneratedProjects: Set<URL> = []
    /// The working folder of the main checkout. A bare repository has none.
    var mainCheckout: URL?
    var mergeCandidate: GitHubMergeVerifier.Candidate?

    public init() {}

    public var ignoredBytes: Int64 { ignoredFiles.reduce(0) { $0 + $1.allocatedBytes } }
    public var localizedBranch: String { branchText.localized }
    public var mergeCheck: Check { mergeCheckText.result(localized: false) }
    public var localizedMergeCheck: Check { mergeCheckText.result(localized: true) }
    private var mergeCheckText: CheckText { mergedInto == nil ? .unknown(mergeIssueText) : .clear }
    public var regenerableIgnoredFiles: [File] { ignoredFiles.filter { $0.regeneratesSafely == true } }
    public var localIgnoredFiles: [File] { ignoredFiles.filter { $0.regeneratesSafely == false && !$0.hasMainCheckoutCopy } }
    public var copiedIgnoredFiles: [File] { ignoredFiles.filter { $0.regeneratesSafely == false && $0.hasMainCheckoutCopy } }
    public var unverifiedIgnoredFiles: [File] { ignoredFiles.filter { $0.regeneratesSafely == nil } }
    public var unpushedCommitCount: Int? {
        switch pushStatus {
        case .unknown: nil
        case .noUnpushedCommits: 0
        case .unpushedCommits(let count): count
        }
    }
    public var localFilesCheck: Check { localFilesCheckText.result(localized: false) }
    public var localizedLocalFilesCheck: Check { localFilesCheckText.result(localized: true) }

    private var localFilesCheckText: CheckText {
        if !localFiles.isEmpty {
            let count = localFiles.count
            return .found(EngineText(english: "\(count) \(count == 1 ? "file" : "files")", display: "\(count) files"))
        }
        guard filesChecked, status != .unavailable else { return .unknown(filesIssueText) }
        return .clear
    }

    public var ignoredFilesCheck: Check { ignoredFilesCheckText.result(localized: false) }
    public var localizedIgnoredFilesCheck: Check { ignoredFilesCheckText.result(localized: true) }

    private var ignoredFilesCheckText: CheckText {
        let local = localIgnoredFiles.filter { !includesAfterMerge($0) }
        if !local.isEmpty { return .found(.verbatim(local.map(\.path).joined(separator: ", "))) }
        guard filesChecked, status != .unavailable else { return .unknown(filesIssueText) }
        guard ignoredFiles.allSatisfy({ $0.regeneratesSafely == true || $0.hasMainCheckoutCopy || includesAfterMerge($0) }) else {
            return .unknown(ignoredFilesIssueText)
        }
        return .clear
    }

    public func includesAfterMerge(_ file: File) -> Bool {
        mergedInto != nil && file.status == .ignored && file.canRemoveWhenMerged
    }

    public var pushCheck: Check { pushCheckText.result(localized: false) }
    public var localizedPushCheck: Check { pushCheckText.result(localized: true) }

    private var pushCheckText: CheckText {
        guard let count = unpushedCommitCount else { return .unknown(pushIssueText) }
        if count > 0 {
            return .found(EngineText(english: "\(count) \(count == 1 ? "commit" : "commits")", display: "\(count) commits"))
        }
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

    /// Stops counting main checkout copies that a removal also removes.
    public func ignoringCopies(within removed: [URL]) -> GitWorktreeReview {
        guard let mainCheckout else { return self }
        var review = self
        for index in review.ignoredFiles.indices where review.ignoredFiles[index].hasMainCheckoutCopy {
            let copy = mainCheckout.appendingPathComponent(review.ignoredFiles[index].path).standardizedFileURL.path
            if removed.contains(where: { copy == $0.standardizedFileURL.path || copy.hasPrefix($0.standardizedFileURL.path + "/") }) {
                review.ignoredFiles[index].hasMainCheckoutCopy = false
            }
        }
        return review
    }
    public var statusLabel: String { outcome.rawValue }
    public var localizedStatusLabel: String {
        let text: EngineText = switch outcome {
        case .inUse: "In use"
        case .uncommittedChanges: "Uncommitted changes"
        case .unpushedCommits: "Unpushed commits"
        case .hasLocalFiles: "Has local files"
        case .couldNotVerify: "Could not verify"
        case .safeToRemove: "Safe to remove"
        }
        return text.localized
    }

    enum CheckTool { case git, processes }

    static func failureReason(_ error: Error, tool: CheckTool) -> EngineText {
        if case ProcessError.timedOut = error {
            return tool == .git ? "Git timed out." : "The process check timed out."
        }
        if case ProcessError.executableMissing = error {
            return tool == .git ? "Git is not installed." : "The process check is not installed."
        }
        if case ProcessError.failed(_, _, let stderr) = error {
            let message = stderr.lowercased()
            if message.contains("permission denied") || message.contains("operation not permitted") {
                return "Permission to read these files was denied."
            }
        }
        if let error = error as? CocoaError, error.code == .fileReadNoPermission {
            return "Permission to read these files was denied."
        }
        return tool == .git ? "Git could not complete this check." : "The process check could not complete this check."
    }
}
