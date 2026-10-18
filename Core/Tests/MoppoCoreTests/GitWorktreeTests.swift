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

        func nextProject(_ path: String, development: Bool = false) throws {
            try file(path + "/package.json", text: #"{"dependencies":{"next":"16.2.4"}}"#)
            try file(path + "/tsconfig.json", text: #"{"compilerOptions":{"incremental":true}}"#)
            try file(path + "/tsconfig.tsbuildinfo", text: #"{"fileNames":["./page.ts"],"fileInfos":["hash"],"version":"5.9.3"}"#)
            try file(path + "/next-env.d.ts", text: """
                /// <reference types="next" />
                /// <reference types="next/image-types/global" />
                import "./.next/types/routes.d.ts";

                // NOTE: This file should not be edited
                // see https://nextjs.org/docs/app/api-reference/config/typescript for more information.
                """)
            let output = path + (development ? "/.next/dev" : "/.next")
            try file(output + "/package.json", text: #"{"type":"commonjs"}"#)
            try file(output + "/build-manifest.json", text: #"{"pages":{"/page":["page.js"]},"rootMainFiles":["main.js"]}"#)
            try file(output + "/server/pages/page.js", text: "Generated page")
        }

        func plist(_ path: String, object: [String: Any]) throws {
            try file(path, text: "")
            try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0)
                .write(to: home.appendingPathComponent(path))
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
        try sandbox.file("Documents/Small/.hidden/task/.git", text: "gitdir: /missing/.git/worktrees/task\n")
        try sandbox.file("Documents/Small/.hidden/task/tiny.txt", text: "Local work")
        let context = ScanContext()
        let log = try ScanDiagnostics(directory: sandbox.home.appendingPathComponent("logs"))
        let documents = try await ScanDiagnostics.$current.withValue(log.context) {
            let results = try await ScanCoordinator(scanners: [DocumentsFilesScanner(home: sandbox.home)]).scan(context: context)
            return try #require(results.categories.first)
        }
        log.finish(outcome: "completed")
        log.flush()
        let events = try Data(contentsOf: log.fileURL).split(separator: 10).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let completed = events.filter { $0["event"] as? String == "span_end" }
            .compactMap { $0["details"] as? [String: String] }
        #expect(completed.filter { $0["operation"]?.hasPrefix("measure_") == true }.count == 3)
        let processChecks = completed.filter { $0["operation"] == "process" && $0["path"] == "/usr/sbin/lsof" }
        #expect(processChecks.count == 3)
        #expect(processChecks.allSatisfy { $0["arguments"]?.contains("+D") == false })
        let project = try #require(documents.entries.first { $0.url.path.hasSuffix("/Documents/Project") })
        let child = try #require(project.children.first { $0.url.path.hasSuffix("/Documents/Project/.claude/worktrees/task") })
        #expect(child.parentDisplay.contains("Git worktree"))
        #expect(project.worktreeCount == 1)
        let small = try #require(documents.filteringNoise(below: 1_048_576).entries.first { $0.url.lastPathComponent == "Small" })
        #expect(small.worktreeCount == 1)
        #expect(small.totalBytesIncludingChildren < 1_048_576)
        let shown = events.filter { $0["event"] as? String == "worktree_row" }
            .compactMap { $0["details"] as? [String: String] }
        #expect(shown.filter { $0["outcome"] == "shown" }.count == 3)
        let visible = events.filter { $0["event"] as? String == "worktree_visible_row" }
            .compactMap { $0["details"] as? [String: String] }
        #expect(Set(visible.compactMap { $0["path"] }) == Set((documents.entries + documents.entries.flatMap(\.children))
            .filter(\.isGitWorktree).map { $0.url.path }))
        let zero = try await GitWorktreeDetector.addingWorktrees(to: FileEntry(url: repo, kind: .folder, allocatedBytes: 0),
            context: context, prepared: WorktreeScan.Result(roots: [projectTree],
                measurements: [projectTree.standardizedFileURL: .zero], reviews: [:]))
        #expect(zero.worktreeCount == 1)
        #expect(zero.displayBytes == 0)
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

        let aiLog = try ScanDiagnostics(directory: sandbox.home.appendingPathComponent("ai-logs"))
        let ai = try await ScanDiagnostics.$current.withValue(aiLog.context) {
            try await AIToolsScanner(home: sandbox.home).scan(context: context)
        }
        aiLog.finish(outcome: "completed")
        aiLog.flush()
        let aiSpans = try Data(contentsOf: aiLog.fileURL).split(separator: 10).compactMap { line -> [String: String]? in
            let event = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            return event["event"] as? String == "span_end" ? event["details"] as? [String: String] : nil
        }
        let aiProcessChecks = aiSpans.filter { $0["operation"] == "process" && $0["path"] == "/usr/sbin/lsof" }
        #expect(aiProcessChecks.count == 2)
        #expect(aiProcessChecks.allSatisfy { $0["arguments"]?.contains("+D") == false })
        #expect(!aiSpans.contains { $0["operation"] == "worktree_review" })
        for tree in [codexTree, claudeTree] {
            let parent = try #require(ai.entries.first { $0.children.contains { $0.url.path.hasSuffix(String(tree.path.dropFirst(sandbox.home.path.count))) } })
            let measurement = try await context.measurer.measure(parent.url)
            #expect(parent.displayBytes == measurement.allocatedBytes)
            #expect(parent.children.allSatisfy { !$0.regeneratesSafely })
        }
        #expect(ai.totalBytes == ai.entries.reduce(0) { $0 + $1.displayBytes })
    }

    @Test("Worktrees inside AI groups remain visible with their storage protection")
    func groupedAIWorktrees() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let first = try sandbox.worktree(".codex/cache/first", repository: repo)
        let second = try sandbox.worktree(".codex/cache/nested/second", repository: repo)
        let exact = try sandbox.worktree(".codex/plugins", repository: repo)
        try sandbox.file(".codex/cache/other.txt", text: "Keep these files")
        let context = ScanContext()
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        let parent = try #require(ai.entries.first { $0.url.lastPathComponent == ".codex" })
        let rows = CleanupDataType.worktrees.rows(in: ai.entries)
        #expect(Set(rows.map { $0.url.path }) == Set([first.path, second.path, exact.path]))
        #expect(parent.worktreeCount == 3)
        #expect(parent.children.count == 4)
        #expect(parent.displayBytes == (try await context.measurer.measure(parent.url)).allocatedBytes)
        #expect(ai.totalBytes == parent.displayBytes)
        #expect(ai.safeToRemoveBytes == 0)
        for row in rows {
            #expect(row.allocatedBytes == (try await context.measurer.measure(row.url)).allocatedBytes)
            #expect(row.protectionReason == .inventory)
            #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
            #expect(row.gitWorktreeReview?.status == .clean)
        }
        let remainder = try #require(parent.children.first { $0.url.lastPathComponent == "cache" })
        #expect(remainder.displayName == "Codex other cache files · Other files")
        #expect(remainder.allocatedBytes == (try await context.measurer.measure(remainder.url)).allocatedBytes
            - rows.filter { $0.url.path != exact.path }.reduce(0) { $0 + $1.allocatedBytes })
        #expect(remainder.protectionReason == .inventory)
        #expect(!CleanupService.removalAllowed(parent, userDataRemovalOverrides: [parent.id]))
        #expect(parent.children.first { $0.url.path == exact.path }?.displayName == "Codex plugins")
    }

    @Test("Cache grouping cannot hide worktrees or make their containing folders safe")
    func groupedCacheWorktrees() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let grouped = try sandbox.worktree("Documents/Project/.mypy_cache/task", repository: repo)
        try sandbox.file("Documents/Project/.mypy_cache/CACHEDIR.TAG", text: CacheDirectoryTag.signature)
        let nested = try sandbox.worktree("Documents/build/task", repository: repo)
        let context = ScanContext()
        let documents = try await DocumentsFilesScanner(home: sandbox.home).scan(context: context)
        let rows = CleanupDataType.worktrees.rows(in: documents.entries)
        #expect(Set(rows.map { $0.url.path }) == Set([grouped.path, nested.path]))
        for parent in documents.entries {
            #expect(parent.worktreeCount == 1)
            #expect(!parent.regeneratesSafely)
            #expect(parent.kind == .folder)
            #expect(parent.displayBytes == (try await context.measurer.measure(parent.url)).allocatedBytes)
        }
        let project = try #require(documents.entries.first { $0.url.lastPathComponent == "Project" },
            "Expected \(repo.path), found \(documents.entries.map { $0.url.path })")
        let remainder = try #require(project.children.first { $0.url.lastPathComponent == ".mypy_cache" })
        #expect(remainder.protectionReason == .folderRemainder)
        #expect(!remainder.regeneratesSafely)
        #expect(!CleanupService.removalAllowed(remainder, userDataRemovalOverrides: [remainder.id]))
        #expect(!project.isRemovalLocked)
        #expect(CleanupService.removalAllowed(project, userDataRemovalOverrides: []))
        #expect(project.reclaimableBytes == project.totalBytesIncludingChildren)
        let targets = CleanupService.removalTargets(for: project, removeProtectedAppData: false)
        #expect(targets.map(\.url.path) == [grouped.path, project.url.path])
        #expect(targets.reduce(0) { $0 + $1.allocatedBytes } == project.displayBytes)
        #expect(rows.allSatisfy { $0.gitWorktreeReview?.status == .clean && !$0.isRemovalLocked })
        #expect(documents.totalBytes == (try await context.measurer.measure(sandbox.home.appendingPathComponent("Documents"))).allocatedBytes)
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

    @Test("Ignored cache files inherit verified roots in fresh and shared reviews")
    func ignoredCacheContents() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        try sandbox.file("Documents/Project/.gitignore", text: ".venv/\n__pycache__/\n.env\ndatabase.sqlite\n.DS_Store\n.next/\nnext-env.d.ts\n*.tsbuildinfo\n")
        try sandbox.file("Documents/Project/uv.lock", text: "version = 1\n")
        try sandbox.file("Documents/Project/source.py", text: "print('fixture')\n")
        try sandbox.nextProject("Documents/Project")
        try sandbox.git(["-C", repo.path, "add", ".gitignore", "uv.lock", "source.py", "package.json", "tsconfig.json"])
        try sandbox.git(["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Fixture"])
        try sandbox.git(["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        let tree = try sandbox.worktree("Worktrees/caches", repository: repo)
        try sandbox.nextProject("Worktrees/caches")
        try sandbox.file("Worktrees/caches/.DS_Store", text: "\0\0\0\u{1}Bud1fixture")
        try sandbox.file("Worktrees/caches/.pytest_cache/.gitignore", text: "*\n")
        try sandbox.file("Worktrees/caches/.pytest_cache/CACHEDIR.TAG", text: CacheDirectoryTag.signature)
        try sandbox.file("Worktrees/caches/.pytest_cache/README.md", text: "pytest cache")
        try sandbox.file("Worktrees/caches/.pytest_cache/v/cache/nodeids", text: "[]")
        try sandbox.file("Worktrees/caches/.venv/pyvenv.cfg", text: "home = /fixture/python\n")
        try sandbox.file("Worktrees/caches/.venv/lib/package.py", text: "# Installed dependency\n")
        try sandbox.file("Worktrees/caches/__pycache__/source.cpython-313.pyc", text: "Compiled fixture")

        let fresh = try await GitWorktreeReviewService().review(tree)
        #expect(fresh.ignoredFiles.contains { $0.path == ".pytest_cache/README.md" })
        #expect(fresh.ignoredFiles.contains { $0.path == ".pytest_cache/CACHEDIR.TAG" })
        #expect(fresh.regenerableIgnoredFiles.count == fresh.ignoredFiles.count)
        #expect(fresh.isSafeToRemove)
        let batch = try await WorktreeScan.prepare([tree])
        let measured = try await batch.measure(tree, with: AllocatedSizeMeasurer())
        let shared = try #require(measured.reviews[tree.standardizedFileURL])
        #expect(shared.ignoredFiles == fresh.ignoredFiles)

        try sandbox.file("Worktrees/caches/.env", text: "Local settings")
        try sandbox.file("Worktrees/caches/database.sqlite", text: "Local data")
        let mixed = try await GitWorktreeReviewService().review(tree)
        #expect(mixed.localIgnoredFiles.map(\.path) == [".env", "database.sqlite"])
        #expect(mixed.regenerableIgnoredFiles.count == fresh.ignoredFiles.count)
        #expect(mixed.unverifiedIgnoredFiles.isEmpty)
        #expect(mixed.outcome == .hasLocalFiles)
        #expect(mixed.ignoredFilesCheck == .found(".env, database.sqlite"))
    }

    @Test("Next and TypeScript evidence rejects edited files, missing manifests, and links", arguments: [false, true])
    func generatedWebFiles(development: Bool) throws {
        let sandbox = try Sandbox()
        try sandbox.nextProject("web", development: development)
        let detector = GeneratedWorktreeFileDetector(root: sandbox.home.appendingPathComponent("web"))
        let root = sandbox.home.appendingPathComponent("web")
        #expect(detector.recognizes(root.appendingPathComponent(".next"), isDirectory: true))
        #expect(detector.recognizes(root.appendingPathComponent("next-env.d.ts"), isDirectory: false))
        #expect(detector.recognizes(root.appendingPathComponent("tsconfig.tsbuildinfo"), isDirectory: false))
        try sandbox.file("web/.env.local", text: "Keep local settings")
        #expect(!detector.recognizes(root.appendingPathComponent(".env.local"), isDirectory: false))
        try sandbox.file("web/next-env.d.ts", text: "/// <reference types=\"next\" />\n// NOTE: This file should not be edited\ndeclare const localSetting: string;")
        #expect(!detector.recognizes(root.appendingPathComponent("next-env.d.ts"), isDirectory: false))
        try sandbox.file("web/tsconfig.tsbuildinfo", text: #"{"notes":"Keep this file"}"#)
        #expect(!detector.recognizes(root.appendingPathComponent("tsconfig.tsbuildinfo"), isDirectory: false))
        try sandbox.file("outside/package.json", text: #"{"dependencies":{"next":"16.2.4"}}"#)
        try FileManager.default.removeItem(at: root.appendingPathComponent("package.json"))
        #expect(!detector.recognizes(root.appendingPathComponent(".next"), isDirectory: true))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("package.json"),
            withDestinationURL: sandbox.home.appendingPathComponent("outside/package.json"))
        #expect(!detector.recognizes(root.appendingPathComponent(".next"), isDirectory: true))
    }

    @Test("Finder and Xcode metadata require known contents and preserve local Xcode data")
    func generatedDesktopMetadata() throws {
        let sandbox = try Sandbox()
        let detector = GeneratedWorktreeFileDetector(root: sandbox.home)
        let finder = sandbox.home.appendingPathComponent(".DS_Store")
        try sandbox.file(".DS_Store", text: "Local notes with a misleading name")
        #expect(!detector.recognizes(finder, isDirectory: false))
        try sandbox.file(".DS_Store", text: "\0\0\0\u{1}Bud1fixture")
        #expect(detector.recognizes(finder, isDirectory: false))
        let metadata = "Core/.swiftpm/xcode/xcuserdata"
        let user = metadata + "/fixture.xcuserdatad"
        try sandbox.plist(user + "/xcschemes/xcschememanagement.plist", object: [
            "SchemeUserState": ["Core.xcscheme_^#shared#^_": ["orderHint": 1]]
        ])
        try sandbox.plist(user + "/UserInterfaceState.xcuserstate", object: [
            "$archiver": "NSKeyedArchiver", "$objects": ["$null"], "$top": [:]
        ])
        let folder = sandbox.home.appendingPathComponent(metadata)
        #expect(detector.recognizes(folder, isDirectory: true))
        try sandbox.file(user + "/xcschemes/Local.xcscheme", text: "Local scheme")
        #expect(!detector.recognizes(folder, isDirectory: true))
        try FileManager.default.removeItem(at: sandbox.home.appendingPathComponent(user + "/xcschemes/Local.xcscheme"))
        try sandbox.file(user + "/xcdebugger/Breakpoints_v2.xcbkptlist", text: "Local breakpoint")
        #expect(!detector.recognizes(folder, isDirectory: true))
        try sandbox.file("project.yml", text: "name: Project")
        try sandbox.file("Project.xcodeproj/project.pbxproj", text: "Generated project")
        try sandbox.file("Project.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved", text: "Keep dependency versions")
        #expect(!detector.recognizes(sandbox.home.appendingPathComponent("Project.xcodeproj"), isDirectory: true))
    }

    private static var xcodegenExecutable: String? {
        ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test("Generated Xcode projects require an exact match in fresh and shared reviews", .enabled(if: xcodegenExecutable != nil))
    func generatedXcodeProjects() async throws {
        let sandbox = try Sandbox()
        let repo = try sandbox.repository()
        let spec = """
            name: Project
            targets:
              Project:
                type: framework
                platform: macOS
                sources: [Sources]
            schemes:
              Project:
                build:
                  targets:
                    Project: all
            """
        try sandbox.file("Documents/Project/project.yml", text: spec)
        try sandbox.file("Documents/Project/.gitignore", text: "*.xcodeproj/\n")
        try sandbox.file("Documents/Project/Sources/Source.swift", text: "struct Source {}\n")
        try sandbox.git(["-C", repo.path, "add", "project.yml", ".gitignore", "Sources"])
        try sandbox.git(["-C", repo.path, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-m", "Project"])
        try sandbox.git(["-C", repo.path, "update-ref", "refs/remotes/origin/main", "HEAD"])
        let tree = try sandbox.worktree("Worktrees/generated", repository: repo)
        let generator = try #require(Self.xcodegenExecutable)
        try await ProcessRunner().run(generator, ["generate", "--quiet", "--no-env", "--project", tree.path,
            "--spec", tree.appendingPathComponent("project.yml").path, "--project-root", tree.path])
        let bundle = tree.appendingPathComponent("Project.xcodeproj")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("project.xcworkspace/xcshareddata/swiftpm/configuration"),
                                               withIntermediateDirectories: true)
        let fresh = try await GitWorktreeReviewService().review(tree)
        #expect(fresh.regenerableIgnoredFiles.map(\.path) == ["Project.xcodeproj/"])
        #expect(fresh.isSafeToRemove)
        let batch = try await WorktreeScan.prepare([tree])
        let measured = try await batch.measure(tree, with: AllocatedSizeMeasurer())
        #expect(measured.reviews[tree]?.ignoredFiles == fresh.ignoredFiles)
        let verifier = GeneratedXcodeProjectVerifier(generator: generator)
        let project = bundle.appendingPathComponent("project.pbxproj")
        let original = try Data(contentsOf: project)
        try (original + Data("\n// Local project edit\n".utf8)).write(to: project)
        #expect(try await verifier.verify(tree, ignoredPaths: ["Project.xcodeproj/"], git: "/usr/bin/git").isEmpty)
        try original.write(to: project)
        for path in ["project.xcworkspace/xcshareddata/swiftpm/Package.resolved", "xcshareddata/xcschemes/Local.xcscheme",
                     "xcuserdata/fixture.xcuserdatad/xcdebugger/Breakpoints_v2.xcbkptlist", "notes.txt"] {
            try sandbox.file("Worktrees/generated/Project.xcodeproj/" + path, text: "Keep local data")
            #expect(try await verifier.verify(tree, ignoredPaths: ["Project.xcodeproj/"], git: "/usr/bin/git").isEmpty)
            try FileManager.default.removeItem(at: bundle)
            try await ProcessRunner().run(generator, ["generate", "--quiet", "--no-env", "--project", tree.path,
                "--spec", tree.appendingPathComponent("project.yml").path, "--project-root", tree.path])
        }
        try FileManager.default.removeItem(at: tree.appendingPathComponent("Sources/Source.swift"))
        try FileManager.default.createSymbolicLink(at: tree.appendingPathComponent("Sources/Source.swift"),
            withDestinationURL: repo.appendingPathComponent("Sources/Source.swift"))
        #expect(try await verifier.verify(tree, ignoredPaths: ["Project.xcodeproj/"], git: "/usr/bin/git").isEmpty)
    }

    @Test("Project verification rejects generation commands and paths outside the snapshot",
           arguments: ["preGenCommand", "postGenCommand", "sourcePath", "schemeName"])
    func unsafeXcodeGeneration(kind: String) async throws {
        let sandbox = try Sandbox()
        try sandbox.file("project.yml", text: "name: Project\n")
        var object: [String: Any] = ["name": "Project"]
        switch kind {
        case "sourcePath": object["fileGroups"] = ["../outside"]
        case "schemeName": object["schemes"] = ["../../outside": [:]]
        default: object["options"] = [kind: "touch marker"]
        }
        let resolved = try JSONSerialization.data(withJSONObject: object)
        let verifier = GeneratedXcodeProjectVerifier(generator: "xcodegen") { executable, arguments in
            if executable == "git" { return Data("project.yml\0".utf8) }
            #expect(arguments.first == "dump")
            return resolved
        }
        #expect(try await verifier.verify(sandbox.home, ignoredPaths: ["Project.xcodeproj/"], git: "git").isEmpty)
    }

    @Test("Missing generators and external specification inputs remain unverified")
    func unavailableXcodeGeneration() async throws {
        let sandbox = try Sandbox()
        let verifier = GeneratedXcodeProjectVerifier(generator: "xcodegen") { _, _ in
            Issue.record("The parser must not read an external specification.")
            return Data()
        }
        for source in ["include: ../external.yml\nname: Project\n", #"{"\u0069nclude":"../external.yml","name":"Project"}"#] {
            try sandbox.file("project.yml", text: source)
            #expect(try await verifier.verify(sandbox.home, ignoredPaths: ["Project.xcodeproj/"], git: "git").isEmpty)
        }
        try sandbox.file("project.yml", text: "name: Project\n")
        let missing = GeneratedXcodeProjectVerifier(generator: nil)
        #expect(try await missing.verify(sandbox.home, ignoredPaths: ["Project.xcodeproj/"], git: "git").isEmpty)
    }

    @Test("Empty ignored folders stop qualifying when local or hidden files appear")
    func emptyIgnoredFolders() throws {
        let sandbox = try Sandbox()
        let folder = sandbox.home.appendingPathComponent(".claude/.cc-writes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let detector = GeneratedWorktreeFileDetector(root: sandbox.home)
        #expect(detector.recognizes(folder, isDirectory: true))
        try sandbox.file(".claude/.cc-writes/.local-data", text: "Keep this hidden file")
        #expect(!detector.recognizes(folder, isDirectory: true))
    }

    @Test("Cache inheritance preserves evidence, boundaries, and measurement failures")
    func ignoredCacheBoundaries() throws {
        let sandbox = try Sandbox()
        let root = sandbox.home.appendingPathComponent(".pytest_cache/tree").standardizedFileURL
        try sandbox.file(".pytest_cache/CACHEDIR.TAG", text: CacheDirectoryTag.signature)
        try sandbox.file(".pytest_cache/uv.lock", text: "Outside the worktree")
        let files = ["ordinary.txt", ".venv/pyvenv.cfg", ".venv/lib/package.py", "__pycache__/orphan.pyc",
                     "plain/.pytest_cache/README.md", ".pytest_cache/README.md", ".pytest_cache/nested/file.json"]
        for path in files { try sandbox.file(".pytest_cache/tree/" + path, text: "Fixture") }
        try sandbox.file(".pytest_cache/tree/plain/.pytest_cache/CACHEDIR.TAG", text: "Invalid signature")
        try sandbox.file(".pytest_cache/tree/.pytest_cache/CACHEDIR.TAG", text: CacheDirectoryTag.signature)
        try sandbox.file("outside/.pytest_cache/CACHEDIR.TAG", text: CacheDirectoryTag.signature)
        try sandbox.file("outside/.pytest_cache/README.md", text: "Outside data")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"),
            withDestinationURL: sandbox.home.appendingPathComponent("outside"))
        let paths = files + ["linked/.pytest_cache/README.md", "missing.txt"]
        var review = GitWorktreeReview()
        review.ignoredFiles = paths.map { .init(path: $0, status: .ignored) }
        let measurements = Dictionary(uniqueKeysWithValues: paths.map {
            (root.appendingPathComponent($0).standardizedFileURL, SizeMeasurement(allocatedBytes: 64, fileCount: 1))
        })
        GitWorktreeReviewService.applyMeasurements(measurements, directory: root, to: &review)
        #expect(review.regenerableIgnoredFiles.map(\.path) == [".pytest_cache/README.md", ".pytest_cache/nested/file.json"])
        #expect(review.unverifiedIgnoredFiles.map(\.path) == ["missing.txt"])
        #expect(review.localIgnoredFiles.count == paths.count - 3)

        let cacheFile = root.appendingPathComponent(".pytest_cache/README.md").standardizedFileURL
        for failure in [SizeMeasurement(unreadableCount: 1), SizeMeasurement(containsCloudOnlyItem: true)] {
            GitWorktreeReviewService.applyMeasurements([cacheFile: failure], directory: root, to: &review)
            #expect(review.ignoredFiles.first { $0.path == ".pytest_cache/README.md" }?.regeneratesSafely == nil)
        }
        GitWorktreeReviewService.applyMeasurements([cacheFile: SizeMeasurement(containsProtectedPattern: true)], directory: root, to: &review)
        #expect(review.ignoredFiles.first { $0.path == ".pytest_cache/README.md" }?.regeneratesSafely == false)
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

    @Test("Shared process checks match hard links and reject incomplete inventories")
    func sharedActivity() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("outside/open.txt", text: "Open file")
        try sandbox.file("tree/.venv/other.txt", text: "Other file")
        let root = sandbox.home.appendingPathComponent("tree").standardizedFileURL
        let file = sandbox.home.appendingPathComponent("outside/open.txt")
        try FileManager.default.linkItem(at: file, to: root.appendingPathComponent(".venv/alias.txt"))
        let identity = try #require(FileIdentity.of(file)).split(separator: ":")
        let device = try #require(UInt32(identity[0]))
        let output = Data("p123\0cTest process\0\nf3\0tREG\0D0x\(String(device, radix: 16))\0i\(identity[1])\0\n".utf8)
        let parsed = WorktreeActivity.parse(output)
        #expect(parsed.complete)
        let activity = WorktreeActivity(roots: [root], processes: parsed.processes)
        let totals = try await AllocatedSizeMeasurer().measure(root, retaining: [],
            observeEntry: { url, values, owners in activity.observe(url, values: values, attribution: owners) })
        #expect(activity.check(root, measurement: totals[root]) == .found("Test process"))
        let prefetched = try file.resourceValues(forKeys: [.fileIdentifierKey, .volumeIdentifierKey])
        #expect(prefetched.fileIdentifier == UInt64(identity[1]))
        let fast = WorktreeActivity(roots: [root], processes: parsed.processes)
        fast.observe(root.appendingPathComponent("missing"), values: prefetched, attribution: [root])
        #expect(fast.check(root, measurement: totals[root]) == .found("Test process"))
        #expect(fast.fallbackCount == 0)
        #expect(activity.fallbackCount == 0)
        let fallback = WorktreeActivity(roots: [root], processes: parsed.processes)
        fallback.observe(file, values: URLResourceValues(), attribution: [root])
        #expect(fallback.check(root, measurement: totals[root]) == .found("Test process"))
        #expect(fallback.fallbackCount == 1)
        let directoryIdentity = try #require(FileIdentity.of(root))
        let cwd = WorktreeActivity(roots: [root], processes: [directoryIdentity: ["Shell"]])
        cwd.observe(root, values: try root.resourceValues(forKeys: [.fileIdentifierKey, .volumeIdentifierKey]), attribution: [root])
        #expect(cwd.check(root, measurement: totals[root]) == .found("Shell"))
        #expect(!WorktreeActivity.parse(Data("p123\0cTest\0\nf3\0tREG\0\n".utf8)).complete)
        let revoked = WorktreeActivity.parse(output + Data("f4\0n(revoked)\0\n".utf8))
        #expect(revoked.complete)
        #expect(revoked.revokedFiles == 1)
        #expect(revoked.processes == parsed.processes)
        for record in ["f4\0\n", "f4\0nPermission denied\0\n", "f4\0tREG\0n(revoked)\0\n"] {
            let result = WorktreeActivity.parse(output + Data(record.utf8))
            #expect(!result.complete)
            #expect(result.incompleteFiles == 1)
        }
        #expect(!WorktreeActivity.parse(output.dropLast()).complete)
        let incomplete = WorktreeActivity(roots: [root], processes: [:], issue: "Incomplete inventory.")
        #expect(incomplete.check(root, measurement: totals[root]) == .unknown("Incomplete inventory."))
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
