import Foundation

/// Signs that the project around a dependency store is still in use.
///
/// A lockfile shows that a store can come back. It does not show that removal costs
/// nothing. In a project that somebody changed this morning, removal stops a running
/// development server and causes a new download. So a store counts as safe only when
/// its project is idle for `idlePeriod`. Inside a repository, Git must also ignore it:
/// a store that Git does not ignore can hold committed files.
public struct ProjectActivity: Sendable, Equatable {

    public enum GitIgnoreState: String, Sendable, Equatable {
        /// The repository ignores the store.
        case ignored
        /// No ignore rule matches the store, or the repository tracks files in it.
        case notIgnored = "not_ignored"
        /// Git did not answer, or the project has a `.git` entry and the Mac has no Git.
        case unknown
        /// The project is not in a repository.
        case outsideRepository = "outside_repository"
    }

    /// Why the store does not count as safe. Removal stays available.
    public enum Hold: String, Sendable, Equatable {
        case recentActivity = "recent_activity"
        case notIgnoredByGit = "not_ignored_by_git"
        case unknown
    }

    /// A project with no sign of work for this period is idle.
    public static let idlePeriod: TimeInterval = 14 * 24 * 60 * 60

    public let gitIgnore: GitIgnoreState
    /// The newest sign of work: a commit, checkout, staged change, or changed file.
    public let lastActivity: Date?
    /// The scan sets this value, so the row does not change while you read it.
    public let hold: Hold?

    public init(gitIgnore: GitIgnoreState, lastActivity: Date?, now: Date) {
        self.gitIgnore = gitIgnore
        self.lastActivity = lastActivity
        hold = switch gitIgnore {
        case .notIgnored: .notIgnoredByGit
        case .unknown: .unknown
        case .ignored, .outsideRepository:
            if let lastActivity {
                now.timeIntervalSince(lastActivity) < Self.idlePeriod ? .recentActivity : nil
            } else {
                .unknown
            }
        }
    }

    /// The short text after the row path, in the style of `no lockfile`.
    public var caveat: String? {
        switch hold {
        case .recentActivity: "recent project changes"
        case .notIgnoredByGit: "Git does not ignore it"
        case .unknown: "project state unknown"
        case nil: nil
        }
    }

    /// The row help text and the command line detail.
    public var explanation: String? {
        let rule = "Moppo does not count it as safe to remove. You can still select it."
        return switch hold {
        case .recentActivity:
            (lastActivity.map { "The project changed on \($0.formatted(date: .abbreviated, time: .omitted)). " } ?? "")
                + "Moppo waits until the project has no changes for 14 days. " + rule
        case .notIgnoredByGit: "Git does not ignore this folder, or the repository tracks files in it. " + rule
        case .unknown: "Moppo could not read the state of this project. " + rule
        case nil: nil
        }
    }
}

/// Reads `ProjectActivity` for dependency stores.
///
/// Git runs once for each repository, not once for each store. The reader does not
/// call `/usr/bin/git`: on a Mac without the Command Line Tools, that file opens the
/// installer dialog. `GitWorktreeDetector.executable()` finds a real Git binary.
struct ProjectActivityReader: Sendable {

    /// The most changed paths that are read for dates.
    static let statusPathLimit = 200

    /// Read at each call. The standard scanners live as long as the app.
    private let clock: @Sendable () -> Date
    private let gitExecutable: @Sendable () async throws -> String?

    init(
        clock: @escaping @Sendable () -> Date = { Date() },
        gitExecutable: @escaping @Sendable () async throws -> String? = { try await GitWorktreeDetector.executable() }
    ) {
        self.clock = clock
        self.gitExecutable = gitExecutable
    }

