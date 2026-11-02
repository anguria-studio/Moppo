import Foundation
import Testing
@testable import MoppoCore

/// A `vendor` folder is offered only when its tool, its lockfile, and Git all show
/// that the folder can come back. Each other `vendor` folder stays in its project row.
@Suite("Vendor folders")
struct VendorFolderTests {

    private final class Sandbox {
        let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("moppo-vendor-\(UUID().uuidString)", isDirectory: true)

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

        /// A project with the evidence and the lockfiles of `tool`, and a vendor folder
        /// large enough to get its own row. Returns the vendor folder.
        @discardableResult
        func project(_ relative: String, tool: VendorFolder.Tool) throws -> URL {
            try file("\(relative)/src/main", bytes: 2 * 1024 * 1024)
            for lockfile in tool.lockfiles { try file("\(relative)/\(lockfile)") }
            let vendor = "\(relative)/vendor"
            switch tool {
            case .composer:
                try file("\(vendor)/composer/installed.json")
                try file("\(vendor)/acme/lib/src/Lib.php", bytes: 3 * 1024 * 1024)
            case .bundler:
                try file("\(vendor)/bundle/ruby/3.3.0/gems/rack-3.0.0/lib/rack.rb", bytes: 3 * 1024 * 1024)
            case .go:
                try file("\(vendor)/modules.txt")
                try file("\(vendor)/example.com/mod/mod.go", bytes: 3 * 1024 * 1024)
            }
            return home.appendingPathComponent(vendor)
        }

        /// A fake Git that runs `body` as a shell script.
        func git(_ body: String) throws -> String {
            let url = home.appendingPathComponent("fake-git-\(UUID().uuidString)")
            try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url.path
        }

        func commit(_ project: URL, adding paths: [String]) throws {
            try runGit(["init", "-q", project.path])
            try runGit(["-C", project.path, "add", "--"] + paths)
            try runGit(["-C", project.path, "-c", "user.name=Test", "-c", "user.email=test@example.com",
                        "commit", "-q", "-m", "Test"])
        }

        func scan(gitTrackedFiles: GitTrackedFilesReader = GitTrackedFilesReader()) async throws -> ScanCategoryResult {
            let clock: @Sendable () -> Date = { Date().addingTimeInterval(ProjectActivity.idlePeriod + 24 * 60 * 60) }
            return try await DocumentsFilesScanner(
                home: home, projectActivity: ProjectActivityReader(clock: clock, gitExecutable: { nil }),
                gitTrackedFiles: gitTrackedFiles
            ).scan(context: ScanContext())
        }
    }

    private static func project(_ name: String, in result: ScanCategoryResult) throws -> FileEntry {
        try #require(result.entries.first { $0.url.lastPathComponent == name })
    }

    // MARK: - Evidence

    @Test("each tool needs its evidence and every lockfile next to vendor", arguments: VendorFolder.Tool.allCases)
    func evidenceAndLockfiles(tool: VendorFolder.Tool) throws {
        let sandbox = try Sandbox()
        let vendor = try sandbox.project("Documents/app", tool: tool)
        #expect(VendorFolder.evidence(at: vendor)?.tool == tool)

        for lockfile in tool.lockfiles {
            let url = vendor.deletingLastPathComponent().appendingPathComponent(lockfile)
            try FileManager.default.removeItem(at: url)
            #expect(VendorFolder.evidence(at: vendor) == nil, "\(lockfile) is missing")
            try sandbox.file("Documents/app/\(lockfile)")
        }

        try FileManager.default.removeItem(at: vendor.appendingPathComponent(tool.evidence))
        #expect(VendorFolder.evidence(at: vendor) == nil, "the evidence is missing")
    }

    @Test("a folder with other content, two tools, a Go workspace, or its own repository is not identified")
    func ambiguousFolders() throws {
        let sandbox = try Sandbox()
        let rails = try sandbox.project("Documents/rails", tool: .bundler)
        try sandbox.file("Documents/rails/vendor/javascript/pinned.js")
        let mixed = try sandbox.project("Documents/mixed", tool: .composer)
        try sandbox.file("Documents/mixed/vendor/modules.txt")
        try sandbox.file("Documents/mixed/go.mod")
        try sandbox.file("Documents/mixed/go.sum")
        let repository = try sandbox.project("Documents/clone", tool: .go)
        try sandbox.file("Documents/clone/vendor/.git/HEAD")
        let workspace = try sandbox.project("Documents/workspace", tool: .go)
        try sandbox.file("Documents/workspace/go.work")

        #expect(VendorFolder.evidence(at: rails) == nil)
        #expect(VendorFolder.evidence(at: mixed) == nil)
        #expect(VendorFolder.evidence(at: repository) == nil)
        #expect(VendorFolder.evidence(at: workspace) == nil)
    }

    // MARK: - Git

    @Test("Git reports untracked, fully tracked, and partly tracked folders")
    func gitTrackedFiles() async throws {
        let sandbox = try Sandbox()
        let reader = GitTrackedFilesReader()
        let outside = try sandbox.project("Documents/outside", tool: .go)
        #expect(try await reader.state(of: outside) == .untracked)

        let ignored = try sandbox.project("Documents/ignored", tool: .go)
        try Data("vendor/\n".utf8).write(to: ignored.deletingLastPathComponent().appendingPathComponent(".gitignore"))
        try sandbox.commit(ignored.deletingLastPathComponent(), adding: ["."])
        #expect(try await reader.state(of: ignored) == .untracked)

        let tracked = try sandbox.project("Documents/tracked", tool: .go)
        try sandbox.commit(tracked.deletingLastPathComponent(), adding: ["."])
        #expect(try await reader.state(of: tracked) == .tracked)

        let partly = try sandbox.project("Documents/partly", tool: .go)
        try sandbox.commit(partly.deletingLastPathComponent(), adding: ["go.mod", "vendor/modules.txt"])
        #expect(try await reader.state(of: partly) == .tracked)
    }

