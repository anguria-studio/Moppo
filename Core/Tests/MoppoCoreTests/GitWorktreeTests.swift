import Foundation
import Testing
@testable import MoppoCore

@Suite("Git worktrees")
struct GitWorktreeTests {
    private final class Sandbox {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("moppo-worktrees-\(UUID().uuidString)", isDirectory: true)

        init() throws {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        func file(_ path: String, text: String) throws {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }

        func git(_ arguments: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        func repository() throws -> URL {
            let repo = home.appendingPathComponent("Documents/Project", isDirectory: true)
            try file("Documents/Project/source.txt", text: String(repeating: "source\n", count: 200_000))
            try git(["init", repo.path])
            try git(["-C", repo.path, "add", "source.txt"])
            try git(["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Test"])
            return repo
        }

        func worktree(_ path: String, repository: URL) throws -> URL {
            let url = home.appendingPathComponent(path, isDirectory: true)
            try git(["-C", repository.path, "worktree", "add", "--detach", url.path])
            return url
        }
    }

    @Test("Project and AI folders show real worktrees without counting bytes twice")
    func scannerIntegration() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let projectTree = try sandbox.worktree("Documents/Project/.claude/worktrees/task", repository: repo)
        let codexTree = try sandbox.worktree(".codex/worktrees/abcd/Project", repository: repo)
        let claudeTree = try sandbox.worktree(".claude/worktrees/task", repository: repo)
        _ = try sandbox.worktree("Projects/task", repository: repo)
        try sandbox.file("Documents/Project/.claude/worktrees/task/.build/workspace-state.json", text: "{}")
        let context = ScanContext()
        let documents = try await DocumentsFilesScanner(home: sandbox.home).scan(context: context)
        let project = try #require(documents.entries.first { $0.url.path.hasSuffix("/Documents/Project") })
        let child = try #require(project.children.first { $0.url.path.hasSuffix("/Documents/Project/.claude/worktrees/task") })
        #expect(child.parentDisplay.contains("Git worktree"))
        #expect(!child.regeneratesSafely)
        #expect(child.safetyCaveat != nil)
        #expect(child.gitWorktreeReview?.status == .uncommittedChanges)
        let fullSize = try await context.measurer.measure(repo)
        #expect(project.displayBytes == fullSize.allocatedBytes)
        #expect(BuildOutputDetector.roots(under: projectTree).isEmpty)
        let standalone = try #require(documents.entries.first { $0.url.path.hasSuffix("/Projects/task") })
        #expect(standalone.parentDisplay.contains("Git worktree"))
        #expect(!standalone.isRegenerable)
        #expect(standalone.gitWorktreeReview?.status == .clean)
        #expect(standalone.gitWorktreeReview?.pushStatus == .unknown)

        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        for tree in [codexTree, claudeTree] {
            let parent = try #require(ai.entries.first { $0.children.contains { $0.url.path.hasSuffix(String(tree.path.dropFirst(sandbox.home.path.count))) } })
            let measurement = try await context.measurer.measure(parent.url)
            #expect(parent.displayBytes == measurement.allocatedBytes)
            #expect(parent.children.allSatisfy { !$0.regeneratesSafely })
        }
        #expect(ai.totalBytes == ai.entries.reduce(0) { $0 + $1.displayBytes })
    }

    @Test("Git status detects untracked, unstaged, staged, and deleted files")
    func worktreeStatus() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/task", repository: repo)
        #expect((try await GitWorktreeReviewService().review(tree)).status == .clean)

        try sandbox.file("Worktrees/task/new.swift", text: "// Test file\n")
        #expect((try await GitWorktreeReviewService().review(tree)).status == .uncommittedChanges)
        try FileManager.default.removeItem(at: tree.appendingPathComponent("new.swift"))
        #expect((try await GitWorktreeReviewService().review(tree)).status == .clean)

        try sandbox.file("Worktrees/task/source.txt", text: "Changed source\n")
        #expect((try await GitWorktreeReviewService().review(tree)).status == .uncommittedChanges)
        try sandbox.git(["-C", tree.path, "add", "source.txt"])
        #expect((try await GitWorktreeReviewService().review(tree)).status == .uncommittedChanges)
        try sandbox.git(["-C", tree.path, "restore", "--staged", "--worktree", "source.txt"])
        #expect((try await GitWorktreeReviewService().review(tree)).status == .clean)
        try FileManager.default.removeItem(at: tree.appendingPathComponent("source.txt"))
        #expect((try await GitWorktreeReviewService().review(tree)).status == .uncommittedChanges)
    }