    /// Activity for each store, by standardized path.
    ///
    /// - Parameters:
    ///   - stores: Dependency stores. The parent folder of each store is its project.
    ///   - root: The folder that the scan looks at. Git does not search above it, so a
    ///     repository in the home folder does not claim every project below it.
    func activities(for stores: [URL], within root: URL) async throws -> [String: ProjectActivity] {
        guard !stores.isEmpty else { return [:] }
        let now = clock()
        let root = root.standardizedFileURL
        let git = try await gitExecutable()
        var repositories: [String: Repository?] = [:]
        var storesByRepository: [String: [URL]] = [:]
        var result: [String: ProjectActivity] = [:]

        for store in stores.map(\.standardizedFileURL) {
            try Task.checkCancellation()
            let project = store.deletingLastPathComponent()
            guard let git else {
                // Without Git, a `.git` entry is the only sign of a repository.
                result[store.path] = Self.hasGitEntry(from: project, within: root)
                    ? ProjectActivity(gitIgnore: .unknown, lastActivity: nil, now: now)
                    : outsideRepository(project: project, store: store, now: now)
                continue
            }
            let repository: Repository?
            if let cached = repositories[project.path] {
                repository = cached
            } else {
                repository = try await Repository.locate(project, git: git, root: root)
                repositories[project.path] = repository
            }
            switch repository {
            case .none:
                result[store.path] = outsideRepository(project: project, store: store, now: now)
            case .some(.unavailable):
                result[store.path] = ProjectActivity(gitIgnore: .unknown, lastActivity: nil, now: now)
            case .some(.found(let topLevel, _)):
                storesByRepository[topLevel.path, default: []].append(store)
            }
        }

        let found = repositories.values.compactMap { repository -> (URL, URL)? in
            guard case .found(let topLevel, let gitDirectory)? = repository else { return nil }
            return (topLevel, gitDirectory)
        }
        var seen: Set<String> = []
        for (topLevel, gitDirectory) in found where seen.insert(topLevel.path).inserted {
            try Task.checkCancellation()
            guard let git, let stores = storesByRepository[topLevel.path] else { continue }
            let session = GitSession(git: git, topLevel: topLevel, root: root)
            let ignored = try await session.ignoredPaths(stores)
            let activity = try await session.lastActivity(gitDirectory: gitDirectory)
            for store in stores {
                guard let ignored, case .answered(let lastActivity) = activity else {
                    result[store.path] = ProjectActivity(gitIgnore: .unknown, lastActivity: nil, now: now)
                    continue
                }
                let state: ProjectActivity.GitIgnoreState = ignored.contains(session.relativePath(store))
                    ? .ignored : .notIgnored
                result[store.path] = ProjectActivity(gitIgnore: state, lastActivity: lastActivity, now: now)
            }
        }
        return result
    }

    // MARK: - Outside a repository

