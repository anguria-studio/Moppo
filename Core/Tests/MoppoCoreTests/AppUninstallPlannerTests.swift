import Foundation
import Synchronization
import Testing
@testable import MoppoCore

@Suite("Application uninstall planning")
struct AppUninstallPlannerTests {

    private final class Sandbox {
        let root: URL
        let home: URL
        let applications: URL
        let userApplications: URL
        let systemLibrary: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("moppo-uninstall-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            applications = root.appendingPathComponent("Applications", isDirectory: true)
            userApplications = home.appendingPathComponent("Applications", isDirectory: true)
            systemLibrary = root.appendingPathComponent("Library", isDirectory: true)
            for directory in [home, applications, userApplications, systemLibrary] {
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true
                )
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func application(
            _ name: String,
            identifier: String?,
            under root: URL? = nil
        ) throws -> URL {
            let url = (root ?? applications).appendingPathComponent("\(name).app", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var plist: [String: Any] = [
                "CFBundleName": name,
                "CFBundlePackageType": "APPL",
                "CFBundleVersion": "1",
            ]
            if let identifier { plist["CFBundleIdentifier"] = identifier }
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0
            )
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }

        @discardableResult
        func write(_ relativePath: String, bytes: Int = 4_096) throws -> URL {
            let url = home.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        /// An application extension in `Contents/PlugIns` of `application`.
        func appExtension(_ name: String, identifier: String, in application: URL) throws -> URL {
            let url = application.appendingPathComponent("Contents/PlugIns/\(name).appex", isDirectory: true)
            let contents = url.appendingPathComponent("Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist: [String: Any] = [
                "CFBundleName": name, "CFBundleIdentifier": identifier, "CFBundlePackageType": "XPC!",
            ]
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: contents.appendingPathComponent("Info.plist"))
            return url
        }

        /// Gives `bundle` an executable and signs it ad hoc with the app groups in `groups`.
        /// Sign nested bundles before the bundle that holds them.
        func sign(_ bundle: URL, groups: [String]) throws {
            let name = bundle.deletingPathExtension().lastPathComponent
            let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
            var plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
            plist["CFBundleExecutable"] = name
            try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                .write(to: plistURL)
            let executables = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
            try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: "/usr/bin/true"), to: executables.appendingPathComponent(name)
            )
            var arguments = ["--force", "--sign", "-"]
            if !groups.isEmpty {
                let entitlements = root.appendingPathComponent("\(UUID().uuidString).entitlements")
                try PropertyListSerialization.data(
                    fromPropertyList: ["com.apple.security.application-groups": groups],
                    format: .xml, options: 0
                ).write(to: entitlements)
                arguments += ["--entitlements", entitlements.path]
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            process.arguments = arguments + [bundle.path]
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }

        func planner() -> AppUninstallPlanner {
            AppUninstallPlanner(
                home: home,
                systemLibrary: systemLibrary,
                applicationRoots: [applications, userApplications],
                darwinCache: nil,
                darwinTemp: nil
            )
        }
    }

