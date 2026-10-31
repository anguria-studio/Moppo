import Foundation
import Testing
@testable import MoppoCore

/// A lockfile shows that a dependency store can come back. These tests check the
/// second question: whether the project is idle, and whether Git ignores the store.
@Suite("Project activity")
struct ProjectActivityTests {

    private final class Sandbox {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("moppo-activity-\(UUID().uuidString)", isDirectory: true)

        init() throws {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 4_096) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        /// A Node project with a lockfile and a store large enough to get its own row.
        @discardableResult
        func project(_ relative: String) throws -> URL {
            try file("\(relative)/src/index.js", bytes: 2 * 1024 * 1024)
            try file("\(relative)/package-lock.json")
            try file("\(relative)/node_modules/dep/blob", bytes: 12 * 1024 * 1024)
            return home.appendingPathComponent(relative)
        }

        /// Commits the project. `ignoresStore` writes a `.gitignore` for `node_modules/`.
        func commit(_ project: URL, ignoresStore: Bool = true) throws {
            if ignoresStore {
                try Data("node_modules/\n".utf8).write(to: project.appendingPathComponent(".gitignore"))
            }
            try runGit(["init", "-q", project.path])
            try runGit(["-C", project.path, "add", "."])
            try runGit(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                        "commit", "-q", "-m", "Test"])
        }