    @Test("a failed, slow, or missing Git gives an unknown state", arguments: ["exit 2", "exec /bin/sleep 30", "missing"])
    func failedGitCheck(script: String) async throws {
        let sandbox = try Sandbox()
        let vendor = try sandbox.project("Documents/app", tool: .composer)
        let git: String? = script == "missing" ? nil : try sandbox.git(script)
        let reader = GitTrackedFilesReader(gitExecutable: { git }, timeout: .milliseconds(500))
        let state = try await reader.state(of: vendor)
        #expect(state == .unknown)
    }

    // MARK: - Scan

    @Test("a verified vendor folder is a child row that is not safe and not selected",
          arguments: VendorFolder.Tool.allCases)
    func verifiedFolderIsOffered(tool: VendorFolder.Tool) async throws {
        let sandbox = try Sandbox()
        let vendor = try sandbox.project("Documents/app", tool: tool)

        let result = try await sandbox.scan()

        let project = try Self.project("app", in: result)
        let child = try #require(project.children.first { $0.url == vendor })
        #expect(child.vendorFolder?.tool == tool)
        #expect(!child.isRemovalLocked)
        #expect(!child.isRegenerable)
        #expect(!child.regeneratesSafely)
        #expect(child.safetyCaveat == "restore with \(tool.restoreCommand)")
        #expect(child.parentDisplay.hasSuffix("\(tool.label) · \(tool.lockfiles.joined(separator: " and "))"))
        let summary = FileEntryPresentation(entry: child, showsSafetyCaveat: false).summary
        #expect(summary.hasPrefix("\(tool.label) · \(tool.lockfiles.joined(separator: " and "))"))
        #expect(project.allocatedBytes < 3 * 1024 * 1024, "the project no longer carries the vendor folder")
        #expect(!result.tileRows(safeToRemove: true).contains { $0.url == vendor })
        #expect(CleanupSelection.ids(in: [result], selected: [child.id], scope: .safe).isEmpty)
    }

    @Test("a folder that fails a check stays in its project row", arguments: ["lockfile", "tracked", "partly tracked", "Git failed"])
    func unverifiedFolderStaysInProject(problem: String) async throws {
        let sandbox = try Sandbox()
        let vendor = try sandbox.project("Documents/app", tool: .composer)
        let project = vendor.deletingLastPathComponent()
        var reader = GitTrackedFilesReader()
        switch problem {
        case "lockfile": try FileManager.default.removeItem(at: project.appendingPathComponent("composer.lock"))
        case "tracked": try sandbox.commit(project, adding: ["."])
        case "partly tracked": try sandbox.commit(project, adding: ["vendor/composer/installed.json"])
        default:
            let failing = try sandbox.git("exit 2")
            reader = GitTrackedFilesReader(gitExecutable: { failing })
        }

        let result = try await sandbox.scan(gitTrackedFiles: reader)

        let row = try Self.project("app", in: result)
        #expect(row.children.isEmpty)
        #expect(row.allocatedBytes >= 5 * 1024 * 1024, "the project still carries the vendor folder")
    }

    // MARK: - Removal

    @Test("removal checks the evidence, the lockfile, and Git again", arguments: ["evidence", "lockfile", "Git", "none"])
    func removalRechecks(change: String) async throws {
        let sandbox = try Sandbox()
        let vendor = try sandbox.project("Documents/app", tool: .composer)
        let project = vendor.deletingLastPathComponent()
        let result = try await sandbox.scan()
        let child = try #require(try Self.project("app", in: result).children.first { $0.url == vendor })
        switch change {
        case "evidence": try FileManager.default.removeItem(at: vendor.appendingPathComponent("composer"))
        case "lockfile": try FileManager.default.removeItem(at: project.appendingPathComponent("composer.lock"))
        case "Git": try sandbox.commit(project, adding: ["vendor/acme/lib/src/Lib.php"])
        default: break
        }

        let service = CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) },
                                     log: RemovalLog(directory: sandbox.home.appendingPathComponent("logs")))
        let outcome = try await service.remove(entries: [child], trashFirst: false)

        let removed = change == "none"
        #expect(outcome.removedCount == (removed ? 1 : 0))
        #expect(outcome.failed == (removed ? [] : [vendor.path]))
        #expect(FileManager.default.fileExists(atPath: vendor.path) == !removed)
    }

    @Test("a selected project removes its vendor folder without the vendor checks")
    func projectRemovalIncludesVendorFolder() async throws {
        let sandbox = try Sandbox()
        let vendor = try sandbox.project("Documents/app", tool: .go)
        let project = vendor.deletingLastPathComponent()
        let row = try Self.project("app", in: try await sandbox.scan())
        #expect(row.children.map(\.url) == [vendor])
        try FileManager.default.removeItem(at: project.appendingPathComponent("go.sum"))

        let service = CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) },
                                     log: RemovalLog(directory: sandbox.home.appendingPathComponent("logs")))
        let outcome = try await service.remove(entries: [row], trashFirst: false)

        #expect(outcome.failed.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: project.path))
    }
}
