import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MoppoCore

@Suite("Homebrew application flows", .serialized)
@MainActor
struct HomebrewUninstallFlowTests {
    @Test("A managed application uses Homebrew from its individual review")
    func individualReview() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        let app = fixture.applications["managed"]!
        model.planAppUninstall(app)
        try await waitUntil { !model.isPlanningAppUninstall }
        #expect(model.appUninstallPlan?.managedPackage?.name == "managed")
        #expect(model.appUninstallPlan?.protectedItems.isEmpty == false)
        #expect(await fixture.brew.uninstalls.isEmpty)

        model.requestAppUninstall()
        try await waitUntil { model.batchUninstallOutcome != nil && model.activity == nil }

        #expect(model.batchUninstallOutcome?.homebrewUninstalled == [app.deletingPathExtension().lastPathComponent])
        #expect((model.batchUninstallOutcome?.removedBytes ?? 0) > 0)
        #expect(model.batchUninstallOutcome?.setAside.isEmpty == true)
        #expect(await fixture.brew.uninstalls == ["managed"])
        #expect(!FileManager.default.fileExists(atPath: fixture.profile.path))
    }

    @Test("Batch review precedes removal and preserves mixed results")
    func mixedBatch() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.loadInstalledApplications()
        try await waitUntil { model.installedApplicationsMeasured }
        let applications = try #require(model.installedApplications)
        #expect(applications.count == 4)
        for app in applications { model.toggleApplicationSelection(app) }

        model.moveSelectedApplicationsToTrash()
        try await waitUntil { !model.isPlanningAppUninstall }
        let review = try #require(model.batchUninstallReview)
        #expect(review.plans.count == 4)
        #expect(review.homebrewCount == 2)
        #expect(await fixture.brew.uninstalls.isEmpty)
        for app in applications { #expect(FileManager.default.fileExists(atPath: app.url.path)) }

        // A changed application must survive its earlier review.
        let changed = fixture.applications["changed"]!
        try FileManager.default.moveItem(at: changed, to: fixture.root.appendingPathComponent("old.app"))
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)

        model.requestBatchUninstall()
        try await waitUntil { model.batchUninstallOutcome != nil && model.activity == nil }
        let outcome = try #require(model.batchUninstallOutcome)
        #expect(outcome.uninstalled.count == 2)
        #expect(outcome.homebrewUninstalled.count == 1)
        #expect(outcome.setAside.count == 2)
        #expect(outcome.setAside.allSatisfy { $0.kind == .failed })
        #expect(outcome.removedBytes > 0)
        #expect(outcome.setAside.contains { $0.managedPackage?.name == "denied" && $0.details?.contains("password") == true })
        #expect(FileManager.default.fileExists(atPath: changed.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.profile.path))
        #expect(FileManager.default.fileExists(atPath: fixture.deniedProfile.path))
        #expect(model.selectedApplicationIDs.count == 2)
    }

    @Test("Data cleanup failures remain visible after the application is removed")
    func relatedDataFailure() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.planAppUninstall(fixture.applications["managed"]!)
        try await waitUntil { !model.isPlanningAppUninstall }
        let support = fixture.profile.deletingLastPathComponent()
        try FileManager.default.moveItem(at: support, to: fixture.root.appendingPathComponent("original-support"))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("Replacement data".utf8).write(to: fixture.profile)

        model.requestAppUninstall()
        try await waitUntil { model.batchUninstallOutcome != nil && model.activity == nil }
        let result = try #require(model.batchUninstallOutcome)
        #expect(result.uninstalled.count == 1)
        #expect(result.homebrewUninstalled.count == 1)
        #expect(result.survivorCount == 1)
        #expect(result.setAside.first?.details == support.path)
        #expect(result.setAside.first?.managedPackage == nil)
        #expect(result.removedBytes == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.profile.path))
    }

    @Test("Homebrew planning keeps the same exclusions as ordinary applications")
    func relatedDataExclusions() async throws {
        let fixture = try Fixture()
        let support = fixture.profile.deletingLastPathComponent()
        let context = ScanContext(excludedPaths: [support.path])
        let plan = try await fixture.planner().plan(applicationURL: fixture.applications["managed"]!, context: context)
        #expect(plan.managedPackage != nil)
        #expect(plan.items.count == 1)
        #expect(plan.preservedPaths.contains(support))
    }

    @Test("Planning failures remain distinct from removal failures")
    func skippedResult() {
        let skipped = AppModel.SetAsideApplication(name: "Protected", reason: "The application is excluded.")
        var result = AppModel.BatchUninstallOutcome(setAside: [skipped])
        #expect(result.title == "No applications were removed")
        result.setAside.append(.init(name: "Failed", reason: "Removal failed.", kind: .failed))
        #expect(result.title == "Removal needs attention")
    }

    @Test("Homebrew review and results render in both appearances")
    func renderLayouts() async throws {
        let fixture = try Fixture()
        let plan = try await fixture.planner().plan(applicationURL: fixture.applications["managed"]!)
        let package = try #require(plan.managedPackage)
        let model = fixture.model()
        model.appUninstallPlan = plan
        var result = AppModel.BatchUninstallOutcome()
        result.uninstalled = ["Ordinary application", "Managed application"]
        result.homebrewUninstalled = ["Managed application"]
        result.removedBytes = 42_000_000
        result.setAside = [
            .init(
                name: "An application with a very long name that needs more than one line in this result",
                reason: "Homebrew could not finish removal. Some files may have changed.",
                kind: .failed, applicationURL: plan.applicationURL, managedPackage: package,
                details: "sudo: a password is required"
            ),
            .init(name: "Protected application", reason: "The application is excluded.", applicationURL: plan.applicationURL),
        ]
        for dark in [false, true] {
            try await render(
                AppUninstallResultView(outcome: result, back: {}, review: { _ in }, reviewLeftovers: {}),
                name: "mixed-\(dark ? "dark" : "light")", dark: dark
            )
            try await render(AppUninstallerView(model: model), name: "review-\(dark ? "dark" : "light")", dark: dark)
            let failed = AppModel.BatchUninstallOutcome(setAside: [result.setAside[0]])
            try await render(
                AppUninstallResultView(outcome: failed, back: {}, review: { _ in }, reviewLeftovers: {}),
                name: "failed-\(dark ? "dark" : "light")", dark: dark
            )
        }
    }

    private func render(_ view: some View, name: String, dark: Bool) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view
            .background(Token.pageBackground)
            .environment(\.colorScheme, dark ? .dark : .light))
        let size = NSSize(width: 700, height: 540)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-homebrew-previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        window.contentView = nil
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(condition(), "The operation did not finish before the deadline.")
    }

    actor Brew {
        var applications: [String: URL]
        var uninstalls: [String] = []

        init(applications: [String: URL]) { self.applications = applications }

        func run(_ executable: String, _ arguments: [String]) throws -> Data {
            if arguments.first == "uninstall" {
                let token = arguments.last!
                uninstalls.append(token)
                if token == "denied" { throw ProcessError.failed(command: "brew", status: 1, stderr: "sudo: a password is required") }
                try FileManager.default.removeItem(at: applications.removeValue(forKey: token)!)
                return Data()
            }
            return try JSONSerialization.data(withJSONObject: ["casks": applications.map { token, url in
                ["token": token, "artifacts": [["app": [url.lastPathComponent], "target": url.path]]] as [String: Any]
            }])
        }
    }

    final class Fixture {
        let root: URL
        let applications: [String: URL]
        let profile: URL
        let deniedProfile: URL
        let brew: Brew
        let log: MoppoCore.RemovalLog

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            var applications: [String: URL] = [:]
            for token in ["managed", "denied", "ordinary", "changed"] {
                let url = root.appendingPathComponent("Applications/\(token)-\(root.lastPathComponent).app")
                try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
                let plist = try PropertyListSerialization.data(fromPropertyList: [
                    "CFBundleIdentifier": "test.moppo.\(token)", "CFBundleName": token, "CFBundlePackageType": "APPL",
                ], format: .xml, options: 0)
                try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
                applications[token] = url
            }
            self.applications = applications
            brew = Brew(applications: applications.filter { ["managed", "denied"].contains($0.key) })
            profile = root.appendingPathComponent("Library/Application Support/test.moppo.managed/profile.txt")
            try FileManager.default.createDirectory(at: profile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Keep my profile".utf8).write(to: profile)
            deniedProfile = root.appendingPathComponent("Library/Application Support/test.moppo.denied/profile.txt")
            try FileManager.default.createDirectory(at: deniedProfile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("Keep this profile after failure".utf8).write(to: deniedProfile)
            log = MoppoCore.RemovalLog(directory: root.appendingPathComponent("logs"))
        }

        func planner() -> AppUninstallPlanner {
            let brew = brew
            return AppUninstallPlanner(
                home: root, systemLibrary: root.appendingPathComponent("SystemLibrary"),
                applicationRoots: [root.appendingPathComponent("Applications")], darwinCache: nil, darwinTemp: nil,
                homebrewExecutable: "/opt/homebrew/bin/brew",
                loadHomebrewCatalog: { try await brew.run($0, ["info", "--json=v2", "--installed"]) }
            )
        }

        @MainActor func model() -> AppModel {
            let brew = brew
            return AppModel(
                launchAccess: .limited, hasFullDiskAccess: { false },
                trashService: TrashService(home: root, log: log),
                cleanupHistoryService: CleanupHistoryService(log: log),
                appUninstallPlanner: planner(),
                homebrewUninstallService: HomebrewUninstallService(log: log) { try await brew.run($0, $1) },
                cleanupService: CleanupService(log: log)
            )
        }

        deinit {
            for record in log.recentEntries() {
                if let path = record.trashedPath { try? FileManager.default.removeItem(atPath: path) }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
