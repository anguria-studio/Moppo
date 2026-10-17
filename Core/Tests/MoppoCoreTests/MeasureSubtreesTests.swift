import Foundation
import Testing
@testable import MoppoCore

@Suite("measureSubtrees — one pass, many totals")
struct MeasureSubtreesTests {

    private typealias Sandbox = AllocatedSizeMeasurerTests.Sandbox
    private static let oneMB = 1024 * 1024

    @Test("Selected totals share hard-link accounting and preserve protection flags")
    func selectedTotals() async throws {
        let sandbox = try Sandbox()
        let file = try sandbox.writeFile("project/tree/.venv/data.bin", bytes: Self.oneMB)
        let project = sandbox.root.appendingPathComponent("project").standardizedFileURL
        let tree = project.appendingPathComponent("tree")
        let ignored = tree.appendingPathComponent(".venv")
        let alias = project.appendingPathComponent("alias.bin")
        try FileManager.default.linkItem(at: file, to: alias)
        let secret = try sandbox.writeFile("project/tree/settings.keychain-db", bytes: 4096).standardizedFileURL
        let totals = try await AllocatedSizeMeasurer(protectedPatterns: ["*.keychain-db"])
            .measure(project, retaining: [tree, ignored, alias, secret])
        let parent = try #require(totals[project])
        #expect(parent.fileCount == 2)
        #expect(parent.allocatedBytes == (totals[tree]?.allocatedBytes ?? 0) + (totals[alias]?.allocatedBytes ?? 0))
        #expect(totals[tree]?.allocatedBytes == (totals[ignored]?.allocatedBytes ?? 0) + (totals[secret]?.allocatedBytes ?? 0))
        #expect(parent.containsProtectedPattern)
        #expect(totals[tree]?.containsProtectedPattern == true)
        #expect(totals[secret]?.containsProtectedPattern == true)
        #expect(totals[ignored]?.containsProtectedPattern == false)
    }

    @Test("depth-2 totals are recursive and parents contain their children")
    func depthTwoTotals() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("Library/Caches/app/blob.bin", bytes: 4 * Self.oneMB)
        try sandbox.writeFile("Library/Containers/x.bin", bytes: 2 * Self.oneMB)
        try sandbox.writeFile("Documents/report.bin", bytes: 3 * Self.oneMB)

        let totals = try await AllocatedSizeMeasurer()
            .measureSubtrees(of: sandbox.root, depth: 2)

        let root = sandbox.root.standardizedFileURL
        let library = root.appendingPathComponent("Library")
        let caches = library.appendingPathComponent("Caches")
        let documents = root.appendingPathComponent("Documents")

        // Depth 1 and depth 2 are both present from a single traversal.
        #expect(totals[library]?.fileCount == 2)
        #expect(totals[caches]?.fileCount == 1)
        #expect(totals[documents]?.fileCount == 1)

        // Recursive containment holds exactly.
        let libraryBytes = try #require(totals[library]?.allocatedBytes)
        let cachesBytes = try #require(totals[caches]?.allocatedBytes)
        #expect(cachesBytes < libraryBytes)
        #expect(totals[root]?.allocatedBytes == libraryBytes + (totals[documents]?.allocatedBytes ?? 0))
    }

    @Test("depth-1 agrees with measureChildren")
    func agreesWithMeasureChildren() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("alpha/one.bin", bytes: 2 * Self.oneMB)
        try sandbox.writeFile("beta/two.bin", bytes: 6 * Self.oneMB)

        let measurer = AllocatedSizeMeasurer()
        let subtrees = try await measurer.measureSubtrees(of: sandbox.root, depth: 1)
        let children = try await measurer.measureChildren(of: sandbox.root)

        for (url, measurement) in children {
            #expect(subtrees[url.standardizedFileURL]?.allocatedBytes == measurement.allocatedBytes)
        }
    }

    @Test("an unreadable branch does not zero the root total")
    func unreadableBranch() async throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("open/data.bin", bytes: 3 * Self.oneMB)
        let locked = try sandbox.directory("locked")
        try sandbox.writeFile("locked/hidden.bin", bytes: 5 * Self.oneMB)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)

        let totals = try await AllocatedSizeMeasurer()
            .measureSubtrees(of: sandbox.root, depth: 2)

        let root = sandbox.root.standardizedFileURL
        #expect(totals[root]?.allocatedBytes ?? 0 >= Int64(3 * Self.oneMB))
        #expect(totals[root]?.unreadableCount ?? 0 > 0)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
    }
}
