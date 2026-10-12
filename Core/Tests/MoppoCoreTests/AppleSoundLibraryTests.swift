import Foundation
import Testing
@testable import MoppoCore

@Suite("Downloaded Apple sound content")
struct AppleSoundLibraryTests {
    private final class Sandbox {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-sounds-\(UUID())")
        var home: URL { root.appendingPathComponent("home") }
        var applications: URL { root.appendingPathComponent("Applications") }
        var library: URL { root.appendingPathComponent("Library") }
        var receiptPaths: Set<String> = []

        init() throws {
            for directory in [home, applications, library] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func content(_ relative: String, recognized: Bool = true) throws -> URL {
            let url = library.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: 8192).write(to: url)
            if recognized {
                var path = url
                while path.path.hasPrefix(library.path + "/") {
                    receiptPaths.insert(path.path)
                    path.deleteLastPathComponent()
                }
            }
            return url
        }

        @discardableResult
        func application(_ identifier: String) throws -> URL {
            let name = AppleSoundLibrary.ownerNames[identifier] ?? "Fixture"
            let url = applications.appendingPathComponent("\(name).app")
            try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/_MASReceipt"), withIntermediateDirectories: true)
            try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundlePackageType": "APPL",
            ], format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
            try Data(repeating: 0x41, count: 4096).write(to: url.appendingPathComponent("Contents/_MASReceipt/receipt"))
            return url
        }

