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
        model.uninstaller.planAppUninstall(app)
        try await waitUntil(timeout: .seconds(15)) { !model.uninstaller.isPlanningAppUninstall }
        #expect(model.uninstaller.appUninstallPlan?.managedPackage?.name == "managed")
        #expect(model.uninstaller.appUninstallPlan?.protectedItems.isEmpty == false)
        #expect(await fixture.brew.uninstalls.isEmpty)

        model.uninstaller.requestAppUninstall()
        try await waitUntil(timeout: .seconds(15)) { model.uninstaller.batchUninstallOutcome != nil && model.activity == nil }

        #expect(model.uninstaller.batchUninstallOutcome?.homebrewUninstalled == [app.deletingPathExtension().lastPathComponent])
        #expect((model.uninstaller.batchUninstallOutcome?.removedBytes ?? 0) > 0)
        #expect(model.uninstaller.batchUninstallOutcome?.setAside.isEmpty == true)
        #expect(await fixture.brew.uninstalls == ["managed"])
        #expect(!FileManager.default.fileExists(atPath: fixture.profile.path))
    }

    @Test("Homebrew batch review is required with either confirmation setting", arguments: [true, false])
    func mixedBatch(confirm: Bool) async throws {
        let settings = try RemovalSettingsFixture(confirm: confirm)
        let fixture = try Fixture()
        let model = fixture.model(settings: settings.settings)
        model.uninstaller.loadInstalledApplications()
        try await waitUntil(timeout: .seconds(15)) { model.uninstaller.installedApplicationsMeasured }
        let applications = try #require(model.uninstaller.installedApplications)
        #expect(applications.count == 4)
        for app in applications { model.uninstaller.toggleApplicationSelection(app) }

        model.uninstaller.moveSelectedApplicationsToTrash()
        try await waitUntil(timeout: .seconds(15)) { !model.uninstaller.isPlanningAppUninstall }
        let review = try #require(model.uninstaller.batchUninstallReview)
        #expect(review.plans.count == 4)
        #expect(review.homebrewCount == 2)
        #expect(await fixture.brew.uninstalls.isEmpty)
        for app in applications { #expect(FileManager.default.fileExists(atPath: app.url.path)) }

        // A changed application must survive its earlier review.
        let changed = fixture.applications["changed"]!
        try FileManager.default.moveItem(at: changed, to: fixture.root.appendingPathComponent("old.app"))
        try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)

        model.uninstaller.requestBatchUninstall()
        try await waitUntil(timeout: .seconds(15)) { model.uninstaller.batchUninstallOutcome != nil && model.activity == nil }
        let outcome = try #require(model.uninstaller.batchUninstallOutcome)
        #expect(outcome.uninstalled.count == 2)
        #expect(outcome.homebrewUninstalled.count == 1)
        #expect(outcome.setAside.count == 2)
        #expect(outcome.setAside.allSatisfy { $0.kind == .failed })
        #expect(outcome.removedBytes > 0)
        #expect(outcome.setAside.contains { $0.managedPackage?.name == "denied" && $0.details?.contains("password") == true })
        #expect(FileManager.default.fileExists(atPath: changed.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.profile.path))
        #expect(FileManager.default.fileExists(atPath: fixture.deniedProfile.path))
        #expect(model.uninstaller.selectedApplicationIDs.count == 2)
    }

    @Test("Data cleanup failures remain visible after the application is removed")
    func relatedDataFailure() async throws {
        let fixture = try Fixture()
        let model = fixture.model()
        model.uninstaller.planAppUninstall(fixture.applications["managed"]!)
        try await waitUntil(timeout: .seconds(15)) { !model.uninstaller.isPlanningAppUninstall }
        let support = fixture.profile.deletingLastPathComponent()
        try FileManager.default.moveItem(at: support, to: fixture.root.appendingPathComponent("original-support"))
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("Replacement data".utf8).write(to: fixture.profile)

        model.uninstaller.requestAppUninstall()
        try await waitUntil(timeout: .seconds(15)) { model.uninstaller.batchUninstallOutcome != nil && model.activity == nil }
        let result = try #require(model.uninstaller.batchUninstallOutcome)
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
        let skipped = AppUninstallerModel.SetAsideApplication(name: "Protected", reason: "The application is excluded.")
        var result = AppUninstallerModel.BatchUninstallOutcome(setAside: [skipped])
        #expect(result.title == "No applications were removed")
        result.setAside.append(.init(name: "Failed", reason: "Removal failed.", kind: .failed))
        #expect(result.title == "Removal needs attention")
    }

    @Test("Application details keep the main scrollbar and receive removal confirmation")
    func dialogConfirmation() async throws {
        let fixture = try Fixture(extraApplications: 40)
        let preferences = try RemovalSettingsFixture(confirm: true)
        let model = fixture.model(settings: preferences.settings)
        let application = try #require(fixture.applications["ordinary"])
        let plan = try await fixture.planner().plan(applicationURL: application)
        model.view = .uninstaller

        _ = NSApplication.shared
        let parent = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1000, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        parent.contentView = NSHostingView(rootView: MainWindow(model: model)
            .environment(\.scenePhase, .inactive))
        defer {
            model.finishRemovalConfirmation(false)
            model.uninstaller.resetAppUninstall()
            parent.contentView = nil
            parent.orderOut(nil)
        }
        try await waitUntil { model.uninstaller.installedApplicationsMeasured }
        parent.contentView?.layoutSubtreeIfNeeded()
        let host = try #require(parent.contentView)
        let libraryScroll = try #require(scrollViews(in: host).first {
            $0.frame.width > Token.Size.sidebarWidth
        })
        libraryScroll.scrollerStyle = .legacy
        libraryScroll.autohidesScrollers = false
        libraryScroll.hasVerticalScroller = true
        libraryScroll.tile()
        libraryScroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        libraryScroll.reflectScrolledClipView(libraryScroll.contentView)
        let contentBounds = libraryScroll.contentView.bounds
        #expect(contentBounds.origin.y > 0)
        #expect(libraryScroll.documentView!.frame.height > contentBounds.height)

        model.uninstaller.appUninstallPlan = plan
        try await waitUntil {
            NSApp.windows.contains { $0.title == "Application details" && $0.isVisible }
        }
        parent.contentView?.layoutSubtreeIfNeeded()
        #expect(libraryScroll.hasVerticalScroller)
        #expect(libraryScroll.contentView.bounds == contentBounds)
        let panel = try #require(NSApp.windows.first { $0.title == "Application details" && $0.isVisible })
        model.uninstaller.requestAppUninstall()
        try await waitUntil { panel.attachedSheet != nil }
        #expect(model.pendingRemovalConfirmation != nil)
        #expect(parent.attachedSheet == nil)
        #expect(model.uninstaller.isShowingAppUninstallDetail)

        model.finishRemovalConfirmation(false)
        try await waitUntil { !panel.isVisible && !model.uninstaller.isUninstallingApp }
        #expect(model.uninstaller.appUninstallPlan == nil)
        #expect(model.uninstaller.isShowingUninstallerLibrary)
        #expect(FileManager.default.fileExists(atPath: application.path))
        parent.contentView?.layoutSubtreeIfNeeded()
        #expect(libraryScroll.hasVerticalScroller)
        #expect(libraryScroll.contentView.bounds == contentBounds)
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        let current = (view as? NSScrollView).map { [$0] } ?? []
        return current + view.subviews.flatMap { scrollViews(in: $0) }
    }

    @Test("Homebrew review and results render in both appearances")
    func renderLayouts() async throws {
        let fixture = try Fixture()
        let plan = try await fixture.planner().plan(applicationURL: fixture.applications["managed"]!)
        let package = try #require(plan.managedPackage)
        let model = fixture.model()
        model.uninstaller.appUninstallPlan = plan
        let batchModel = fixture.model()
        batchModel.uninstaller.loadInstalledApplications()
        try await waitUntil(timeout: .seconds(15)) { batchModel.uninstaller.installedApplicationsMeasured }
        let selectedIdentifiers = Set(["managed", "ordinary", "changed"].map { "test.moppo.\($0)" })
        for application in batchModel.uninstaller.installedApplications ?? []
        where selectedIdentifiers.contains(application.bundleIdentifier ?? "") {
            batchModel.uninstaller.toggleApplicationSelection(application)
        }
        batchModel.uninstaller.moveSelectedApplicationsToTrash()
        try await waitUntil(timeout: .seconds(15)) { !batchModel.uninstaller.isPlanningAppUninstall }
        let batchReview = try #require(batchModel.uninstaller.batchUninstallReview)
        #expect(batchReview.plans.count == 3)
        #expect(batchReview.homebrewCount == 1)
        var result = AppUninstallerModel.BatchUninstallOutcome()
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
            let success = AppUninstallerModel.BatchUninstallOutcome(
                uninstalled: ["Ferdium"], removedBytes: 175_200_000, homebrewUninstalled: ["Ferdium"]
            )
            try await render(
                AppUninstallResultView(outcome: success, back: {}, review: { _ in }, reviewLeftovers: {}),
                name: "success-\(dark ? "dark" : "light")", dark: dark
            )
            try await render(
                CleanupOperationView(itemCount: 3, totalBytes: 175_200_000, isComplete: true),
                name: "cleanup-success-\(dark ? "dark" : "light")", dark: dark
            )
            try await render(
                AppUninstallResultView(outcome: result, back: {}, review: { _ in }, reviewLeftovers: {}),
                name: "mixed-\(dark ? "dark" : "light")", dark: dark
            )
            let review = try await render(
                AppUninstallDetailView(model: model.uninstaller),
                name: "review-\(dark ? "dark" : "light")", dark: dark,
                size: NSSize(width: 520, height: 460)
            )
            for waiting in [false, true] {
                let progress = try await render(
                    AppUninstallDetailView(model: model.uninstaller, activity: .uninstalling(
                        applicationName: plan.applicationName, applicationOnly: false,
                        waitingToQuit: waiting, usingHomebrew: true
                    ))
                    .disabled(true),
                    name: "progress-\(waiting ? "waiting" : "homebrew")-\(dark ? "dark" : "light")", dark: dark,
                    size: NSSize(width: 520, height: 460)
                )
                expectFixedRegions(review, progress)
            }

            var ordinaryPlan = try await fixture.planner().plan(applicationURL: fixture.applications["ordinary"]!)
            ordinaryPlan.soundLibraryItems = [soundLibraryItem()]
            model.uninstaller.appUninstallPlan = ordinaryPlan
            let soundReview = try await render(
                AppUninstallDetailView(model: model.uninstaller),
                name: "sound-review-\(dark ? "dark" : "light")", dark: dark,
                size: NSSize(width: 520, height: 460)
            )
            for sounds in [false, true] {
                let activity: AppModel.Activity = sounds
                    ? .cleaningUp(itemCount: 1, totalBytes: 64)
                    : .uninstalling(applicationName: ordinaryPlan.applicationName,
                                    applicationOnly: false, waitingToQuit: false)
                let progress = try await render(
                    AppUninstallDetailView(model: model.uninstaller, activity: activity)
                        .disabled(true),
                    name: "progress-\(sounds ? "sounds" : "ordinary")-\(dark ? "dark" : "light")", dark: dark,
                    size: NSSize(width: 520, height: 460)
                )
                expectFixedRegions(soundReview, progress)
            }
            model.uninstaller.appUninstallPlan = plan
            for width in [520, 900] {
                try await render(
                    AppUninstallerView(model: batchModel.uninstaller),
                    name: "batch-review-mixed-\(width)-\(dark ? "dark" : "light")", dark: dark,
                    size: NSSize(width: width, height: 700)
                )
            }
            let failed = AppUninstallerModel.BatchUninstallOutcome(setAside: [result.setAside[0]])
            try await render(
                AppUninstallResultView(outcome: failed, back: {}, review: { _ in }, reviewLeftovers: {}),
                name: "failed-\(dark ? "dark" : "light")", dark: dark
            )
            let cancelled = AppUninstallerModel.BatchUninstallOutcome(setAside: [
                .init(
                    name: "Ferdium",
                    reason: "Administrator authentication was cancelled. Homebrew removal may be incomplete.",
                    kind: .failed, applicationURL: plan.applicationURL, managedPackage: package,
                    details: "Moppo: administrator authentication was cancelled."
                ),
            ])
            try await render(
                AppUninstallResultView(outcome: cancelled, back: {}, review: { _ in }, reviewLeftovers: {}),
                name: "cancelled-\(dark ? "dark" : "light")", dark: dark
            )
        }
    }

    /// Checks the header and footer summary, apart from controls that become dimmed.
    private func expectFixedRegions(_ review: NSBitmapImageRep, _ progress: NSBitmapImageRep) {
        #expect(review.pixelsWide == progress.pixelsWide && review.pixelsHigh == progress.pixelsHigh)
        let scale = review.pixelsWide / 520
        let regions = [
            NSRect(x: 0, y: 0, width: 460, height: 76),
            NSRect(x: 0, y: 392, width: 110, height: 68),
        ]
        for region in regions {
            let matches = (Int(region.minY) * scale..<Int(region.maxY) * scale).allSatisfy { y in
                (Int(region.minX) * scale..<Int(region.maxX) * scale).allSatisfy { x in
                    review.colorAt(x: x, y: y) == progress.colorAt(x: x, y: y)
                }
            }
            #expect(matches, "The fixed dialog area changed during removal: \(region).")
        }
    }

    @discardableResult
    private func render(
        _ view: some View, name: String, dark: Bool,
        size: NSSize = NSSize(width: 700, height: 540)
    ) async throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view
            .background(Token.pageBackground)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-homebrew-previews")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try png.write(to: folder.appendingPathComponent("\(name).png"))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        window.contentView = nil
        return bitmap
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

        init(extraApplications: Int = 0) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            var applications: [String: URL] = [:]
            let tokens = ["managed", "denied", "ordinary", "changed"]
                + (0..<extraApplications).map { "extra-\($0)" }
            for token in tokens {
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

        @MainActor func model(settings: SettingsStore? = nil) -> AppModel {
            let brew = brew
            return AppModel(
                settings: settings,
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
