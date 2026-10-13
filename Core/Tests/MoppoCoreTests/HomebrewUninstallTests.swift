import Foundation
import Testing
@testable import MoppoCore

@Suite("Homebrew removal")
struct HomebrewUninstallTests {
    @Test("Homebrew startup preserves the password request", .enabled(if: homebrewExecutable != nil))
    func homebrewAuthenticationEnvironment() async throws {
        let brew = try #require(Self.homebrewExecutable)
        let environment = HomebrewUninstallService.environment(
            for: ["uninstall", "--cask", "ferdium"], askpassExecutable: "/usr/bin/false"
        )
        let keys = ["SUDO_ASKPASS", "HOMEBREW_MOPPO_APP_PID", "HOMEBREW_MOPPO_CASK", "HOMEBREW_MOPPO_AUTH_DEADLINE"]
        let script = "require 'json'; puts JSON.generate(ENV.to_h.select { |key, _| %w[\(keys.joined(separator: " "))].include?(key) })"
        let output = try await ProcessRunner().run(
            brew, ["ruby", "-e", script], timeout: .seconds(20), environment: environment, allowsInput: false
        )
        let forwarded = try JSONDecoder().decode([String: String].self, from: output)
        for key in keys { #expect(forwarded[key] == environment[key]) }
    }

    private static var homebrewExecutable: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    @Test("Only package removal can use the bundled password helper")
    func authenticationEnvironment() {
        let helper = "/Applications/Moppo.app/Contents/Helpers/MoppoHomebrewAskpass"
        let environment = HomebrewUninstallService.environment(for: ["uninstall", "--cask", "ferdium"], askpassExecutable: helper)
        #expect(environment["SUDO_ASKPASS"] == helper)
        #expect(environment["HOMEBREW_MOPPO_CASK"] == "ferdium")
        #expect(environment["HOMEBREW_MOPPO_APP_PID"] == String(ProcessInfo.processInfo.processIdentifier))
        #expect(environment["HOMEBREW_MOPPO_AUTH_DEADLINE"].flatMap(Double.init) ?? 0 > Date().timeIntervalSince1970)

        let query = HomebrewUninstallService.environment(for: ["info", "--json=v2", "--installed"], askpassExecutable: helper)
        #expect(query["SUDO_ASKPASS"] == "/usr/bin/false")
        #expect(query["HOMEBREW_MOPPO_CASK"] == "")
        #expect(query["HOMEBREW_MOPPO_APP_PID"] == "")
        let headless = HomebrewUninstallService.environment(for: ["uninstall", "--cask", "ferdium"], askpassExecutable: nil)
        #expect(headless["SUDO_ASKPASS"] == "/usr/bin/false")
    }

    @Test("A missing password helper prevents removal")
    func missingHelper() async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: .success)
        let service = HomebrewUninstallService(log: fixture.log, askpassExecutable: fixture.root.appendingPathComponent("missing-helper").path) {
            try await brew.run($0, $1)
        }
        let result = await service.uninstall(fixture.plan)
        #expect(result.status == .notStarted)
        #expect(result.message.contains("password helper"))
        #expect(await brew.calls.isEmpty)
    }

    @Test("Password cancellation reports possible partial changes")
    func authenticationCancelled() async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: .success)
        let service = HomebrewUninstallService(log: fixture.log) { executable, arguments in
            if arguments.first == "uninstall" {
                throw ProcessError.failed(command: executable, status: 1, stderr: "Moppo: administrator authentication was cancelled.\nsudo: no password was provided")
            }
            return try await brew.run(executable, arguments)
        }
        let result = await service.uninstall(fixture.plan)
        #expect(result.status == .incomplete)
        #expect(result.message == "Administrator authentication was cancelled. Homebrew removal may be incomplete.")
        #expect(!result.applicationRemoved)
        #expect(await brew.calls.count == 2)
    }

    @Test("Removal uses Homebrew and moves related data to the Trash")
    func successfulRemoval() async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: .success)
        let result = await fixture.service(brew).uninstall(fixture.plan)

        #expect(result.status == .completed)
        #expect(result.applicationRemoved)
        #expect(!FileManager.default.fileExists(atPath: fixture.related.path))
        #expect(result.relatedCleanup.trashedCount == 1)
        #expect(result.relatedCleanup.failed.isEmpty)
        let calls = await brew.calls
        #expect(calls == [
            ["info", "--json=v2", "--installed"],
            ["uninstall", "--cask", "fixture"],
            ["info", "--json=v2", "--installed"],
        ])
        let records = fixture.log.recentEntries()
        #expect(records.count == 2)
        let appRecord = try #require(records.first { $0.originalPath == fixture.application.path })
        #expect(appRecord.disposition == .deleted)
        #expect(appRecord.trashedPath == nil)
        let dataRecord = try #require(records.first { $0.originalPath == fixture.related.path })
        #expect(dataRecord.disposition == .trashed)
        let trashed = URL(fileURLWithPath: try #require(dataRecord.trashedPath))
        try await TrashService(home: fixture.root, log: fixture.log).putBack(
            TrashItem(url: trashed, bytes: dataRecord.bytes, canPutBack: true)
        )
        #expect(try String(contentsOf: fixture.related, encoding: .utf8) == "Keep this profile")
    }

    @Test("Changed related data survives a successful package removal")
    func changedRelatedData() async throws {
        let fixture = try Fixture()
        try FileManager.default.moveItem(at: fixture.related, to: fixture.root.appendingPathComponent("original-profile"))
        try Data("Replacement data".utf8).write(to: fixture.related)
        let brew = FakeBrew(fixture: fixture, mode: .success)
        let result = await fixture.service(brew).uninstall(fixture.plan)
        #expect(result.status == .completed)
        #expect(result.applicationRemoved)
        #expect(result.relatedCleanup.failed == [fixture.related.path])
        #expect(result.relatedCleanup.removedCount == 0)
        #expect(try String(contentsOf: fixture.related, encoding: .utf8) == "Replacement data")
    }

    @Test("Homebrew can remove a related path before Moppo reaches it")
    func alreadyRemovedRelatedData() async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: .success)
        let service = HomebrewUninstallService(log: fixture.log) { executable, arguments in
            if arguments.first == "uninstall" { try FileManager.default.removeItem(at: fixture.related) }
            return try await brew.run(executable, arguments)
        }
        let result = await service.uninstall(fixture.plan)
        #expect(result.status == .completed)
        #expect(result.relatedCleanup.removedCount == 0)
        #expect(result.relatedCleanup.failed.isEmpty)
        #expect(fixture.log.recentEntries().count == 1)
    }

    @Test("Related data stays when another application owns it")
    func newOwnerPreservesRelatedData() async throws {
        let fixture = try Fixture()
        let contents = fixture.root.appendingPathComponent("Other.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "test.fixture", "CFBundlePackageType": "APPL",
        ], format: .xml, options: 0)
        try plist.write(to: contents.appendingPathComponent("Info.plist"))
        let brew = FakeBrew(fixture: fixture, mode: .success)
        let result = await fixture.service(brew).uninstall(fixture.plan)
        #expect(result.applicationRemoved)
        #expect(result.relatedCleanup.failed == [fixture.related.path])
        #expect(FileManager.default.fileExists(atPath: fixture.related.path))
    }

    @Test("Related cleanup failures keep a successful package result")
    func relatedMeasurementFailure() async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: .success)
        let cleanup = CleanupService(measureSize: { _ in throw CocoaError(.fileReadNoPermission) }, log: fixture.log)
        let service = HomebrewUninstallService(log: fixture.log, cleanupService: cleanup) {
            try await brew.run($0, $1)
        }
        let result = await service.uninstall(fixture.plan)
        #expect(result.status == .completed)
        #expect(result.applicationRemoved)
        #expect(result.relatedCleanup.failed == [fixture.related.path])
        #expect(FileManager.default.fileExists(atPath: fixture.related.path))
    }

    @Test("Related cleanup does not move data while the application exists")
    func existingApplicationPreservesData() async throws {
        let fixture = try Fixture()
        let result = await CleanupService(log: fixture.log).removeRelatedFilesAfterHomebrew(
            fixture.plan, keepReceipt: true
        )
        #expect(result.removedCount == 0)
        #expect(result.failed == [fixture.related.path])
        #expect(FileManager.default.fileExists(atPath: fixture.related.path))
    }

    @Test("Failed commands and incomplete results never report success", arguments: [
        Mode.permissionDenied, .partial, .recordOnly, .verificationFailure, .interrupted, .falseSuccess, .lateFailure,
    ])
    func incompleteRemoval(mode: Mode) async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: mode)
        let result = await fixture.service(brew).uninstall(fixture.plan)

        #expect(result.status == .incomplete)
        #expect(result.applicationRemoved == [.partial, .verificationFailure, .interrupted, .lateFailure].contains(mode))
        #expect(FileManager.default.fileExists(atPath: fixture.related.path))
        #expect(await brew.calls.count == 3)
        if mode == .permissionDenied { #expect(result.details?.contains("password") == true) }
    }

    @Test("Changed ownership prevents command execution")
    func changedOwnership() async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: .changedOwner)
        let result = await fixture.service(brew).uninstall(fixture.plan)

        #expect(result.status == .notStarted)
        #expect(await brew.calls.count == 1)
        #expect(FileManager.default.fileExists(atPath: fixture.application.path))
    }

    @Test("A replacement application cannot use an earlier review")
    func replacementApplication() async throws {
        let fixture = try Fixture()
        try FileManager.default.moveItem(at: fixture.application, to: fixture.root.appendingPathComponent("original.app"))
        try FileManager.default.createDirectory(at: fixture.application, withIntermediateDirectories: true)
        let brew = FakeBrew(fixture: fixture, mode: .success)

        let result = await fixture.service(brew).uninstall(fixture.plan)

        #expect(result.status == .notStarted)
        #expect(await brew.calls.count == 1)
    }

    @Test("Cancellation before removal starts runs no command")
    func cancelledBeforeStart() async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: .success)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await fixture.service(brew).uninstall(fixture.plan)
        }
        #expect(await task.value.status == .notStarted)
        #expect(await brew.calls.isEmpty)
    }

    @Test("Receipt preferences apply to Homebrew removal")
    func disabledReceipt() async throws {
        let fixture = try Fixture()
        let brew = FakeBrew(fixture: fixture, mode: .success)
        // Homebrew already removed this fixture path, so no unrecorded Trash item remains.
        try FileManager.default.removeItem(at: fixture.related)
        _ = await fixture.service(brew).uninstall(fixture.plan, keepReceipt: false)
        #expect(!FileManager.default.fileExists(atPath: fixture.log.logFileURL.path))
    }

    @Test("Only an application artifact can establish ownership")
    func nonApplicationArtifact() throws {
        let data = Data(#"{"casks":[{"token":"fixture","artifacts":[{"binary":["fixture"],"target":"/Applications/Fixture.app"}]}]}"#.utf8)
        #expect(try AppUninstallPlanner.homebrewPackage(
            in: data, managing: URL(fileURLWithPath: "/Applications/Fixture.app"), executable: "/opt/homebrew/bin/brew"
        ) == nil)
    }

    @Test("Renamed application artifacts retain exact target matching")
    func renamedApplicationArtifact() throws {
        let data = Data(#"{"casks":[{"token":"fixture","artifacts":[{"app":["Source.app",{"target":"Fixture.app"}],"target":"/Applications/Fixture.app"}]}]}"#.utf8)
        #expect(try AppUninstallPlanner.homebrewPackage(
            in: data, managing: URL(fileURLWithPath: "/Applications/Fixture.app"), executable: "/opt/homebrew/bin/brew"
        )?.name == "fixture")
    }

    @Test("Ambiguous ownership prevents direct removal planning")
    func ambiguousOwnership() throws {
        let data = Data(#"{"casks":[{"token":"first","artifacts":[{"app":["Fixture.app"],"target":"/Applications/Fixture.app"}]},{"token":"second","artifacts":[{"app":["Fixture.app"],"target":"/Applications/Fixture.app"}]}]}"#.utf8)
        #expect(throws: AppUninstallPlanningError.packageOwnershipUnavailable) {
            try AppUninstallPlanner.homebrewPackage(
                in: data, managing: URL(fileURLWithPath: "/Applications/Fixture.app"), executable: "/opt/homebrew/bin/brew"
            )
        }
    }

    @Test("Process execution supports noninteractive input and explicit environment")
    func noninteractiveProcess() async throws {
        let output = try await ProcessRunner().run(
            "/bin/sh", ["-c", "read value || printf '%s' \"$MOPPO_TEST_VALUE\""],
            timeout: .seconds(5), environment: ["MOPPO_TEST_VALUE": "input closed"], allowsInput: false
        )
        #expect(String(decoding: output, as: UTF8.self) == "input closed")
    }

    enum Mode: Sendable, CaseIterable {
        case success, permissionDenied, partial, recordOnly, verificationFailure, changedOwner
        case interrupted, falseSuccess, lateFailure
    }

    actor FakeBrew {
        let application: URL
        let mode: Mode
        var installed = true
        var calls: [[String]] = []

        init(fixture: Fixture, mode: Mode) {
            self.application = fixture.application
            self.mode = mode
        }

        func run(_ executable: String, _ arguments: [String]) throws -> Data {
            #expect(executable == "/opt/homebrew/bin/brew")
            calls.append(arguments)
            if arguments.first == "uninstall" {
                if mode == .permissionDenied {
                    throw ProcessError.failed(command: "brew", status: 1, stderr: "sudo: a password is required")
                }
                if mode != .recordOnly && mode != .falseSuccess {
                    try FileManager.default.removeItem(at: application)
                }
                installed = [.partial, .interrupted, .falseSuccess].contains(mode)
                if mode == .interrupted { throw CancellationError() }
                if mode == .lateFailure { throw ProcessError.failed(command: "brew", status: 1, stderr: "Removal action failed") }
                return Data()
            }
            if mode == .verificationFailure && calls.count > 1 { throw CocoaError(.fileReadNoPermission) }
            let casks: [[String: Any]] = installed ? [[
                "token": mode == .changedOwner ? "other-package" : "fixture",
                "artifacts": [["app": ["Fixture.app"], "target": application.path]],
            ]] : []
            return try JSONSerialization.data(withJSONObject: ["casks": casks])
        }
    }

    final class Fixture: @unchecked Sendable {
        let root: URL
        let application: URL
        let related: URL
        let plan: AppUninstallPlan
        let log: RemovalLog

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            application = root.appendingPathComponent("Fixture.app")
            related = root.appendingPathComponent("profile-\(root.lastPathComponent).txt")
            log = RemovalLog(directory: root.appendingPathComponent("logs"))
            try FileManager.default.createDirectory(at: application, withIntermediateDirectories: true)
            try Data("Keep this profile".utf8).write(to: related)
            plan = AppUninstallPlan(
                applicationURL: application, applicationName: "Fixture", bundleIdentifier: "test.fixture",
                items: [
                    .init(url: application, category: .application, content: .application, allocatedBytes: 100, ownerBundleIdentifier: nil),
                    .init(url: related, category: .support, content: .userData, allocatedBytes: 10, ownerBundleIdentifier: "test.fixture"),
                ],
                managedPackage: .init(manager: .homebrew, name: "fixture", executable: "/opt/homebrew/bin/brew"),
                preservedPaths: [], candidateBundleIdentifiers: ["test.fixture"], applicationRoots: [root], allowedRelatedRoots: [root]
            )
        }

        func service(_ brew: FakeBrew) -> HomebrewUninstallService {
            HomebrewUninstallService(log: log) { try await brew.run($0, $1) }
        }

        deinit {
            for record in log.recentEntries() {
                if let path = record.trashedPath { try? FileManager.default.removeItem(atPath: path) }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }
}