        func sounds() -> AppleSoundLibrary {
            let paths = receiptPaths
            return AppleSoundLibrary(systemLibrary: library, applicationRoots: [applications], receiptPaths: { paths })
        }
        func planner() -> AppUninstallPlanner {
            AppUninstallPlanner(home: home, systemLibrary: library, applicationRoots: [applications],
                                darwinCache: nil, darwinTemp: nil, soundLibraries: sounds())
        }
        func leftovers() -> OrphanedAppLeftoverPlanner {
            OrphanedAppLeftoverPlanner(
                pathPlanner: planner(),
                directoryNames: { try FileManager.default.contentsOfDirectory(atPath: $0.path) },
                candidatePathStatus: { FileManager.default.fileExists(atPath: $0.path) ? .present : .missing },
                teamIdentifier: { _ in nil }
            )
        }
        func cleanup(log: RemovalLog) -> CleanupService {
            CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: log)
        }
    }

    @Test("Receipt content becomes a named leftover without application containers")
    func absentApplication() async throws {
        let box = try Sandbox()
        try box.content("Application Support/GarageBand/Instrument Library/Sampler/Factory.exs")
        try box.content("Application Support/Logic/EXS Factory Samples/Factory.aif")
        try box.content("Audio/Apple Loops/Apple/Factory/Loop.caf")
        let planner = box.leftovers()
        #expect(planner.scanCandidates().identifiers == AppleSoundLibrary.ownerIdentifiers)
        let plan = try await planner.plan()
        let group = try #require(plan.groups.first)
        #expect(plan.groups.count == 1)
        #expect(group.displayName == "GarageBand")
        #expect(group.bundleIdentifier == AppleSoundLibrary.garageBandIdentifier)
        #expect(group.items.count == 3)
        #expect(group.items.allSatisfy { $0.content == .soundLibrary && !$0.isProtectedUserData })
        #expect(plan.ownerBundleIdentifiers(for: [group.id]) == AppleSoundLibrary.ownerIdentifiers)
        let result = try await ApplicationLeftoversScanner(planner: planner).scan(context: ScanContext())
        #expect(result.safeToRemoveBytes == 0)
        #expect(result.needsReviewBytes == plan.totalBytes)
        #expect(result.entries.first?.displayName == "GarageBand")
    }

    @Test("Each installed consumer protects common instruments", arguments: AppleSoundLibrary.ownerIdentifiers.sorted())
    func installedConsumers(_ identifier: String) async throws {
        let box = try Sandbox()
        try box.content("Application Support/GarageBand/Instrument Library/Sampler/Factory.exs")
        try box.application(identifier)
        #expect(try await box.leftovers().plan().groups.isEmpty)
        let scan = try await ApplicationsScanner(
            applicationDirectories: [box.applications], home: box.home, soundLibraries: box.sounds()
        ).scan(context: ScanContext())
        let application = try #require(scan.entries.first)
        let sound = try #require(application.children.first { $0.soundLibrary != nil })
        #expect(!sound.isRegenerable)
        #expect(sound.protectionReason == nil)
        #expect(scan.safeToRemoveBytes == 0)
        #expect(CleanupService.removalTargets(for: application, removeProtectedAppData: false).allSatisfy { $0.soundLibrary == nil })
        #expect(CleanupService.removalTargets(for: application, removeProtectedAppData: true).allSatisfy { $0.soundLibrary == nil })
    }

    @Test("Registered consumers and shared installations remain outside leftovers")
    func registeredAndSharedOwners() async throws {
        let box = try Sandbox()
        try box.content("Application Support/Logic/EXS Factory Samples/Factory.aif")
        #expect(try await box.leftovers().plan(registeredApplicationBundleIdentifiers: ["com.apple.MainStage3"]).groups.isEmpty)
        let garageBand = try box.application(AppleSoundLibrary.garageBandIdentifier)
        try box.application("com.apple.logic10")
        let plan = try await box.planner().plan(applicationURL: garageBand)
        #expect(plan.soundLibraryItems.isEmpty)
        #expect(plan.preservedPaths.contains(box.library.appendingPathComponent("Application Support/Logic")))
    }

    @Test("Added content, exclusions, protected patterns, and links stay protected")
    func protectedContent() async throws {
        let box = try Sandbox()
        let sample = try box.content("Application Support/GarageBand/Instrument Library/Sampler/Factory.exs")
        let context = ScanContext(excludedPaths: [sample.path])
        #expect(try await box.sounds().scan(context: context, installedOwners: []).items.isEmpty)
        #expect(try await box.sounds().scan(context: ScanContext(excludedPatterns: ["*.exs"]), installedOwners: []).items.isEmpty)
        let custom = try box.content("Application Support/GarageBand/Instrument Library/Sampler/Custom.exs", recognized: false)
        let unknown = try await box.sounds().scan(context: ScanContext(), installedOwners: [])
        #expect(unknown.items.isEmpty)
        #expect(!unknown.preservedPaths.isEmpty)
        try FileManager.default.removeItem(at: custom)
        try FileManager.default.removeItem(at: sample)
        try FileManager.default.createSymbolicLink(at: sample, withDestinationURL: box.root)
        let linked = try await box.sounds().scan(context: ScanContext(), installedOwners: [])
        #expect(linked.items.isEmpty)
        #expect(linked.unreadableCount > 0)
    }

    @Test("Unreadable receipts and empty content do not offer removal")
    func unavailableReceipts() async throws {
        let box = try Sandbox()
        try box.content("Application Support/GarageBand/Instrument Library/Sampler/Factory.exs")
        let unavailable = AppleSoundLibrary(systemLibrary: box.library, applicationRoots: [box.applications],
                                           receiptPaths: { throw CocoaError(.fileReadNoPermission) })
        let result = try await unavailable.scan(context: ScanContext(), installedOwners: [])
        #expect(result.items.isEmpty)
        #expect(result.unreadableCount == 1)
        let unknown = AppleSoundLibrary(systemLibrary: box.library, applicationRoots: [box.applications], receiptPaths: { [] })
        #expect(try await unknown.scan(context: ScanContext(), installedOwners: []).items.isEmpty)
    }

    @Test("An owner installed after review stops leftover removal")
    func ownerChangesBeforeRemoval() async throws {
        let box = try Sandbox()
        let sample = try box.content("Application Support/GarageBand/Instrument Library/Sampler/Factory.exs")
        let plan = try await box.leftovers().plan()
        let item = try #require(plan.groups.first?.items.first)
        let log = RemovalLog(directory: box.root.appendingPathComponent("logs"))
        let outcome = try await box.cleanup(log: log).removeOrphanedAppLeftovers(
            plan, bundleIdentifiers: [AppleSoundLibrary.garageBandIdentifier],
            registeredApplicationBundleIdentifiers: ["com.apple.logic10"]
        )
        #expect(outcome.failed == [item.url.path])
        #expect(outcome.removedCount == 0)
        #expect(FileManager.default.fileExists(atPath: sample.path))
    }

    @Test("A library changed after review cannot move through ordinary cleanup")
    func contentChangesBeforeRemoval() async throws {
        let box = try Sandbox()
        let sample = try box.content("Application Support/GarageBand/Instrument Library/Sampler/Factory.exs")
        let reviewed = try await box.sounds().scan(context: ScanContext(), installedOwners: [])
        let item = try #require(reviewed.items.first)
        try Data("Updated sample".utf8).write(to: sample)
        let log = RemovalLog(directory: box.root.appendingPathComponent("logs"))
        let outcome = try await box.cleanup(log: log).remove(entries: [item.fileEntry], trashFirst: false)
        #expect(outcome.failed == [item.url.path])
        #expect(outcome.removedCount == 0)
        #expect(FileManager.default.fileExists(atPath: sample.path))
    }

    @Test("Sound removal uses Trash and supplies a Put Back receipt", arguments: [true, false])
    func removalAndRecovery(installed: Bool) async throws {
        let box = try Sandbox()
        let sample = try box.content("Application Support/GarageBand/Instrument Library/Sampler/Factory.exs")
        let application = installed ? try box.application(AppleSoundLibrary.garageBandIdentifier) : nil
        let log = RemovalLog(directory: box.root.appendingPathComponent("logs"))
        let cleanup = box.cleanup(log: log)
        defer {
            for record in log.recentEntries() {
                if let path = record.trashedPath { try? FileManager.default.removeItem(atPath: path) }
            }
        }
        let outcome: CleanupOutcome
        if let application {
            let plan = try await box.planner().plan(applicationURL: application)
            let item = try #require(plan.soundLibraryItems.first)
            #expect(plan.items.allSatisfy { $0.soundLibrary == nil })
            outcome = try await cleanup.removeSoundLibraries(plan, itemPaths: [item.id])
            #expect(FileManager.default.fileExists(atPath: application.path))
        } else {
            let plan = try await box.leftovers().plan()
            outcome = try await cleanup.removeOrphanedAppLeftovers(plan, bundleIdentifiers: [AppleSoundLibrary.garageBandIdentifier])
        }
        #expect(outcome.trashedCount == 1)
        #expect(outcome.deletedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: sample.path))
        let history = CleanupHistoryService(log: log)
        let recorded = try #require(history.summary().items.first)
        #expect(recorded.state == .availableInTrash)
        let trashURL = try #require(recorded.trashedURL)
        try await TrashService(home: box.home, log: log).putBack(TrashItem(
            url: trashURL, name: recorded.name, bytes: recorded.bytes, deletedAt: recorded.timestamp, canPutBack: true
        ))
        #expect(FileManager.default.fileExists(atPath: sample.path))
    }
}