    @Test("Ignored files do not produce a changes badge, and failed checks remain unknown")
    func ignoredAndUnavailableStatus() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/task", repository: repo)
        try sandbox.file("Documents/Project/.git/info/exclude", text: "ignored-demo.bin\n")
        try sandbox.file("Worktrees/task/ignored-demo.bin", text: "Test data")
        #expect((try await GitWorktreeReviewService().review(tree)).status == .clean)
        try sandbox.file("Stale/.git", text: "gitdir: /missing/.git/worktrees/task\n")
        #expect((try await GitWorktreeReviewService().review(sandbox.home.appendingPathComponent("Stale"))).status == .unavailable)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return (try await GitWorktreeReviewService().review(tree)).status
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled status check completed")
        } catch is CancellationError {
        }
    }

    @Test("Push checks handle detached worktrees and the configured upstream")
    func unpushedCommits() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/task", repository: repo)
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .unknown)
        try sandbox.git(["-C", repo.path, "remote", "add", "origin", sandbox.home.appendingPathComponent("remote.git").path])
        try sandbox.git(["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .noUnpushedCommits)

        try sandbox.file("Worktrees/task/source.txt", text: "Committed change\n")
        try sandbox.git(["-C", tree.path, "add", "source.txt"])
        try sandbox.git(["-C", tree.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Local change"])
        #expect((try await GitWorktreeReviewService().review(tree)).status == .clean)
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .unpushedCommits(1))
        try sandbox.file("Worktrees/task/untracked.swift", text: "// Local changes\n")
        #expect((try await GitWorktreeReviewService().review(tree)).status == .uncommittedChanges)
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .unpushedCommits(1))

        try sandbox.git(["-C", tree.path, "update-ref", "refs/remotes/origin/other", "HEAD"])
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .noUnpushedCommits)
        try sandbox.git(["-C", tree.path, "switch", "-c", "task-branch"])
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .unknown)
        try sandbox.git(["-C", tree.path, "branch", "--set-upstream-to=origin/main"])
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .unpushedCommits(1))
        try sandbox.git(["-C", tree.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .noUnpushedCommits)
        try sandbox.git(["-C", tree.path, "update-ref", "-d", "refs/remotes/origin/main"])
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .unknown)
    }

    @Test("Incomplete history and failed push checks remain unknown")
    func unknownPushStatus() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/task", repository: repo)
        try sandbox.git(["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        let head = try await ProcessRunner().run("/usr/bin/git", ["-C", repo.path, "rev-parse", "HEAD"])
        try head.write(to: repo.appendingPathComponent(".git/shallow"))
        #expect((try await GitWorktreeDetector.pushStatus(of: tree)).status == .unknown)
        #expect((try await GitWorktreeDetector.pushStatus(of: sandbox.home.appendingPathComponent("missing"))).status == .unknown)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return (try await GitWorktreeDetector.pushStatus(of: tree)).status
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled push check completed")
        } catch is CancellationError {
        }
    }

    @Test("Relative and stale worktree markers differ from submodules and ordinary repositories")
    func markerShapes() throws {
        let sandbox = try Sandbox()
        try sandbox.file("Project/.worktrees/task/.git", text: "gitdir: ../../.git/worktrees/task\n")
        try sandbox.file("Project/module/.git", text: "gitdir: ../.git/modules/module\n")
        try sandbox.file("Project/ordinary/.git/config", text: "[core]\n")
        try sandbox.file("Project/decoy/.git", text: "not a git marker")
        let root = sandbox.home.appendingPathComponent("Project")
        let found = try GitWorktreeDetector.roots(under: root, context: ScanContext())
        #expect(found.map(\.lastPathComponent) == ["task"])
    }

    @Test("Discovery respects exclusions, symbolic links, and cancellation")
    func discoveryGuards() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Project/.worktrees/task/.git", text: "gitdir: /missing/.git/worktrees/task\n")
        let root = sandbox.home.appendingPathComponent("Project")
        let tree = root.appendingPathComponent(".worktrees/task")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: tree)
        #expect(try GitWorktreeDetector.roots(under: root, context: ScanContext()).count == 1)
        #expect(try GitWorktreeDetector.roots(under: root, context: ScanContext(excludedPaths: [tree.path])).isEmpty)
        #expect(try GitWorktreeDetector.roots(under: root, context: ScanContext(excludedPatterns: [".worktrees"])).isEmpty)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GitWorktreeDetector.roots(under: root, context: ScanContext())
        }
        do {
            _ = try await task.value
            Issue.record("Cancelled discovery completed")
        } catch is CancellationError {
        }
    }

    @Test("Review separates local work from ignored data and checks Git locks")
    func reviewFilesAndLocks() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/review", repository: repo)
        try sandbox.git(["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        try sandbox.file("Documents/Project/.git/info/exclude", text: ".env\n.build/\n")
        try sandbox.file("Documents/Project/.git/FETCH_HEAD", text: "Fetched fixture\n")
        let fetchDate = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: fetchDate],
            ofItemAtPath: repo.appendingPathComponent(".git/FETCH_HEAD").path)
        try sandbox.file("Worktrees/review/.env", text: "Local configuration")
        try sandbox.file("Worktrees/review/.build/workspace-state.json", text: "{}")
        try sandbox.file("Worktrees/review/notes.txt", text: "Local notes")
        let review = try await GitWorktreeReviewService().review(tree)
        #expect(review.statusLabel == "Uncommitted changes")
        #expect(review.localFiles.map(\.path) == ["notes.txt"])
        #expect(review.ignoredFiles.map(\.path) == [".build/", ".env"])
        #expect(review.ignoredFiles.first?.regeneratesSafely == true)
        #expect(review.ignoredFiles.last?.regeneratesSafely == false)
        #expect(review.ignoredBytes > 0)
        #expect(review.filesChecked)
        let lastFetch = try #require(review.lastFetchDate)
        #expect(abs(lastFetch.timeIntervalSince(fetchDate)) < 1)
        #expect(review.locks == .clear)
        #expect(!review.isSafeToRemove)

        try sandbox.git(["-C", repo.path, "worktree", "lock", tree.path])
        let locked = try await GitWorktreeReviewService().review(tree)
        #expect(locked.locks == .found("locked"))
        #expect(!locked.isSafeToRemove)
        #expect(locked.outcome == .inUse)
    }

    @Test("A green verdict requires complete checks and regenerable ignored files")
    func safeVerdict() {
        var review = GitWorktreeReview()
        review.status = .clean
        review.pushStatus = .noUnpushedCommits
        review.filesChecked = true
        review.locks = .clear
        review.activity = .clear
        #expect(review.isSafeToRemove)
        #expect(review.statusLabel == "Safe to remove")
        review.ignoredFiles = [.init(path: ".env", status: .ignored, allocatedBytes: 4096, regeneratesSafely: false)]
        #expect(!review.isSafeToRemove)
        #expect(review.outcome == .hasLocalFiles)
        review.pushStatus = .unknown
        #expect(review.outcome == .hasLocalFiles)
        review.pushStatus = .noUnpushedCommits
        review.ignoredFiles = []
        review.lastFetchDate = Date().addingTimeInterval(-90 * 24 * 60 * 60)
        #expect(review.isSafeToRemove)
        review.lastFetchDate = nil
        #expect(review.isSafeToRemove)
        review.activity = .unknown("Process check failed.")
        #expect(!review.isSafeToRemove)
        review.activity = .clear
        review.pushStatus = .unknown
        #expect(review.statusLabel == "Couldn't verify")
        #expect(!review.isSafeToRemove)
        review.pushStatus = .unpushedCommits(1)
        #expect(review.statusLabel == "Unpushed commits")
        review.status = .uncommittedChanges
        #expect(review.statusLabel == "Uncommitted changes")
        review.locks = .found("index.lock")
        #expect(review.outcome == .inUse)
        review.locks = .clear
        review.activity = .found("Codex, node")
        #expect(review.outcome == .inUse)
    }

    @Test("Unavailable Git leaves the review unknown without running Git")
    func unavailableGit() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Worktree/.git", text: "gitdir: /missing/.git/worktrees/task\n")
        let review = try await GitWorktreeReviewService(gitExecutable: { nil })
            .review(sandbox.home.appendingPathComponent("Worktree"))
        #expect(review.status == .unavailable)
        #expect(review.pushStatus == .unknown)
        #expect(!review.filesChecked)
        #expect(!review.isSafeToRemove)
    }

    @Test("Status parsing handles renames, unusual names, and invalid paths")
    func reviewParsing() {
        let directory = URL(fileURLWithPath: "/fixture")
        let data = Data("R  new name\0old name\0?? line\nbreak.txt\0!! .env\0?? ../outside\0".utf8)
        let files = GitWorktreeReviewService.files(in: data, directory: directory)
        #expect(files.local.map(\.path) == ["line\nbreak.txt", "new name"])
        #expect(files.ignored.map(\.path) == [".env"])
        #expect(!files.complete)
    }

    @Test("Git-managed Trash and Put Back preserve local work and registration")
    func managedTrashAndPutBack() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let tree = try sandbox.worktree("Worktrees/recovery", repository: repo)
        try sandbox.file("Worktrees/recovery/notes.txt", text: "Keep these notes")
        let trash = sandbox.home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let landed = trash.appendingPathComponent("recovery")
        #expect(try await GitWorktreeDetector.move(tree, to: landed))
        #expect((try await GitWorktreeReviewService().review(landed)).status == .uncommittedChanges)
        let log = RemovalLog(directory: sandbox.home.appendingPathComponent("receipts"))
        try log.append([RemovalRecord(timestamp: Date(), originalPath: tree.path, bytes: 4096,
            disposition: .trashed, trashedPath: landed.path, trashedIdentity: FileIdentity.of(landed))])
        let service = TrashService(home: sandbox.home, log: log)
        let item = try #require(try await service.summary().items.first)
        #expect(item.canPutBack)
        try await service.putBack(item)
        #expect(try String(contentsOf: tree.appendingPathComponent("notes.txt"), encoding: .utf8) == "Keep these notes")
        #expect((try await GitWorktreeReviewService().review(tree)).status == .uncommittedChanges)
        #expect(!FileManager.default.fileExists(atPath: landed.path))
    }
}