        func setDate(_ date: Date, of url: URL) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }

        func store(in result: ScanCategoryResult, project: String) throws -> FileEntry {
            let row = try #require(result.entries.first { $0.url.lastPathComponent == project })
            return try #require(row.children.first { $0.url.lastPathComponent == "node_modules" })
        }
    }

    private static let day: TimeInterval = 24 * 60 * 60

    @Test("the hold follows the Git ignore state and the project date", arguments: [
        (ProjectActivity.GitIgnoreState.ignored, 20.0, ProjectActivity.Hold?.none),
        (.ignored, 2.0, .recentActivity),
        (.outsideRepository, 20.0, nil),
        (.outsideRepository, 2.0, .recentActivity),
        (.notIgnored, 20.0, .notIgnoredByGit),
        (.unknown, 20.0, .unknown),
    ])
    func holdRules(state: ProjectActivity.GitIgnoreState, daysIdle: Double, hold: ProjectActivity.Hold?) {
        let now = Date()
        let activity = ProjectActivity(gitIgnore: state, lastActivity: now.addingTimeInterval(-daysIdle * Self.day), now: now)
        #expect(activity.hold == hold)
        #expect((activity.caveat == nil) == (hold == nil))
    }

    @Test("a project with no date is unknown, not idle")
    func missingDateIsUnknown() {
        #expect(ProjectActivity(gitIgnore: .ignored, lastActivity: nil, now: Date()).hold == .unknown)
    }

    @Test("outside a repository, a recent project keeps its store out of Safe to Remove")
    func recentProjectOutsideRepository() async throws {
        let sandbox = try Sandbox()
        try sandbox.project("Documents/web")

        let recent = try await DocumentsFilesScanner(home: sandbox.home).scan(context: ScanContext())
        let store = try sandbox.store(in: recent, project: "web")
        #expect(store.isRegenerable, "the lockfile still shows that it can come back")
        #expect(!store.regeneratesSafely)
        #expect(store.projectActivity?.gitIgnore == .outsideRepository)
        #expect(store.safetyCaveat == "recent project changes")
        #expect(!store.isRemovalLocked, "the user can still select it")
        #expect(recent.safeToRemoveBytes == 0)
        #expect(recent.tileRows(safeToRemove: true).isEmpty)

        let idle = try await DocumentsFilesScanner.afterIdlePeriod(home: sandbox.home, readsGit: true).scan(context: ScanContext())
        let idleStore = try sandbox.store(in: idle, project: "web")
        #expect(idleStore.regeneratesSafely)
        #expect(idleStore.safetyCaveat == nil)
        #expect(idle.tileRows(safeToRemove: true).map(\.url) == [idleStore.url])
    }

    @Test("in a repository, an ignored store waits until the project is idle")
    func ignoredStoreInRepository() async throws {
        let sandbox = try Sandbox()
        try sandbox.commit(try sandbox.project("Documents/app"))

        let recent = try await DocumentsFilesScanner(home: sandbox.home).scan(context: ScanContext())
        let store = try sandbox.store(in: recent, project: "app")
        #expect(store.projectActivity?.gitIgnore == .ignored)
        #expect(store.projectActivity?.hold == .recentActivity)
        #expect(!store.regeneratesSafely)

        let idle = try await DocumentsFilesScanner.afterIdlePeriod(home: sandbox.home, readsGit: true).scan(context: ScanContext())
        #expect(try sandbox.store(in: idle, project: "app").regeneratesSafely)
    }

    @Test("a store that Git does not ignore, or whose files Git tracks, is never safe")
    func storeThatGitDoesNotIgnore() async throws {
        let sandbox = try Sandbox()
        try sandbox.commit(try sandbox.project("Documents/plain"), ignoresStore: false)
        let tracked = try sandbox.project("Documents/vendored")
        try sandbox.commit(tracked)
        try runGit(["-C", tracked.path, "add", "-f", "node_modules"])
        try runGit(["-C", tracked.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                    "commit", "-q", "-m", "Vendor"])

        let result = try await DocumentsFilesScanner.afterIdlePeriod(home: sandbox.home, readsGit: true).scan(context: ScanContext())
        for project in ["plain", "vendored"] {
            let store = try sandbox.store(in: result, project: project)
            #expect(store.projectActivity?.gitIgnore == .notIgnored, "\(project)")
            #expect(store.safetyCaveat == "Git does not ignore it", "\(project)")
            #expect(!store.regeneratesSafely, "\(project)")
        }
    }

    /// An old commit does not make a project idle while somebody edits its files.
    @Test("uncommitted changes count as project activity")
    func uncommittedChanges() async throws {
        let sandbox = try Sandbox()
        let project = try sandbox.project("Documents/edited")
        try sandbox.commit(project)
        let old = Date().addingTimeInterval(-60 * Self.day)
        let gitDirectory = project.appendingPathComponent(".git")
        for name in ["logs/HEAD", "index"] {
            try sandbox.setDate(old, of: gitDirectory.appendingPathComponent(name))
        }

        let quiet = try await DocumentsFilesScanner(home: sandbox.home).scan(context: ScanContext())
        #expect(try sandbox.store(in: quiet, project: "edited").regeneratesSafely)

        try Data("changed".utf8).write(to: project.appendingPathComponent("src/index.js"))
        let edited = try await DocumentsFilesScanner(home: sandbox.home).scan(context: ScanContext())
        let store = try sandbox.store(in: edited, project: "edited")
        #expect(store.projectActivity?.hold == .recentActivity)
        #expect(!store.regeneratesSafely)
    }

    /// A repository in the home folder does not claim every project below it.
    @Test("Git does not look for a repository above the scan folder")
    func repositoryAboveScanFolder() async throws {
        let sandbox = try Sandbox()
        try sandbox.project("Documents/loose")
        try runGit(["init", "-q", sandbox.home.path])

        let result = try await DocumentsFilesScanner.afterIdlePeriod(home: sandbox.home, readsGit: true).scan(context: ScanContext())
        let store = try sandbox.store(in: result, project: "loose")
        #expect(store.projectActivity?.gitIgnore == .outsideRepository)
        #expect(store.regeneratesSafely)
    }

    @Test("without Git, a project with a .git entry is unknown and a plain project uses file dates")
    func noGitBinary() async throws {
        let sandbox = try Sandbox()
        let repository = try sandbox.project("Documents/repo")
        try FileManager.default.createDirectory(at: repository.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try sandbox.project("Documents/plain")
        let reader = ProjectActivityReader(
            clock: { Date().addingTimeInterval(ProjectActivity.idlePeriod + Self.day) },
            gitExecutable: { nil }
        )

        let result = try await DocumentsFilesScanner(home: sandbox.home, projectActivity: reader).scan(context: ScanContext())
        let unknown = try sandbox.store(in: result, project: "repo")
        #expect(unknown.projectActivity?.hold == .unknown)
        #expect(!unknown.regeneratesSafely)
        let plain = try sandbox.store(in: result, project: "plain")
        #expect(plain.projectActivity?.gitIgnore == .outsideRepository)
        #expect(plain.regeneratesSafely)
    }

    @Test("rename entries in git status give the new path only")
    func changedPathsSkipOldRenamePaths() {
        let output = Data(" M src/a.js\0R  new.js\0old.js\0?? notes/\0".utf8)
        #expect(ProjectActivityReader.GitSession.changedPaths(output) == ["src/a.js", "new.js", "notes/"])
    }
}
