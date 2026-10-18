import Foundation
import Testing
@testable import MoppoCore

@Suite("Cleanup data types")
struct CleanupDataTypeTests {
    @Test("Types distinguish files, dependency folders, and worktree metadata")
    func classification() {
        func entry(_ path: String, _ kind: FileEntry.Kind) -> FileEntry {
            FileEntry(url: URL(fileURLWithPath: path), kind: kind, allocatedBytes: 100)
        }
        let cases: [(FileEntry, CleanupDataType?)] = [
            (entry("/project/node_modules", .cache), .nodeModules),
            (entry("/project/node_modules", .folder), .nodeModules),
            (entry("/project/node_modules", .file), nil),
            (entry("/project/.venv", .cache), .pythonEnvironments),
            (entry("/project/.tox", .cache), .pythonEnvironments),
            (entry("/project/venv", .folder), nil),
            (entry("/project/__pycache__", .cache), nil),
            (entry("/downloads/photo.HEIC", .file), nil),
            (entry("/downloads/clip.MP4", .file), nil),
            (entry("/downloads/music.FLAC", .file), nil),
            (entry("/downloads/photo.jpg", .folder), nil),
            (entry("/downloads/music.mp3", .cache), nil),
            (entry("/downloads/archive.zip", .archive), .archivesAndInstallers),
            (entry("/downloads/installer.dmg", .diskImage), .archivesAndInstallers),
            (entry("/downloads/installer.PKG", .file), .archivesAndInstallers),
            (entry("/downloads/Example.app", .downloadedApp), .archivesAndInstallers),
            (entry("/Applications/Example.app", .appBundle), nil),
            (entry("/project/worktrees", .folder), nil)
        ]
        for (item, expected) in cases {
            #expect(CleanupDataType.allCases.filter { $0 != .all && $0.matches(item) } == expected.map { [$0] } ?? [])
        }
        var worktree = entry("/project/node_modules", .folder)
        worktree.gitWorktreeReview = GitWorktreeReview()
        #expect(CleanupDataType.worktrees.matches(worktree))
        #expect(!CleanupDataType.nodeModules.matches(worktree))
        let docker = FileEntry(url: URL(string: "docker://images/example")!, kind: .diskImage, allocatedBytes: 100)
        #expect(!CleanupDataType.archivesAndInstallers.matches(docker))
    }

    @Test("Matching children keep context and cannot escape a unit removal workflow")
    func childRows() {
        let child = FileEntry(url: URL(fileURLWithPath: "/project/node_modules"),
            parentDisplay: "~/project", kind: .cache, allocatedBytes: 200, safetyCaveat: "no lockfile")
        var parent = FileEntry(url: URL(fileURLWithPath: "/project"), kind: .folder,
            allocatedBytes: 900, protectionReason: .inventory, children: [child])
        parent.aiStorageSection = .init(owner: .codex, title: "Task data", summary: "Task files")
        let rows = CleanupDataType.nodeModules.rows(in: [parent, child])
        #expect(rows.count == 1)
        #expect(rows[0].id == child.id)
        #expect(rows[0].parentDisplay == child.parentDisplay)
        #expect(rows[0].allocatedBytes == 200)
        #expect(rows[0].safetyCaveat == "no lockfile")
        #expect(rows[0].aiStorageSection?.owner == .codex)
        parent.removesAsUnit = true
        #expect(CleanupDataType.nodeModules.rows(in: [parent]).isEmpty)
        parent.removesAsUnit = false
        parent.removalAction = .orphanedApplication(bundleIdentifier: "test.app")
        #expect(CleanupDataType.nodeModules.rows(in: [parent]).isEmpty)
        parent.removalAction = nil
        parent.children[0].protectionReason = .userData
        #expect(CleanupDataType.nodeModules.rows(in: [parent]).isEmpty)
        #expect(CleanupDataType.all.rows(in: [parent]) == [parent])
    }
}
