import Foundation
import Testing
@testable import MoppoCore

@Suite("Application data folders with other names")
struct ApplicationDataFoldersTests {
    /// Layouts from the #216 manifests of 3 November 2026: names and types only.
    /// The VoiceInk folder was empty. The fixture adds one file to give it a size.
    static let layouts: [(app: String, identifier: String, folders: [String], files: [String])] = [
        ("AnythingLLM", "com.anythingllm", ["Library/Application Support/anythingllm-desktop"],
         ["Library/Application Support/anythingllm-desktop/storage/anythingllm.db",
          "Library/Application Support/anythingllm-desktop/Code Cache/js/index"]),
        ("Cherry Studio", "com.kangfenmao.CherryStudio", ["Library/Application Support/CherryStudio", ".cherrystudio"],
         ["Library/Application Support/CherryStudio/Data/cherrystudio.sqlite",
          "Library/Application Support/CherryStudio/Code Cache/js/index", ".cherrystudio/bin/uv"]),
        ("Stability Matrix", "ai.lykos.stabilitymatrix", ["Library/Application Support/StabilityMatrix"],
         ["Library/Application Support/StabilityMatrix/global.json",
          "Library/Application Support/StabilityMatrix/Logs/app.log"]),
        ("VoiceInk", "com.prakashjoshipax.VoiceInk", ["Library/Application Support/VoiceInk"],
         ["Library/Application Support/VoiceInk/fixture"]),
        ("T3 Code (Beta)", "com.t3tools.t3code", ["Library/Application Support/t3code-v2"],
         ["Library/Application Support/t3code-v2/Local Storage/leveldb/000003.log",
          "Library/Application Support/t3code-v2/Cache/Cache_Data/data_0"]),
        ("DBeaver", "org.jkiss.dbeaver.core.product", ["Library/DBeaverData"],
         ["Library/DBeaverData/workspace6/General/.dbeaver/data-sources.json"]),
        ("superwhisper", "com.superduper.superwhisper", ["Library/Application Support/superwhisper", "superwhisper"],
         ["Library/Application Support/superwhisper/database/superwhisper.sqlite",
          "superwhisper/settings/settings.json", "superwhisper/modes/default.json"])
    ]

    /// DBeaver keeps database connections. Moppo never offers its folder. See `DatabaseStorage`.
    static let databaseApps: Set<String> = ["DBeaver"]