    @Test("a missing application has a distinct review failure")
    func missingApplication() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        try FileManager.default.removeItem(at: app)
        await #expect(throws: AppUninstallPlanningError.applicationMissing) {
            try await sandbox.planner().plan(applicationURL: app)
        }
        let invalid = try sandbox.write("not-an-application.txt")
        await #expect(throws: AppUninstallPlanningError.notAnApplication) {
            try await sandbox.planner().plan(applicationURL: invalid)
        }
    }

    enum PermanentResult: CaseIterable {
        case trashed, noConfirmation, declined, deleted, authorizationCancelled, changedDuringConfirmation, noDeletion, missingReply, relatedMeasurementFailure, newOwnerDuringApproval
    }

    @Test("permanent application removal requires consent and verified deletion", arguments: PermanentResult.allCases)
    func permanentApplicationRemoval(result: PermanentResult) async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/blob")
        let plan = try await sandbox.planner().plan(applicationURL: app)
        let parent = sandbox.applications
        let displaced = sandbox.root.appendingPathComponent("Original.app")
        let log = RemovalLog(directory: sandbox.root.appendingPathComponent("receipts"))
        try FileManager.default.setAttributes([.posixPermissions: result == .trashed ? 0o755 : 0o555], ofItemAtPath: parent.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            for record in log.recentEntries() {
                if let path = record.trashedPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        let service = CleanupService(measureSize: { url in
            if url != app, result == .relatedMeasurementFailure { throw CocoaError(.fileReadNoPermission) }
            return try await AllocatedSizeMeasurer().measure(url)
        }, log: log, applicationRemovalFallback: { url, stillMatches in
            #expect(result != .trashed && result != .noConfirmation && result != .declined && result != .changedDuringConfirmation)
            #expect(url == app)
            #expect(stillMatches())
            if result == .authorizationCancelled { throw ApplicationRemovalError.cancelled }
            if result == .noDeletion { return }
            if result == .missingReply { throw CocoaError(.fileNoSuchFile) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
            if result == .newOwnerDuringApproval {
                try FileManager.default.copyItem(at: url, to: parent.appendingPathComponent("Second Copy.app"))
            }
            try FileManager.default.removeItem(at: url)
        })
        let confirmation: @Sendable () async -> Bool = {
            #expect(result != .trashed)
            if result == .changedDuringConfirmation {
                do {
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path)
                    try FileManager.default.moveItem(at: app, to: displaced)
                    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
                } catch { Issue.record("Could not replace the fixture: \(error)") }
            }
            return result != .declined
        }
        let outcome = result == .noConfirmation
            ? try await service.uninstall(plan)
            : try await service.uninstall(plan, confirmPermanentRemoval: confirmation)
        let receipt = try #require(log.recentEntries().first { $0.originalPath == app.path })
        if result == .relatedMeasurementFailure || result == .newOwnerDuringApproval {
            #expect(outcome.deletedCount == 1)
            #expect(outcome.failed == plan.items.dropFirst().map { $0.url.path })
            #expect(receipt.disposition == .deleted)
            #expect(receipt.trashedPath == nil)
            #expect(FileManager.default.fileExists(atPath: cache.path))
        } else if result == .deleted || result == .trashed {
            #expect(outcome.failed.isEmpty)
            #expect(outcome.deletedCount == (result == .deleted ? 1 : 0))
            #expect(outcome.trashedCount == plan.items.count - outcome.deletedCount)
            #expect(receipt.disposition == (result == .deleted ? .deleted : .trashed))
            #expect((receipt.trashedPath == nil) == (result == .deleted))
            #expect(!FileManager.default.fileExists(atPath: cache.path))
        } else {
            #expect(outcome.failed == [app.path])
            #expect(outcome.removedCount == 0)
            #expect(outcome.applicationRemovalCancelled == (result == .noConfirmation || result == .declined || result == .authorizationCancelled))
            #expect(FileManager.default.fileExists(atPath: app.path))
            #expect(FileManager.default.fileExists(atPath: cache.path))
            #expect(receipt.disposition == .failed)
        }
    }

    @Test("an untrusted bundle identifier creates an application-only plan")
    func untrustedIdentifierKeepsRelatedFiles() async throws {
        let sandbox = try Sandbox()
        _ = try sandbox.write("Library/Caches/com.vendor.legacy/blob")

        for (name, identifier) in [
            ("Missing Identifier", nil),
            ("Invalid Identifier", "legacy"),
        ] as [(String, String?)] {
            let app = try sandbox.application(name, identifier: identifier)
            let plan = try await sandbox.planner().plan(applicationURL: app)

            #expect(plan.bundleIdentifier == nil)
            #expect(plan.isApplicationOnly)
            #expect(plan.items.map(\.url) == [app])
            #expect(plan.candidateBundleIdentifiers.isEmpty)
            #expect(plan.protectedItems.isEmpty)
            #expect(AppUninstallPlanner.removalIsStillSafe(
                plan.applicationItem,
                in: plan,
                exclusiveBundleIdentifiers: []
            ))
        }
    }

    @Test("exact bundle paths are classified without prefix or group-container guesses")
    func exactCandidatesOnly() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/blob")
            .deletingLastPathComponent()
        let support = try sandbox.write("Library/Application Support/com.vendor.editor/account.db")
            .deletingLastPathComponent()
        let preference = try sandbox.write("Library/Preferences/com.vendor.editor.plist")
        _ = try sandbox.write("Library/Preferences/com.vendor.editor.helper.plist")
        let sharedGroup = try sandbox.write(
            "Library/Group Containers/group.com.vendor.editor/shared.db"
        ).deletingLastPathComponent()
        let launchAgent = try sandbox.write("Library/LaunchAgents/com.vendor.editor.plist")
        let logs = try sandbox.write("Library/Logs/com.vendor.editor/today.log")
            .deletingLastPathComponent()

        let plan = try await sandbox.planner().plan(applicationURL: app)
        let paths = Set(plan.items.map(\.id))

        #expect(paths.contains(app.path))
        #expect(paths.contains(cache.path))
        #expect(paths.contains(support.path))
        #expect(paths.contains(preference.path))
        #expect(paths.contains(launchAgent.path))
        #expect(!paths.contains { $0.contains("editor.helper.plist") })
        #expect(!paths.contains { $0.contains("Group Containers") })
        let kept = try #require(plan.preservedPaths.first { $0.url == sharedGroup })
        #expect(kept.reason == .sharedGroupContainer)
        #expect((kept.allocatedBytes ?? 0) > 0)
        // Old log records do not come back, but logs are not user data.
        let logItem = try #require(plan.items.first { $0.id == logs.standardizedFileURL.path })
        #expect(logItem.content == .logs)
        #expect(!logItem.isProtectedUserData)
        #expect(logItem.fileEntry.kind == .folder)
        #expect(logItem.fileEntry.regenerationLabel == .notRegenerable(reason: FileEntry.NotRegenerable.logs.reason))
    }

    @Test("another installed copy keeps every shared bundle-owned path")
    func duplicateApplicationPreservesSharedData() async throws {
        let sandbox = try Sandbox()
        let selected = try sandbox.application("Editor", identifier: "com.vendor.editor")
        _ = try sandbox.application("Editor Copy", identifier: "com.vendor.editor")
        _ = try sandbox.write("Library/Caches/com.vendor.editor/blob")
        _ = try sandbox.write("Library/Preferences/com.vendor.editor.plist")

        let plan = try await sandbox.planner().plan(applicationURL: selected)

        #expect(plan.items.map(\.id) == [selected.path])
    }

    /// The RustDesk layout from the rented Mac for #56, 3 November 2026.
    @Test("launch files with another name join the application by program or associated identifier")
    func launchFilesWithOtherNames() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("RustDesk", identifier: "com.carriez.rustdesk")
        let other = try sandbox.application("Perplexity", identifier: "ai.perplexity.macv3")
        let otherProgram = other.appendingPathComponent("Contents/MacOS/perplexityd")
        try FileManager.default.createDirectory(
            at: otherProgram.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data().write(to: otherProgram)
        let agents = sandbox.systemLibrary.appendingPathComponent("LaunchAgents")
        let server = try writeLaunchItem(
            at: agents.appendingPathComponent("com.carriez.RustDesk_server.plist"),
            program: app.appendingPathComponent("Contents/MacOS/RustDesk").path,
            associated: "com.carriez.rustdesk"
        )
        let service = try writeLaunchItem(
            at: sandbox.systemLibrary.appendingPathComponent("LaunchDaemons/com.carriez.RustDesk_service.plist"),
            program: "/bin/sh", associated: "com.carriez.rustdesk"
        )
        // A similar name is not evidence. A program in another application keeps the file with it.
        try writeLaunchItem(at: agents.appendingPathComponent("com.carriez.RustDesk_helper.plist"), program: "/bin/sh")
        try writeLaunchItem(
            at: agents.appendingPathComponent("com.carriez.RustDesk_shared.plist"),
            program: otherProgram.path, associated: "com.carriez.rustdesk"
        )

        let plan = try await sandbox.planner().plan(applicationURL: app)
        let launchItems = plan.items.filter { $0.category == .helpers }

        #expect(Set(launchItems.map(\.id)) == [server.path, service.path])
        #expect(launchItems.allSatisfy { $0.content == .appComponent && $0.ownerBundleIdentifier == "com.carriez.rustdesk" })
    }

    /// The Comet layout from the rented Mac for #56, 3 November 2026. The program is missing there.
    @Test("a launch file that names an embedded updater joins only the application that contains it")
    func launchFileOfEmbeddedUpdater() async throws {
        let sandbox = try Sandbox()
        let comet = try sandbox.application("Comet", identifier: "ai.perplexity.comet")
        try sandbox.application(
            "CometUpdater", identifier: "ai.perplexity.CometUpdater",
            under: comet.appendingPathComponent("Contents/Frameworks/Comet Framework.framework/Versions/156.0.8078.130/Helpers")
        )
        let perplexity = try sandbox.application("Perplexity", identifier: "ai.perplexity.macv3")
        let wake = try writeLaunchItem(
            at: sandbox.home.appendingPathComponent("Library/LaunchAgents/ai.perplexity.CometUpdater.wake.plist"),
            program: sandbox.home.appendingPathComponent(
                "Library/Application Support/Perplexity/CometUpdater/Current/CometUpdater.app/Contents/MacOS/CometUpdater"
            ).path,
            associated: ["ai.perplexity.CometUpdater"]
        )

        let cometPlan = try await sandbox.planner().plan(applicationURL: comet)
        let perplexityPlan = try await sandbox.planner().plan(applicationURL: perplexity)

        let item = try #require(cometPlan.items.first { $0.id == wake.path })
        #expect(item.ownerBundleIdentifier == "ai.perplexity.CometUpdater")
        let exclusive = try AppUninstallPlanner.exclusiveBundleIdentifiers(
            candidates: Set(cometPlan.items.compactMap(\.ownerBundleIdentifier)),
            selectedApplication: comet, applicationRoots: [sandbox.applications, sandbox.userApplications],
            checkCancellation: {}
        )
        #expect(AppUninstallPlanner.removalIsStillSafe(item, in: cometPlan, exclusiveBundleIdentifiers: exclusive))
        #expect(!perplexityPlan.items.contains { $0.category == .helpers })
    }

    @Test("Batch reviews share current owners and one Homebrew lookup", arguments: [false, true])
    func batchOwnership(catalogFails: Bool) async throws {
        let sandbox = try Sandbox()
        let editor = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let duplicate = try sandbox.application("Editor Copy", identifier: "com.vendor.editor")
        let player = try sandbox.application("Player", identifier: "com.vendor.player")
        _ = try sandbox.write("Library/Caches/com.vendor.editor/shared")
        let cache = try sandbox.write("Library/Caches/com.vendor.player/private").deletingLastPathComponent()
        let lookups = Mutex(0)
        let planner = AppUninstallPlanner(
            home: sandbox.home, systemLibrary: sandbox.systemLibrary,
            applicationRoots: [sandbox.applications], darwinCache: nil, darwinTemp: nil,
            homebrewExecutable: "/fixture/brew", loadHomebrewCatalog: { _ in
                lookups.withLock { $0 += 1 }
                if catalogFails { throw CocoaError(.fileReadNoPermission) }
                return Data(#"{"casks":[]}"#.utf8)
            }
        )
        let diagnostics = try ScanDiagnostics(directory: sandbox.root.appendingPathComponent("diagnostics"))
        let results = try await ScanDiagnostics.$current.withValue(diagnostics.context) {
            try await planner.plans(
                applicationURLs: [editor, player], context: ScanContext(excludedPaths: [duplicate.path])
            )
        }
        diagnostics.finish(outcome: "completed")
        diagnostics.flush()
        #expect(lookups.withLock { $0 } == 1)
        #expect(results.count == 2)
        if catalogFails {
            for result in results {
                #expect(throws: AppUninstallPlanningError.packageOwnershipUnavailable) { try result.get() }
            }
        } else {
            #expect(try results[0].get().items.map(\.url) == [editor])
            #expect(try results[1].get().items.map(\.url) == [player, cache])
        }
        let records = try Data(contentsOf: diagnostics.fileURL).split(separator: 10).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let walks = records.filter {
            $0["event"] as? String == "span_start"
                && ($0["details"] as? [String: String])?["operation"] == "application_bundle_identifiers"
        }
        #expect(walks.count == 3)
    }

    @Test("Homebrew ownership requires one exact app artifact target")
    func homebrewOwnershipIsExact() throws {
        let data = Data(#"""
        {
          "casks": [
            {
              "token": "editor",
              "artifacts": [
                { "app": ["Editor.app"], "target": "/Applications/Editor.app" }
              ]
            },
            {
              "token": "editor-beta",
              "artifacts": [
                { "app": ["Editor.app"], "target": "/Applications Beta/Editor.app" }
              ]
            }
          ]
        }
        """#.utf8)

        let package = try #require(try AppUninstallPlanner.homebrewPackage(
            in: data,
            managing: URL(fileURLWithPath: "/Applications/Editor.app"),
            executable: "/opt/homebrew/bin/brew"
        ))

        #expect(package.name == "editor")
        #expect(package.manager == .homebrew)
        #expect(package.uninstallCommand
            == "/opt/homebrew/bin/brew uninstall --cask editor")
        #expect(try AppUninstallPlanner.homebrewPackage(
            in: data,
            managing: URL(fileURLWithPath: "/Applications/Other.app"),
            executable: "/opt/homebrew/bin/brew"
        ) == nil)
    }

    @Test("an embedded helper contributes only its exact identifier")
    func embeddedHelperIdentifiers() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let helpers = app.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        _ = try sandbox.application(
            "Background", identifier: "com.vendor.editor.background", under: helpers
        )
        let helperCache = try sandbox.write("Library/Caches/com.vendor.editor.background/blob")
            .deletingLastPathComponent()
        let outside = sandbox.home.appendingPathComponent("Outside")
        try sandbox.application("External", identifier: "com.vendor.editor.external", under: outside)
        try FileManager.default.createSymbolicLink(
            at: helpers.appendingPathComponent("LinkedFolder"), withDestinationURL: outside
        )
        _ = try sandbox.write("Library/Caches/com.vendor.editor.external/blob")

        let plan = try await sandbox.planner().plan(applicationURL: app)

        #expect(plan.items.contains { $0.url == helperCache })
        #expect(!plan.items.contains { $0.url.path.contains("com.vendor.editor.external") })
    }

    @Test("Cancellation interrupts discovery and ownership walks", arguments: [false, true])
    func cancelledOwnershipWalk(discovery: Bool) throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let resources = discovery
            ? sandbox.applications.appendingPathComponent("Vendor/Resources", isDirectory: true)
            : app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        for index in 0..<64 {
            try Data([0]).write(to: resources.appendingPathComponent("resource-\(index)"))
        }
        var checkpoints = 0
        #expect(throws: CancellationError.self) {
            let checkCancellation = {
                checkpoints += 1
                if checkpoints == 8 { throw CancellationError() }
            }
            if discovery {
                _ = try AppUninstallPlanner.installedApplications(
                    in: [sandbox.applications], fileManager: .default,
                    checkCancellation: checkCancellation
                )
            } else {
                _ = try AppUninstallPlanner.installedBundleIdentifiers(
                    in: [sandbox.applications], checkCancellation: checkCancellation
                )
            }
        }
        #expect(checkpoints == 8)
    }

    @Test("Applications and Application Leftovers walk each bundle once in one scan")
    func cleanupCategoriesShareBundleWalks() async throws {
        let sandbox = try Sandbox()
        for index in 0..<6 {
            let app = try sandbox.application("Editor\(index)", identifier: "com.vendor.editor\(index)")
            let helpers = app.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
            try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
            try sandbox.application("Helper", identifier: "com.vendor.editor\(index).helper", under: helpers)
        }
        try sandbox.application("Tool", identifier: "com.vendor.tool", under: sandbox.userApplications)
        let coordinator = ScanCoordinator(scanners: [
            ApplicationsScanner(
                applicationDirectories: [sandbox.applications, sandbox.userApplications],
                home: sandbox.home, soundLibraries: nil
            ),
            ApplicationLeftoversScanner(planner: OrphanedAppLeftoverPlanner(pathPlanner: sandbox.planner())),
        ])
        let diagnostics = try ScanDiagnostics(directory: sandbox.root.appendingPathComponent("diagnostics"))
        _ = try await ScanDiagnostics.$current.withValue(diagnostics.context) {
            try await coordinator.scan()
        }
        diagnostics.finish(outcome: "completed")
        diagnostics.flush()

        let records = try Data(contentsOf: diagnostics.fileURL).split(separator: 10).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let walkedPaths = records.compactMap { record -> String? in
            guard record["event"] as? String == "span_start",
                  let details = record["details"] as? [String: String],
                  details["operation"] == "application_bundle_identifiers" else { return nil }
            return details["path"]
        }
        #expect(walkedPaths.count == 7)
        #expect(Set(walkedPaths).count == 7)
    }

    @Test("A failed bundle walk keeps no result, so the next caller walks again")
    func failedBundleWalkIsRepeated() async throws {
        let walks = ApplicationBundleWalks()
        let app = URL(fileURLWithPath: "/Applications/Editor.app")
        await #expect(throws: CancellationError.self) {
            try await walks.identifiers(in: [app]) { _ in throw CancellationError() }
        }
        let identifiers = try await walks.identifiers(in: [app]) { _ in ["com.vendor.editor"] }
        #expect(identifiers == ["com.vendor.editor"])
    }

    @Test("Cleanup ownership scans reject cancellation before traversal", arguments: [
        CategoryID.applications, .applicationLeftovers
    ])
    func cancelledOwnershipScans(category: CategoryID) async throws {
        let sandbox = try Sandbox()
        try sandbox.application("Editor", identifier: "com.vendor.editor")
        let task = Task<Void, Error> {
            withUnsafeCurrentTask { $0?.cancel() }
            if category == .applications {
                _ = try await ApplicationsScanner(
                    applicationDirectories: [sandbox.applications], home: sandbox.home, soundLibraries: nil
                ).scan(context: ScanContext())
            } else {
                _ = try await OrphanedAppLeftoverPlanner(pathPlanner: sandbox.planner()).plan()
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test("known nonstandard Electron roots split caches from profiles")
    func knownCurationIsSharedWithTheScanner() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Visual Studio Code", identifier: "com.microsoft.VSCode")
        let cache = try sandbox.write("Library/Application Support/Code/Code Cache/index")
            .deletingLastPathComponent()
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Code")
        _ = try sandbox.write("Library/Application Support/Code/User/settings.json")

        let plan = try await sandbox.planner().plan(applicationURL: app)
        let cacheItem = try #require(plan.items.first { $0.url == cache })
        let remainder = try #require(plan.items.first {
            $0.url == support && $0.content == .userData
        })

        #expect(cacheItem.content == .regenerable)
        #expect(remainder.displayName == "Visual Studio Code settings and data")

        // Moving the real support root necessarily carries anything nested inside
        // it. The plan moves the child first so both rows receive honest receipts.
        let order = plan.removalOrder()
        let cacheIndex = try #require(order.firstIndex(of: cacheItem))
        let remainderIndex = try #require(order.firstIndex(of: remainder))
        #expect(cacheIndex < remainderIndex)
    }

    @Test("an excluded related path is preserved and disclosed")
    func exclusionsRemainAbsolute() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/blob")
            .deletingLastPathComponent()
        let context = ScanContext(excludedPaths: [cache.path])

        let plan = try await sandbox.planner().plan(applicationURL: app, context: context)

        #expect(!plan.items.contains { $0.url == cache })
        // An excluded path is not measured.
        #expect(plan.preservedPaths == [.init(url: cache, reason: .excluded)])
    }

    @Test("a kept path that Moppo cannot read has no size, not 0 B")
    func unreadablePreservedPathHasNoSize() {
        let url = URL(fileURLWithPath: "/Library/Group Containers/group.com.vendor.editor")
        let unread = AppUninstallPlan.PreservedPath(
            url: url, reason: .sharedGroupContainer,
            measurement: SizeMeasurement(allocatedBytes: 0, unreadableCount: 1)
        )
        let partial = AppUninstallPlan.PreservedPath(
            url: url, reason: .sharedGroupContainer,
            measurement: SizeMeasurement(allocatedBytes: 4096, unreadableCount: 1)
        )
        #expect(unread.allocatedBytes == nil)
        #expect(partial.allocatedBytes == 4096)
    }

    @Test("a support folder with database files is preserved and disclosed")
    func databaseDataIsPreserved() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("DBngin", identifier: "com.tinyapp.DBngin")
        let support = try sandbox.write("Library/Application Support/com.tinyapp.DBngin/Engines/postgresql/A1/PG_VERSION")
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cache = try sandbox.write("Library/Caches/com.tinyapp.DBngin/Cache.db").deletingLastPathComponent()

        let plan = try await sandbox.planner().plan(applicationURL: app)

        #expect(plan.items.map(\.url) == [app, cache])
        #expect(plan.preservedPaths.map(\.url) == [support])
        #expect(plan.preservedPaths.first?.reason == .databaseData)
        #expect((plan.preservedPaths.first?.allocatedBytes ?? 0) > 0)
        #expect(plan.reviewTitle == "Partial uninstall")
        #expect(plan.reviewDetail.hasSuffix(" 1 related path stays on disk."))
    }

    @Test("the app bundle is always first, before protected data")
    func removalOrderStartsWithApplication() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        _ = try sandbox.write("Library/Application Support/com.vendor.editor/profile.db")
        _ = try sandbox.write("Library/Caches/com.vendor.editor/blob")
        let plan = try await sandbox.planner().plan(applicationURL: app)

        let order = plan.removalOrder()

        #expect(order.first?.url == app)
        #expect(order.dropFirst().contains { $0.content == .userData })
    }

    @Test("a replacement at a reviewed path is refused by filesystem identity")
    func replacementPathIsNotTheReviewedItem() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let cache = try sandbox.write("Library/Caches/com.vendor.editor/old")
            .deletingLastPathComponent()
        let plan = try await sandbox.planner().plan(applicationURL: app)
        let item = try #require(plan.items.first { $0.url == cache })

        try FileManager.default.removeItem(at: cache)
        _ = try sandbox.write("Library/Caches/com.vendor.editor/replacement")
        let exclusive = try AppUninstallPlanner.exclusiveBundleIdentifiers(
            candidates: plan.candidateBundleIdentifiers,
            selectedApplication: plan.applicationURL,
            applicationRoots: plan.applicationRoots,
            checkCancellation: Task.checkCancellation
        )

        #expect(!AppUninstallPlanner.removalIsStillSafe(
            item, in: plan, exclusiveBundleIdentifiers: exclusive
        ))
    }

    @Test("a changed app bundle stops the uninstall before related data")
    func applicationFailureIsATransactionGate() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let supportFile = try sandbox.write(
            "Library/Application Support/com.vendor.editor/profile.db"
        )
        let plan = try await sandbox.planner().plan(applicationURL: app)

        // Replace the reviewed bundle at the same path. The location still looks
        // right, but it is no longer the filesystem object the user reviewed.
        try FileManager.default.moveItem(
            at: app, to: sandbox.root.appendingPathComponent("reviewed-bundle")
        )
        _ = try sandbox.application("Editor", identifier: "com.vendor.editor")

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log")),
            applicationRemovalFallback: { _, _ in
                Issue.record("A changed application must not request authorization.")
                throw CocoaError(.fileWriteUnknown)
            }
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [app.path])
        #expect(FileManager.default.fileExists(atPath: supportFile.path))
    }

    @Test("a failed child cannot be carried away by its containing parent")
    func changedChildProtectsItsContainingFolder() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application(
            "Visual Studio Code", identifier: "com.microsoft.VSCode"
        )
        let cache = try sandbox.write(
            "Library/Application Support/Code/Code Cache/index"
        ).deletingLastPathComponent()
        let settings = try sandbox.write(
            "Library/Application Support/Code/User/settings.json"
        )
        let support = sandbox.home.appendingPathComponent("Library/Application Support/Code")
        let plan = try await sandbox.planner().plan(applicationURL: app)
        #expect(plan.items.contains {
            $0.url == support && $0.content == .userData
        })

        // A missing app already satisfies the requested app-removal state, but a
        // replacement inside the reviewed support tree is a different object and
        // must survive even when the containing remainder is part of the plan.
        try FileManager.default.moveItem(
            at: app, to: sandbox.root.appendingPathComponent("already-removed-app")
        )
        try FileManager.default.moveItem(
            at: cache, to: sandbox.root.appendingPathComponent("reviewed-cache")
        )
        let replacement = try sandbox.write(
            "Library/Application Support/Code/Code Cache/replacement"
        )

        let outcome = try await CleanupService(
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log"))
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed.contains(cache.path))
        #expect(outcome.failed.contains(support.path))
        #expect(FileManager.default.fileExists(atPath: replacement.path))
        #expect(FileManager.default.fileExists(atPath: settings.path))
    }

    @Test("system identifiers and symbolic-link applications are refused")
    func protectedAndSymbolicApplicationsAreRefused() async throws {
        let sandbox = try Sandbox()
        let system = try sandbox.application("System", identifier: "com.apple.systemtool")
        await #expect(throws: AppUninstallPlanningError.protectedApplication) {
            _ = try await sandbox.planner().plan(applicationURL: system)
        }

        let real = try sandbox.application("Real", identifier: "com.vendor.real")
        let link = sandbox.applications.appendingPathComponent("Linked.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        await #expect(throws: AppUninstallPlanningError.symbolicLink) {
            _ = try await sandbox.planner().plan(applicationURL: link)
        }
    }

    @Test("the installed list offers exactly what a plan would accept")
    func installedApplicationsMatchThePlanner() async throws {
        let sandbox = try Sandbox()
        try sandbox.application("Zed", identifier: "com.vendor.zed")
        try sandbox.application("alpha", identifier: "com.vendor.alpha",
                                under: sandbox.userApplications)
        try sandbox.application("No Identifier", identifier: nil)
        try sandbox.application("System", identifier: "com.apple.systemtool")
        try sandbox.application("Moppo", identifier: "com.tommasolaterza.Moppo")
        let excluded = try sandbox.application("Excluded", identifier: "com.vendor.excluded")
        let real = try sandbox.application("Real", identifier: "com.vendor.real")
        try FileManager.default.createSymbolicLink(
            at: sandbox.applications.appendingPathComponent("Linked.app"),
            withDestinationURL: real
        )
        // Application discovery includes all folder depths.
        let vendor = sandbox.applications.appendingPathComponent("Vendor", isDirectory: true)
        try sandbox.application("Nested", identifier: "com.vendor.nested", under: vendor)
        try sandbox.application(
            "Buried", identifier: "com.vendor.buried",
            under: vendor.appendingPathComponent("Deeper/ACC", isDirectory: true)
        )
        try sandbox.application(
            "User Nested", identifier: "com.vendor.user",
            under: sandbox.userApplications.appendingPathComponent("Tools/Vendor/Current")
        )
        try sandbox.application(
            "Embedded", identifier: "com.vendor.real.helper",
            under: real.appendingPathComponent("Contents/Library/LoginItems")
        )
        try sandbox.application(
            "Invisible", identifier: "com.vendor.invisible",
            under: vendor.appendingPathComponent(".Hidden")
        )
        try sandbox.application(".Hidden", identifier: "com.vendor.hiddenapp")
        try sandbox.application(
            "Pattern", identifier: "com.vendor.pattern", under: vendor.appendingPathComponent("Folder.skip")
        )
        // An exclusion inside this bundle must not hide applications in sibling folders.
        let guarded = try sandbox.application("Guarded", identifier: "com.vendor.guarded", under: vendor)
        // Excluding this folder must keep all its applications out of the list.
        let shut = sandbox.applications.appendingPathComponent("Shut", isDirectory: true)
        try sandbox.application("Hidden", identifier: "com.vendor.hidden", under: shut)
        // A link out of the root is not a vendor folder.
        let outside = sandbox.home.appendingPathComponent("Elsewhere", isDirectory: true)
        try sandbox.application("Outsider", identifier: "com.vendor.outsider", under: outside)
        try FileManager.default.createSymbolicLink(
            at: sandbox.applications.appendingPathComponent("LinkedFolder"),
            withDestinationURL: outside
        )

        let context = ScanContext(
            excludedPaths: [excluded.path, shut.path, guarded.appendingPathComponent("Contents").path],
            excludedPatterns: ["*.skip"]
        )
        let listed = sandbox.planner().installedApplications(context: context)

        #expect(listed.map(\.name) == ["alpha", "Buried", "Nested", "No Identifier", "Real", "User Nested", "Zed"])
        #expect(listed.first { $0.name == "No Identifier" }?.bundleIdentifier == nil)
        // Every card must open a review: nothing listed may be refused by the plan.
        for application in listed {
            _ = try await sandbox.planner().plan(applicationURL: application.url, context: context)
        }
    }

    // MARK: - Apple identifiers

    /// A bundle with the App Store's receipt in it, as Pages or Xcode has.
    private static func addAppStoreReceipt(to application: URL) throws {
        let receipt = application.appendingPathComponent("Contents/_MASReceipt/receipt")
        try FileManager.default.createDirectory(
            at: receipt.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0x30, count: 64).write(to: receipt)
    }

    /// `com.apple.` was refused outright until 19 Sep 2026, which on a real Mac
    /// refused Pages, Numbers, Keynote, iMovie and Xcode — App Store installs — and
    /// nothing else: system applications are not in `/Applications` to be refused.
    @Test("an Apple application is offered on an App Store receipt, and refused without one")
    func appleApplicationsNeedAReceipt() async throws {
        let sandbox = try Sandbox()
        let pages = try sandbox.application("Pages", identifier: "com.apple.iWork.Pages")
        try Self.addAppStoreReceipt(to: pages)
        let unknown = try sandbox.application("Unknown", identifier: "com.apple.unknowntool")

        let listed = sandbox.planner().installedApplications()
        #expect(listed.map(\.name) == ["Pages"])
        _ = try await sandbox.planner().plan(applicationURL: pages)
        await #expect(throws: AppUninstallPlanningError.protectedApplication) {
            _ = try await sandbox.planner().plan(applicationURL: unknown)
        }
    }

    @Test("under an Apple identifier only the exact name is matched, and the shared group stays")
    func appleApplicationMatchesItsExactIdentifierOnly() async throws {
        let sandbox = try Sandbox()
        let pages = try sandbox.application("Pages", identifier: "com.apple.iWork.Pages")
        try Self.addAppStoreReceipt(to: pages)
        // Embedded, and named beneath the application — a vendor's helper would be
        // claimed by the prefix rule. Under `com.apple.` it is not.
        try sandbox.application(
            "Helper", identifier: "com.apple.iWork.Pages.helper",
            under: pages.appendingPathComponent("Contents/Library/LoginItems", isDirectory: true)
        )
        _ = try sandbox.write("Library/Caches/com.apple.iWork.Pages/blob")
        _ = try sandbox.write("Library/Caches/com.apple.iWork.Pages.helper/blob")
        _ = try sandbox.write("Library/Caches/com.apple.iWork.Numbers/blob")
        _ = try sandbox.write("Library/Group Containers/group.com.apple.iWork.Pages/shared.db")

        let plan = try await sandbox.planner().plan(applicationURL: pages)
        let paths = plan.items.map(\.url.path)

        #expect(!plan.isApplicationOnly)
        #expect(paths.contains { $0.hasSuffix("/Library/Caches/com.apple.iWork.Pages") })
        #expect(!paths.contains { $0.contains("com.apple.iWork.Pages.helper") })
        #expect(!paths.contains { $0.contains("com.apple.iWork.Numbers") })
        #expect(!paths.contains { $0.contains("/Group Containers/") })
        #expect(plan.preservedPaths.contains { $0.url.path.contains("group.com.apple.iWork.Pages") })
    }

    // MARK: App group containers

    @Test("a group container that only the application and its extension claim is protected user data")
    func exclusiveGroupContainers() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let share = try sandbox.appExtension("Share", identifier: "com.vendor.editor.share", in: app)
        try sandbox.sign(share, groups: ["group.com.vendor.editor.shared"])
        try sandbox.sign(app, groups: ["group.com.vendor.editor"])
        let containers = try ["group.com.vendor.editor", "group.com.vendor.editor.shared"].map {
            try sandbox.write("Library/Group Containers/\($0)/shared.db").deletingLastPathComponent()
        }

        let plan = try await sandbox.planner().plan(applicationURL: app)

        for container in containers {
            let item = try #require(plan.items.first { $0.id == container.standardizedFileURL.path })
            #expect(item.isProtectedUserData)
            #expect(item.category == .containers)
        }
        #expect(plan.preservedPaths.isEmpty)
        #expect(plan.reviewTitle == "Complete uninstall")
    }

    @Test("a group that another installed application claims stays on disk")
    func groupClaimedByAnotherApplication() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        try sandbox.sign(app, groups: ["group.com.vendor.editor", "group.com.vendor.editor.family"])
        let writer = try sandbox.application(
            "Writer", identifier: "com.vendor.writer", under: sandbox.userApplications
        )
        try sandbox.sign(writer, groups: ["group.com.vendor.editor.family"])
        let own = try sandbox.write("Library/Group Containers/group.com.vendor.editor/shared.db")
            .deletingLastPathComponent()
        let family = try sandbox.write("Library/Group Containers/group.com.vendor.editor.family/shared.db")
            .deletingLastPathComponent()

        let plan = try await sandbox.planner().plan(applicationURL: app)

        #expect(plan.items.contains { $0.id == own.standardizedFileURL.path && $0.isProtectedUserData })
        #expect(!plan.items.contains { $0.id == family.standardizedFileURL.path })
        #expect(plan.preservedPaths.map(\.url) == [family.standardizedFileURL])
        let kept = try #require(plan.preservedPaths.first)
        #expect(kept.reason == .sharedGroupContainer)
        #expect(kept.claimingApplications == [writer.standardizedFileURL])
        #expect(kept.optInItem?.isProtectedUserData == true)
        #expect(plan.reviewTitle == "Partial uninstall")
    }

    enum MissingGroupEvidence: CaseIterable { case signature, inventory }

    @Test("a group container stays when Moppo cannot read all of the evidence", arguments: MissingGroupEvidence.allCases)
    func incompleteGroupEvidence(_ missing: MissingGroupEvidence) async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        try sandbox.sign(app, groups: ["group.com.vendor.editor"])
        let container = try sandbox.write("Library/Group Containers/group.com.vendor.editor/shared.db")
            .deletingLastPathComponent()
        let unreadable: URL
        switch missing {
        case .signature:
            let writer = try sandbox.application("Writer", identifier: "com.vendor.writer")
            try sandbox.sign(writer, groups: [])
            unreadable = writer.appendingPathComponent("Contents/MacOS/Writer")
        case .inventory:
            unreadable = sandbox.applications.appendingPathComponent("Vendor", isDirectory: true)
            try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
        }

        let plan = try await sandbox.planner().plan(applicationURL: app)

        #expect(!plan.items.contains { $0.id == container.standardizedFileURL.path })
        #expect(plan.preservedPaths.map(\.url) == [container.standardizedFileURL])
        let kept = try #require(plan.preservedPaths.first)
        #expect(kept.reason == .sharedGroupContainer)
        #expect(kept.claimingApplications == nil)
        #expect(kept.optInItem != nil)
    }

    @Test("an exclusive group container that Moppo cannot read stays on disk with its reason")
    func unreadableExclusiveGroupContainer() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        try sandbox.sign(app, groups: ["group.com.vendor.editor"])
        let container = try sandbox.write("Library/Group Containers/group.com.vendor.editor/shared.db")
            .deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: container.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
        }

        let plan = try await sandbox.planner().plan(applicationURL: app)

        #expect(!plan.items.contains { $0.id == container.standardizedFileURL.path })
        let kept = try #require(plan.preservedPaths.first)
        #expect(kept.url == container.standardizedFileURL)
        #expect(kept.reason == .unreadable)
        #expect(plan.reviewTitle == "Partial uninstall")
    }

    @Test("an application that claims the group after the review stops the container removal")
    func groupOwnerInstalledAfterReview() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        try sandbox.sign(app, groups: ["group.com.vendor.editor"])
        let container = try sandbox.write("Library/Group Containers/group.com.vendor.editor/shared.db")
            .deletingLastPathComponent()
        let plan = try await sandbox.planner().plan(applicationURL: app)
        #expect(plan.items.contains { $0.id == container.standardizedFileURL.path })
        let claims = ApplicationGroupClaims.applicationRootsOnly
        #expect(try await claims.groupsClaimedElsewhere(
            ["group.com.vendor.editor"], selectedApplication: app,
            applicationRoots: plan.applicationRoots, identifiers: []
        ).isEmpty)

        let writer = try sandbox.application("Writer", identifier: "com.vendor.writer")
        try sandbox.sign(writer, groups: ["group.com.vendor.editor"])
        // The application is already gone, so the test does not use the real Trash.
        try FileManager.default.moveItem(at: app, to: sandbox.root.appendingPathComponent("removed-app"))
        let outcome = try await CleanupService(
            measureSize: { try await AllocatedSizeMeasurer().measure($0) },
            log: RemovalLog(directory: sandbox.root.appendingPathComponent("log"))
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [container.standardizedFileURL.path])
        #expect(FileManager.default.fileExists(atPath: container.path))
    }

    /// A shared group container, the plan that keeps it, and the log for its removal.
    private func sharedContainerFixture(
        _ sandbox: Sandbox, context: ScanContext = ScanContext()
    ) async throws -> (app: URL, container: URL, plan: AppUninstallPlan, log: RemovalLog) {
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        try sandbox.sign(app, groups: ["group.com.vendor.editor"])
        let writer = try sandbox.application("Writer", identifier: "com.vendor.writer")
        try sandbox.sign(writer, groups: ["group.com.vendor.editor"])
        let container = try sandbox.write("Library/Group Containers/group.com.vendor.editor/shared.db")
            .deletingLastPathComponent().standardizedFileURL
        let plan = try await sandbox.planner().plan(applicationURL: app, context: context)
        #expect(plan.preservedPaths.map(\.url) == [container])
        // The application is already gone, so only the container can go to the real Trash.
        try FileManager.default.moveItem(at: app, to: sandbox.root.appendingPathComponent("removed-app"))
        return (app, container, plan, RemovalLog(directory: sandbox.root.appendingPathComponent("log")))
    }

    private func discardTrashedItems(in log: RemovalLog) {
        for record in log.recentEntries() {
            if let path = record.trashedPath { try? FileManager.default.removeItem(atPath: path) }
        }
    }

    @Test("an opted-in shared group container moves to the Trash after the application, and the log records the opt-in")
    func optedInSharedGroupContainerIsRemoved() async throws {
        let sandbox = try Sandbox()
        let fixture = try await sharedContainerFixture(sandbox)
        defer { discardTrashedItems(in: fixture.log) }
        let id = try #require(fixture.plan.preservedPaths.first?.id)
        let plan = fixture.plan.includingSharedGroupContainers([id], context: ScanContext())
        #expect(plan.optedInItems.map(\.url) == [fixture.container])

        let outcome = try await CleanupService(
            measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: fixture.log
        ).uninstall(plan)

        #expect(outcome.failed.isEmpty)
        #expect(outcome.removedCount == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.container.path))
        let record = try #require(fixture.log.recentEntries().first { $0.originalPath == fixture.container.path })
        #expect(record.disposition == .trashed)
        #expect(record.optedInSharedGroupContainer)
        let line = RemovalLog.line(for: record)
        #expect(line.hasSuffix(" optIn=sharedGroupContainer"))
        #expect(RemovalLog.record(from: Substring(line)) == record)
    }

    @Test("a shared group container that the user did not opt in to remove stays on disk")
    func sharedGroupContainerWithoutOptInStays() async throws {
        let sandbox = try Sandbox()
        let fixture = try await sharedContainerFixture(sandbox)
        defer { discardTrashedItems(in: fixture.log) }
        let plan = fixture.plan.includingSharedGroupContainers([], context: ScanContext())
        #expect(plan.optedInItems.isEmpty)

        let outcome = try await CleanupService(
            measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: fixture.log
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed.isEmpty)
        #expect(FileManager.default.fileExists(atPath: fixture.container.path))
        #expect(fixture.log.recentEntries().isEmpty)
    }

    enum OptInChange: CaseIterable { case excluded, protectedContent }

    @Test("an opted-in shared group container stays when it becomes excluded or holds protected content", arguments: OptInChange.allCases)
    func optedInSharedGroupContainerStaysAfterAChange(_ change: OptInChange) async throws {
        let sandbox = try Sandbox()
        let fixture = try await sharedContainerFixture(sandbox)
        defer { discardTrashedItems(in: fixture.log) }
        let id = try #require(fixture.plan.preservedPaths.first?.id)
        let context: ScanContext
        switch change {
        case .excluded:
            context = ScanContext(excludedPaths: [fixture.container.path])
        case .protectedContent:
            context = ScanContext(excludedPatterns: ["*.keychain-db"])
            try sandbox.write("Library/Group Containers/group.com.vendor.editor/login.keychain-db")
        }
        let plan = fixture.plan.includingSharedGroupContainers([id], context: context)

        let outcome = try await CleanupService(
            measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: fixture.log
        ).uninstall(plan)

        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [fixture.container.path])
        #expect(FileManager.default.fileExists(atPath: fixture.container.path))
        let record = try #require(fixture.log.recentEntries().first)
        #expect(record.disposition == .failed)
        #expect(record.optedInSharedGroupContainer)
    }

    @Test("a shared group container that fails another check has that reason and no opt-in")
    func sharedGroupContainerWithAnotherReasonHasNoOptIn() async throws {
        let sandbox = try Sandbox()
        let app = try sandbox.application("Editor", identifier: "com.vendor.editor")
        let container = try sandbox.write("Library/Group Containers/group.com.vendor.editor/shared.db")
            .deletingLastPathComponent().standardizedFileURL

        let plan = try await sandbox.planner().plan(
            applicationURL: app, context: ScanContext(excludedPaths: [container.path])
        )

        #expect(plan.preservedPaths.map(\.url) == [container])
        #expect(plan.preservedPaths.first?.reason == .excluded)
        #expect(plan.preservedPaths.first?.optInItem == nil)
        #expect(plan.includingSharedGroupContainers([container.path], context: ScanContext()).optedInItems.isEmpty)
    }

    /// Every droplet Shortcuts makes carries `com.apple.shortcuts.droplet`, so what
    /// that name matches belongs to all of them and to none.
    @Test("a Shortcuts droplet is the application alone, with its identifier still shown")
    func shortcutsDropletIsApplicationOnly() async throws {
        let sandbox = try Sandbox()
        let droplet = try sandbox.application(
            "Light Mode", identifier: "com.apple.shortcuts.droplet", under: sandbox.userApplications
        )
        _ = try sandbox.write("Library/Preferences/com.apple.shortcuts.droplet.plist")

        #expect(sandbox.planner().installedApplications().map(\.name) == ["Light Mode"])
        let plan = try await sandbox.planner().plan(applicationURL: droplet)
        #expect(plan.isApplicationOnly)
        #expect(plan.bundleIdentifier == "com.apple.shortcuts.droplet")
        #expect(plan.items.map(\.url) == [droplet])
    }

    /// `Install macOS Sonoma.app` is twelve gigabytes and the first thing anyone
    /// would clear. Fetched through Software Update or `softwareupdate
    /// --fetch-full-installer` it carries no App Store receipt, so the receipt rule
    /// refused it: a row the size of the scan that nothing could remove.
    @Test("a macOS installer is removable on its own, with or without a receipt")
    func macOSInstallerIsApplicationOnly() async throws {
        let sandbox = try Sandbox()
        let installer = try sandbox.application(
            "Install macOS Sonoma", identifier: "com.apple.InstallAssistant.macOSSonoma"
        )
        _ = try sandbox.write("Library/Preferences/com.apple.InstallAssistant.macOSSonoma.plist")

        #expect(sandbox.planner().installedApplications().map(\.name) == ["Install macOS Sonoma"])
        let plan = try await sandbox.planner().plan(applicationURL: installer)
        // The installer alone: what else answers to an Apple name is not knowable.
        #expect(plan.isApplicationOnly)
        #expect(plan.items.map(\.url) == [installer])
        #expect(plan.bundleIdentifier == "com.apple.InstallAssistant.macOSSonoma")
    }

    @Test("a browser's web-application launcher is not listed")
    func chromiumShimIsNotListed() throws {
        let sandbox = try Sandbox()
        let folder = sandbox.userApplications
            .appendingPathComponent("Chrome Apps.localized", isDirectory: true)
        let shim = try sandbox.application(
            "Some Site", identifier: "com.google.Chrome.app.abcdefgh", under: folder
        )
        let plistURL = shim.appendingPathComponent("Contents/Info.plist")
        var plist = try #require(NSDictionary(contentsOf: plistURL) as? [String: Any])
        plist["CrAppModeShortcutID"] = "abcdefgh"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: plistURL)
        try sandbox.application("Real Tool", identifier: "com.vendor.tool", under: folder)

        // Recognised by what it is, not by the folder it sits in.
        #expect(sandbox.planner().installedApplications().map(\.name) == ["Real Tool"])
    }
}
