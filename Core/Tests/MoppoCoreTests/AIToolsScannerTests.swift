import Foundation
import Testing
@testable import MoppoCore

@Suite("AI storage")
struct AIToolsScannerTests {
    private final class Sandbox {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-ai-\(UUID().uuidString)")
        init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ path: String, bytes: Int = 1024 * 1024) throws -> URL {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }
    }

    @Test("History, unknown caches, and downloaded runtimes remain visible and locked")
    func inventoryProtection() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".codex/sessions/task.jsonl")
        try sandbox.file(".codex/cache/unknown.sqlite")
        try sandbox.file(".codex/auth.json", bytes: 4096)
        try sandbox.file(".claude/projects/task/conversation.jsonl")
        try sandbox.file(".claude/file-history/previous.txt")
        try sandbox.file(".cursor/projects/task/state.json")
        try sandbox.file(".cache/codex-runtimes/runtime/bin/python")
        let context = ScanContext()
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        #expect(ai.entries.count == 4)
        for entry in ai.entries {
            #expect(entry.displayBytes == (try await context.measurer.measure(entry.url)).allocatedBytes)
            #expect(entry.reclaimableBytes == 0)
            for row in [entry] + entry.children {
                #expect(row.isRemovalLocked)
                #expect(!row.regeneratesSafely)
                #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
            }
        }
        #expect(ai.safeToRemoveBytes == 0)
        #expect(ai.needsReviewBytes == ai.totalBytes)
        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: context)
        let system = try await SystemCachesScanner(
            cachesRoot: sandbox.home.appendingPathComponent("Library/Caches"),
            logsRoot: sandbox.home.appendingPathComponent("Library/Logs"),
            dotCacheRoot: sandbox.home.appendingPathComponent(".cache")
        ).scan(context: context)
        #expect(hidden.entries.isEmpty)
        #expect(system.entries.isEmpty)
    }

    @Test("Claude VM files use allocated bytes and only verified desktop caches count as safe")
    func vmAndDesktopCaches() async throws {
        let sandbox = try Sandbox()
        let prefix = "Library/Application Support/Claude/"
        try sandbox.file(prefix + "vm_bundles/claudevm.bundle/rootfs.img")
        try sandbox.file(prefix + "vm_bundles/claudevm.bundle/rootfs.img.zst")
        let session = try sandbox.file(prefix + "vm_bundles/claudevm.bundle/sessiondata.img", bytes: 4096)
        let handle = try FileHandle(forWritingTo: session)
        try handle.truncate(atOffset: 1024 * 1024 * 1024)
        try handle.close()
        try sandbox.file(prefix + "Cache/data")
        try sandbox.file(prefix + "Code Cache/js/data")
        try sandbox.file(prefix + "Partitions/feature/Cache/data")
        try sandbox.file(prefix + "Cookies", bytes: 4096)
        try sandbox.file(prefix + "Service Worker/CacheStorage/offline-state")
        let context = ScanContext()
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        let row = try #require(ai.entries.first)
        #expect(row.children.filter(\.isRegenerable).count == 3)
        #expect(row.children.filter { $0.protectionReason == .inventory }.count == 3)
        let sessionRow = try #require(row.children.first { $0.url == session })
        #expect(sessionRow.allocatedBytes == (try await context.measurer.measure(session)).allocatedBytes)
        #expect(sessionRow.allocatedBytes < 1024 * 1024 * 1024)
        #expect(row.displayBytes == (try await context.measurer.measure(row.url)).allocatedBytes)
        #expect(row.reclaimableBytes == ai.safeToRemoveBytes)
        #expect(ai.safeToRemoveBytes + ai.needsReviewBytes == ai.totalBytes)
        #expect(ai.filtered(safeToRemove: true).totalBytes == ai.safeToRemoveBytes)
        #expect(ai.filtered(safeToRemove: false).totalBytes == ai.needsReviewBytes)
        #expect(!row.children.contains { $0.url.path.contains("Service Worker") })

        var running = context
        running.runningApplications = [.init(name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", bundlePath: "/Applications/Claude.app")]
        let inUse = try await AIToolsScanner(home: sandbox.home).scan(context: running)
        #expect(inUse.safeToRemoveBytes == 0)
        #expect(inUse.entries.flatMap(\.children).filter(\.isRegenerable).allSatisfy { $0.inUseBy != nil })
    }

    @Test("AI ownership removes duplicate rows and retains installed application bundles")
    func categoryOwnership() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Application Support/Codex/Cache/data")
        try sandbox.file("Library/Application Support/Codex/Cookies")
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext())
        let root = try #require(ai.entries.first)
        let cache = try #require(root.children.first)
        let app = FileEntry(url: sandbox.home.appendingPathComponent("Applications/ChatGPT.app"), kind: .appBundle,
                            allocatedBytes: 2_000_000, children: [cache, root])
        let hidden = FileEntry(url: root.url.appendingPathComponent("vm.img"), kind: .diskImage, allocatedBytes: 3_000_000)
        let results = ScanCoordinator.removingAIToolOverlaps(from: [
            ai, ScanCategoryResult(categoryID: .applications, entries: [app]),
            ScanCategoryResult(categoryID: .hiddenSystemData, entries: [hidden])
        ])
        #expect(results.first { $0.categoryID == .applications }?.entries.first?.children.isEmpty == true)
        #expect(results.first { $0.categoryID == .applications }?.totalBytes == app.allocatedBytes)
        #expect(results.first { $0.categoryID == .hiddenSystemData }?.availability == .empty)

        let excluded = try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext(excludedPaths: [cache.url.path]))
        #expect(excluded.entries.isEmpty)
        #expect(!excluded.claimedStoragePaths.isEmpty)
        let guarded = ScanCoordinator.removingAIToolOverlaps(from: [excluded,
            ScanCategoryResult(categoryID: .systemCaches, entries: [cache])])
        #expect(guarded.last?.entries.isEmpty == true)
    }

    @Test("Removed Cursor desktop data uses the leftover review and installed owners retain AI storage")
    func cursorDesktopOwnership() async throws {
        let sandbox = try Sandbox()
        let identifier = "com.todesktop.230313mzl4w4u92"
        let desktop = sandbox.home.appendingPathComponent("Library/Application Support/Cursor", isDirectory: true)
        try sandbox.file("Library/Application Support/Cursor/Cache/data")
        try sandbox.file("Library/Application Support/Cursor/User/history.db")
        try sandbox.file(".cursor/projects/task/state.json")
        let applications = sandbox.home.appendingPathComponent("Applications")
        let planner = OrphanedAppLeftoverPlanner(pathPlanner: AppUninstallPlanner(
            home: sandbox.home,
            systemLibrary: sandbox.home.appendingPathComponent("SystemLibrary"),
            applicationRoots: [applications], darwinCache: nil, darwinTemp: nil
        ))
        let coordinator = ScanCoordinator(scanners: [
            ApplicationLeftoversScanner(planner: planner), AIToolsScanner(home: sandbox.home)
        ])

        let absent = try await coordinator.scan()
        let leftovers = try #require(absent.categories.first { $0.categoryID == .applicationLeftovers })
        let group = try #require(leftovers.entries.first)
        #expect(group.removalAction == .orphanedApplication(bundleIdentifier: identifier))
        #expect(group.children.map(\.url) == [desktop])
        #expect(group.children.first?.protectionReason == .userData)
        #expect(leftovers.safeToRemoveBytes == 0)
        #expect(leftovers.needsReviewBytes == leftovers.totalBytes)
        #expect(absent.categories.first { $0.categoryID == .aiTools }?.entries.map(\.displayName) == ["Cursor project data"])
        #expect(absent.totalBytes == (try await ScanContext().measurer.measure(desktop)).allocatedBytes
            + (try await ScanContext().measurer.measure(sandbox.home.appendingPathComponent(".cursor/projects"))).allocatedBytes)

        let registered = try await coordinator.scan(context: ScanContext(
            registeredApplicationBundleIdentifiers: [identifier]
        ))
        #expect(registered.categories.first { $0.categoryID == .applicationLeftovers }?.entries.isEmpty == true)
        #expect(registered.categories.first { $0.categoryID == .aiTools }?.entries.contains { $0.url == desktop } == true)

        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": "Cursor",
                                   "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        let info = try sandbox.file("Applications/Cursor.app/Contents/Info.plist", bytes: 0)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        let installed = try await coordinator.scan()
        #expect(installed.categories.first { $0.categoryID == .applicationLeftovers }?.entries.isEmpty == true)
        #expect(installed.categories.first { $0.categoryID == .aiTools }?.entries.contains { $0.url == desktop } == true)
    }

    @Test("Absent roots, protected patterns, and symlink targets do not produce removal rows")
    func missingAndProtectedPaths() async throws {
        let sandbox = try Sandbox()
        #expect(try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext()).availability == .empty)
        let external = try sandbox.file("outside/feature/Cache/data")
        try FileManager.default.createSymbolicLink(at: sandbox.home.appendingPathComponent(".codex"),
                                                  withDestinationURL: external.deletingLastPathComponent())
        try sandbox.file(".claude/projects/private.keychain-db")
        try sandbox.file("Library/Application Support/Claude/Cookies")
        let partition = sandbox.home.appendingPathComponent("Library/Application Support/Claude/Partitions")
        try FileManager.default.createSymbolicLink(at: partition,
                                                  withDestinationURL: external.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        let result = try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext(excludedPatterns: ["*.keychain-db"]))
        #expect(result.entries.map(\.displayName) == ["Claude desktop data"])
        #expect(result.entries.first?.children.isEmpty == true)
        #expect(result.safeToRemoveBytes == 0)
    }

    @Test("Unreadable AI folders report a measurement gap and remain claimed")
    func unreadableStorage() async throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file(".claude/projects/task.jsonl")
        let folder = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let result = try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext())
        #expect(result.unreadableCount > 0)
        #expect(result.claimedStoragePaths.contains(sandbox.home.appendingPathComponent(".claude").path))
        #expect(result.safeToRemoveBytes == 0)
    }
}