    private final class Sandbox {
        let home: URL
        let applications: URL

        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("moppo-data-folders-\(UUID().uuidString)", isDirectory: true)
            applications = home.appendingPathComponent("Applications", isDirectory: true)
            try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: home) }

        func file(_ relative: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 1024 * 1024).write(to: url)
        }

        func layouts() throws {
            for file in ApplicationDataFoldersTests.layouts.flatMap(\.files) { try self.file(file) }
        }

        func install(_ name: String, identifier: String) throws {
            let contents = applications.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
            try Data(count: 2 * 1024 * 1024).write(to: contents.appendingPathComponent("MacOS/\(name)"))
            let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name,
                                        "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
        }

        func url(_ relative: String) -> URL {
            home.appendingPathComponent(relative, isDirectory: true).standardizedFileURL
        }

        func pathPlanner() -> AppUninstallPlanner {
            AppUninstallPlanner(home: home, systemLibrary: home.appendingPathComponent("SystemLibrary"),
                                applicationRoots: [applications], darwinCache: nil, darwinTemp: nil)
        }

        func coordinator() -> ScanCoordinator {
            ScanCoordinator(scanners: [
                ApplicationsScanner(applicationDirectories: [applications], home: home, soundLibraries: nil),
                ApplicationLeftoversScanner(planner: OrphanedAppLeftoverPlanner(pathPlanner: pathPlanner())),
                AIToolsScanner(home: home, applications: applications)
            ])
        }
    }

    @Test("Each folder appears once: with its application, or in its leftover group after removal")
    func foldersFollowTheirApplication() async throws {
        let sandbox = try Sandbox()
        try sandbox.layouts()
        let measurer = ScanContext().measurer

        let removed = try await sandbox.coordinator().scan()
        let leftovers = try #require(removed.categories.first { $0.categoryID == .applicationLeftovers })
        var expectedBytes: Int64 = 0
        for layout in Self.layouts where !Self.databaseApps.contains(layout.app) {
            let group = try #require(leftovers.entries.first {
                $0.removalAction == .orphanedApplication(bundleIdentifier: layout.identifier)
            }, "\(layout.app)")
            #expect(Set(group.children.map(\.url)) == Set(layout.folders.map(sandbox.url)), "\(layout.app)")
            #expect(group.children.allSatisfy { $0.protectionReason == .userData }, "\(layout.app)")
            for folder in layout.folders { expectedBytes += try await measurer.measure(sandbox.url(folder)).allocatedBytes }
        }
        #expect(leftovers.entries.count == Self.layouts.count - Self.databaseApps.count)
        #expect(leftovers.safeToRemoveBytes == 0)
        // AI Tools does not list a folder that a leftover group lists.
        #expect(removed.categories.first { $0.categoryID == .aiTools }?.entries.isEmpty != false)
        #expect(removed.totalBytes == expectedBytes)

        for layout in Self.layouts { try sandbox.install(layout.app, identifier: layout.identifier) }
        let installed = try await sandbox.coordinator().scan()
        #expect(installed.categories.first { $0.categoryID == .applicationLeftovers }?.entries.isEmpty != false)
        let applications = try #require(installed.categories.first { $0.categoryID == .applications })
        let claimed = Set(installed.categories.first { $0.categoryID == .aiTools }?.claimedStoragePaths ?? [])
        for layout in Self.layouts {
            let row = try #require(applications.entries.first { $0.displayName == layout.app }, "\(layout.app)")
            for folder in layout.folders.map(sandbox.url) {
                // AI Tools shows the folders that it claims. The application row shows the others.
                let child = row.children.first { $0.url == folder }
                #expect((child == nil) == claimed.contains(folder.path), "\(folder.path)")
                let reason: FileEntry.ProtectionReason = Self.databaseApps.contains(layout.app) ? .inventory : .userData
                #expect(child.map { $0.protectionReason == reason } ?? true, "\(folder.path)")
            }
        }
        #expect(applications.safeToRemoveBytes == 0)
    }

    @Test("App Uninstaller lists each folder as user data, and keeps database folders")
    func uninstallReviewListsFolders() async throws {
        let sandbox = try Sandbox()
        try sandbox.layouts()
        for layout in Self.layouts {
            try sandbox.install(layout.app, identifier: layout.identifier)
            let plan = try await sandbox.pathPlanner().plan(
                applicationURL: sandbox.applications.appendingPathComponent("\(layout.app).app")
            )
            if Self.databaseApps.contains(layout.app) {
                #expect(plan.preservedPaths.map(\.url) == layout.folders.map(sandbox.url), "\(layout.app)")
                #expect(!plan.items.contains { layout.folders.map(sandbox.url).contains($0.url) })
                continue
            }
            for folder in layout.folders.map(sandbox.url) {
                let item = try #require(plan.items.first { $0.url == folder }, "\(folder.path)")
                #expect(item.content == .userData)
                #expect(item.isProtectedUserData)
                #expect(AppUninstallPlanner.removalIsStillSafe(
                    item, in: plan, exclusiveBundleIdentifiers: [layout.identifier]
                ))
            }
            #expect(plan.preservedPaths.isEmpty, "\(layout.app)")
            #expect(plan.reviewTitle == "Complete uninstall", "\(layout.app)")
        }
    }

    @Test("A home folder without its layout files is not evidence of an application")
    func homeFolderNeedsItsLayout() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("superwhisper/notes.txt")
        let planner = OrphanedAppLeftoverPlanner(pathPlanner: sandbox.pathPlanner())

        #expect(try await planner.plan().groups.isEmpty)

        try sandbox.file("superwhisper/settings/settings.json")
        try sandbox.file("superwhisper/modes/default.json")
        let group = try #require(try await planner.plan().groups.first)
        #expect(group.items.map(\.url) == [sandbox.url("superwhisper")])
    }

    @Test("A named folder outside the library does not allow its parent folder or a link")
    func namedFolderBoundary() throws {
        let sandbox = try Sandbox()
        let folder = sandbox.url("superwhisper")
        let folders = [folder]

        #expect(AppUninstallPlanner.relatedRoot(of: folder, roots: [], folders: folders) == sandbox.home.standardizedFileURL)
        #expect(AppUninstallPlanner.relatedRoot(of: folder.appendingPathComponent("recordings"), roots: [], folders: folders) != nil)
        #expect(AppUninstallPlanner.relatedRoot(of: sandbox.url("Documents"), roots: [], folders: folders) == nil)
        #expect(AppUninstallPlanner.relatedRoot(of: sandbox.url("superwhisper-old"), roots: [], folders: folders) == nil)

        try sandbox.file("elsewhere/settings/settings.json")
        try sandbox.file("elsewhere/modes/default.json")
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: sandbox.url("elsewhere"))
        #expect(!sandbox.pathPlanner().candidateIsSafe(folder))
    }
}