    /// The newest modification date among the items in the project folder, without the store.
    /// The manifest and the lockfile are in this folder.
    private func outsideRepository(project: URL, store: URL, now: Date) -> ProjectActivity {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: project, includingPropertiesForKeys: [.contentModificationDateKey], options: []
        )) ?? []
        let newest = items
            .filter { $0.standardizedFileURL.path != store.path }
            .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            .max()
        return ProjectActivity(gitIgnore: .outsideRepository, lastActivity: newest, now: now)
    }

    static func hasGitEntry(from project: URL, within root: URL) -> Bool {
        var directory = project.standardizedFileURL
        while directory.path.hasPrefix(root.path + "/") {
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) { return true }
            directory = directory.deletingLastPathComponent()
        }
        return false
    }

    // MARK: - Git

    enum Repository: Sendable {
        case found(topLevel: URL, gitDirectory: URL)
        /// A repository may exist, but Git did not answer.
        case unavailable

        /// Nil when the project is not in a repository below `root`.
        static func locate(_ project: URL, git: String, root: URL) async throws -> Repository? {
            let result = try await ProcessRunner().runResult(
                git, ["--no-optional-locks", "-C", project.path, "rev-parse", "--show-toplevel", "--absolute-git-dir"],
                timeout: .seconds(5), environment: GitSession.environment(root: root), allowsInput: false
            )
            guard result.completion == .exited else { return .unavailable }
            guard result.exitStatus == 0 else {
                // Exit status 128 is "not a git repository". Other failures are unknown.
                return result.exitStatus == 128 && result.standardError.contains("not a git repository")
                    ? nil : .unavailable
            }
            let lines = String(decoding: result.output, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map(String.init)
            guard lines.count == 2 else { return .unavailable }
            return .found(
                topLevel: URL(fileURLWithPath: lines[0], isDirectory: true).standardizedFileURL,
                gitDirectory: URL(fileURLWithPath: lines[1], isDirectory: true).standardizedFileURL
            )
        }
    }

    struct GitSession: Sendable {
        let git: String
        let topLevel: URL
        let root: URL

        static func environment(root: URL) -> [String: String] {
            [
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
                // Git does not look for a repository in or above the scan folder.
                "GIT_CEILING_DIRECTORIES": root.path
            ]
        }

        /// Nil when Git did not finish in time.
        private func run(_ arguments: [String]) async throws -> ProcessResult? {
            let result = try await ProcessRunner().runResult(
                git, ["--no-optional-locks", "-c", "core.quotePath=false", "-C", topLevel.path] + arguments,
                timeout: .seconds(10), environment: Self.environment(root: root), allowsInput: false
            )
            return result.completion == .exited ? result : nil
        }

        /// The path that Git uses for `url`. Git prints resolved paths, such as
        /// `/private/var` for `/var`, so this function resolves both sides first.
        func relativePath(_ url: URL) -> String {
            let path = url.resolvingSymlinksInPath().path
            let top = topLevel.resolvingSymlinksInPath().path
            return path.hasPrefix(top + "/") ? String(path.dropFirst(top.count + 1)) : path
        }

        /// The stores that Git ignores, as relative paths. Nil when Git did not answer.
        ///
        /// Without `--no-index`, Git does not report a folder whose files it tracks.
        /// Git quotes a path with a newline or a quotation mark even with
        /// `core.quotePath=false`. Such a path does not match, so its store counts as
        /// not ignored. That result is safe: the store is only kept out of Safe to Remove.
        func ignoredPaths(_ stores: [URL]) async throws -> Set<String>? {
            guard let result = try await run(["check-ignore", "--"] + stores.map(relativePath)) else { return nil }
            switch result.exitStatus {
            case 0: return Set(String(decoding: result.output, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map(String.init))
            case 1: return []
            default: return nil
            }
        }

        enum Activity: Sendable, Equatable {
            case unanswered
            case answered(Date?)
        }

        /// The newest of the reflog, the index, and the files with uncommitted changes.
        func lastActivity(gitDirectory: URL) async throws -> Activity {
            var dates: [Date] = []
            // Git writes `logs/HEAD` at each commit, checkout, pull, and reset. Its file
            // date is the time of the last entry. `git reflog --format=%ct` prints the
            // commit date instead, which is old after a checkout of an old branch.
            for name in ["logs/HEAD", "index"] {
                let url = gitDirectory.appendingPathComponent(name)
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    dates.append(date)
                }
            }
            guard let status = try await run([
                "status", "--porcelain=v1", "-z", "--untracked-files=normal", "--ignore-submodules=all"
            ]), status.exitStatus == 0 else { return .unanswered }
            for path in Self.changedPaths(status.output).prefix(ProjectActivityReader.statusPathLimit) {
                let url = topLevel.appendingPathComponent(path)
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    dates.append(date)
                }
            }
            return .answered(dates.max())
        }

        static func fields(_ data: Data) -> [String] {
            data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        }

        /// Paths from `git status --porcelain=v1 -z`. After a rename or copy entry, Git
        /// writes the old path. That path no longer exists, so this function skips it.
        static func changedPaths(_ data: Data) -> [String] {
            var paths: [String] = []
            var fields = Self.fields(data)[...]
            while let field = fields.popFirst() {
                guard field.count > 3 else { continue }
                let status = field.prefix(2)
                paths.append(String(field.dropFirst(3)))
                if status.contains("R") || status.contains("C") { _ = fields.popFirst() }
            }
            return paths
        }
    }
}
