import Foundation
import Testing
@testable import MoppoCore

@Suite("Tool command removal", .serialized)
struct ToolCommandRemovalTests {
    private static let nativeGo = ProcessInfo.processInfo.environment["MOPPO_TEST_GO_EXECUTABLE"]
        ?? ToolCommandRemoval.resolveGo()

    private final class Fixture: Sendable {
        let root: URL
        let cache: URL
        let executable: URL
        let log: RemovalLog

        init(script: String = "echo 'command warning' >&2\n/bin/rm -rf -- \"$GOMODCACHE\"") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-command-\(UUID())")
            cache = root.appendingPathComponent("go/pkg/mod")
            executable = root.appendingPathComponent("go-stub")
            log = RemovalLog(directory: root.appendingPathComponent("history"))
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 65_536).write(to: cache.appendingPathComponent("download"))
            try ("#!/bin/sh\n" + script + "\n").write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func entry(timeout: Duration = .seconds(10), patterns: [String] = []) -> FileEntry {
            let review = ToolCommandRemoval(targetURL: cache, executable: executable.path,
                arguments: ["clean", "-modcache"], environment: ["GOMODCACHE": cache.path],
                expectedResult: .targetAbsent, timeout: timeout, protectedPatterns: patterns)
            return FileEntry(url: cache, displayName: "Go module cache", kind: .cache, allocatedBytes: 65_536,
                isRegenerable: true, removalMethod: .toolCommand(review))
        }

        func remove(_ entry: FileEntry, confirmed: Bool = true) async throws -> CleanupOutcome {
            try await CleanupService(log: log).remove(entries: [entry], trashFirst: true, keepReceipt: false,
                confirmedToolCommands: confirmed ? [entry.id: try #require(entry.toolCommand)] : [:])
        }
    }

    @Test("Commands require exact confirmation and save permanent history when receipts are off")
    func confirmationAndHistory() async throws {
        let fixture = try Fixture()
        let entry = fixture.entry()
        let refused = try await fixture.remove(entry, confirmed: false)
        #expect(refused.failed == [entry.id])
        #expect(refused.toolCommandResults.first?.exitStatus == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.cache.path))

        let outcome = try await fixture.remove(entry)
        let result = try #require(outcome.toolCommandResults.first)
        #expect(result.status == .completed)
        #expect(result.exitStatus == 0)
        #expect(result.standardError == "command warning\n")
        #expect(result.afterBytes == 0)
        #expect((result.removedBytes ?? 0) > 0)
        #expect(outcome.removedCount == 1)
        #expect(outcome.deletedCount == 1)
        #expect(outcome.trashedCount == 0)
        let records = fixture.log.recentEntries()
        #expect(records.first?.toolCommandResult == result)
        #expect(records.first?.disposition == .deleted)
        #expect(records.first?.trashedPath == nil)
        let history = CleanupHistoryService(log: fixture.log).summary()
        #expect(history.items.first?.state == .removedPermanently)
        #expect(history.items.first?.name == "Go module cache")
        #expect(history.availableInTrashCount == 0)
    }

    @Test("Failed commands preserve errors and measure partial removal")
    func partialFailure() async throws {
        let fixture = try Fixture(script: "/bin/rm -- \"$GOMODCACHE/download\"\necho 'cache is busy' >&2\nexit 23")
        try Data(repeating: 0x62, count: 32_768).write(to: fixture.cache.appendingPathComponent("retained"))
        let entry = fixture.entry()
        let outcome = try await fixture.remove(entry)
        let result = try #require(outcome.toolCommandResults.first)
        #expect(result.status == .failed)
        #expect(result.exitStatus == 23)
        #expect(result.standardError == "cache is busy\n")
        #expect((result.afterBytes ?? 0) > 0)
        #expect((result.removedBytes ?? 0) > 0)
        #expect(result.freedBytes == nil)
        #expect(outcome.failed == [entry.id])
        #expect(outcome.removedCount == 0)
        #expect(fixture.log.recentEntries().first?.toolCommandResult == result)
        #expect(FileManager.default.fileExists(atPath: fixture.cache.appendingPathComponent("retained").path))
    }

    @Test("A zero exit status does not prove removal")
    func targetStillPresent() async throws {
        let fixture = try Fixture(script: "exit 0")
        let outcome = try await fixture.remove(fixture.entry())
        #expect(outcome.toolCommandResults.first?.status == .failed)
        #expect(outcome.toolCommandResults.first?.removedBytes == 0)
        #expect(outcome.removedCount == 0)
    }

    @Test("Timeouts preserve the exit status and standard error")
    func timeout() async throws {
        let fixture = try Fixture(script: "echo 'started' >&2\nexec /bin/sleep 30")
        let outcome = try await fixture.remove(fixture.entry(timeout: .milliseconds(200)))
        let result = try #require(outcome.toolCommandResults.first)
        #expect(result.status == .timedOut)
        #expect(result.terminationSignal != nil)
        #expect(result.standardError == "started\n")
        #expect(result.afterBytes != nil)
        #expect(outcome.removedCount == 0)
    }

    @Test("Stop retains earlier results and does not run later commands")
    func cancellation() async throws {
        let first = try Fixture()
        let running = try Fixture(script: "echo 'started' >&2\n/usr/bin/touch \"$GOMODCACHE/started\"\nexec /bin/sleep 30")
        let later = try Fixture()
        let ordinary = FileEntry(url: first.cache, kind: .cache, allocatedBytes: 65_536, isRegenerable: true)
        let entries = [ordinary, running.entry(), later.entry()]
        let confirmations = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            entry.toolCommand.map { (entry.id, $0) }
        })
        let task = Task {
            try await CleanupService(log: first.log).remove(entries: entries, trashFirst: false,
                confirmedToolCommands: confirmations)
        }
        for _ in 0..<300 {
            if FileManager.default.fileExists(atPath: running.cache.appendingPathComponent("started").path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: running.cache.appendingPathComponent("started").path))
        task.cancel()
        let outcome = try await task.value
        #expect(outcome.removedCount == 1)
        #expect(outcome.toolCommandResults.map(\.status) == [.cancelled, .notStarted])
        #expect(outcome.failed == [entries[1].id, entries[2].id])
        #expect(first.log.recentEntries().count == 3)
        #expect(FileManager.default.fileExists(atPath: later.cache.path))
    }

    @Test("Changed targets and executables cannot use an earlier confirmation", arguments: [true, false])
    func changedIdentity(target: Bool) async throws {
        let fixture = try Fixture()
        let entry = fixture.entry()
        let changed = target ? fixture.cache : fixture.executable
        try FileManager.default.moveItem(at: changed, to: fixture.root.appendingPathComponent("retained-original"))
        if target {
            try FileManager.default.createDirectory(at: changed, withIntermediateDirectories: true)
        } else {
            try "#!/bin/sh\nexit 0\n".write(to: changed, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: changed.path)
        }
        let outcome = try await fixture.remove(entry)
        #expect(outcome.toolCommandResults.first?.status == .notStarted)
        #expect(outcome.toolCommandResults.first?.exitStatus == nil)
        #expect(outcome.removedCount == 0)
    }

    @Test("Missing tools, exclusions, and protected files stay locked or absent")
    func scannerSafety() async throws {
        let fixture = try Fixture()
        let missing = try await PackageManagerScanner(home: fixture.root, goExecutable: { nil }).scan(context: ScanContext())
        let row = try #require(missing.entries.first)
        #expect(row.displayName == "Go module cache")
        #expect(row.isRemovalLocked)
        #expect(row.toolCommand != nil)
        let excluded = try await PackageManagerScanner(home: fixture.root).scan(
            context: ScanContext(excludedPaths: [fixture.cache.appendingPathComponent("download").path]))
        #expect(excluded.entries.isEmpty)
        let protected = try await PackageManagerScanner(home: fixture.root).scan(
            context: ScanContext(excludedPatterns: ["download"]))
        #expect(protected.entries.isEmpty)
        let available = try await PackageManagerScanner(home: fixture.root, goExecutable: { fixture.executable.path })
            .scan(context: ScanContext())
        #expect(available.entries.first?.isRemovalLocked == false)
    }

    @Test("A new protected file blocks the command after review")
    func newProtectedFile() async throws {
        let fixture = try Fixture()
        let entry = fixture.entry(patterns: ["*.keychain-db"])
        try Data([1]).write(to: fixture.cache.appendingPathComponent("Secrets.keychain-db"))
        let outcome = try await fixture.remove(entry)
        #expect(outcome.toolCommandResults.first?.status == .notStarted)
        #expect(outcome.toolCommandResults.first?.exitStatus == nil)
    }

    @Test("An unavailable history prevents command execution")
    func historyFailure() async throws {
        let fixture = try Fixture()
        let entry = fixture.entry()
        let log = RemovalLog(directory: fixture.executable)
        let outcome = try await CleanupService(log: log).remove(entries: [entry], trashFirst: true,
            confirmedToolCommands: [entry.id: try #require(entry.toolCommand)])
        #expect(outcome.toolCommandResults.first?.status == .notStarted)
        #expect(outcome.toolCommandResults.first?.failureReason?.contains("Cleanup History") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.cache.path))
    }

    @Test("Native Go removes a read-only disposable cache and preserves adjacent files",
          .enabled(if: nativeGo != nil))
    func nativeGoRemoval() async throws {
        let fixture = try Fixture()
        let executable = try #require(Self.nativeGo)
        let source = fixture.root.appendingPathComponent("go/src/project")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let marker = source.appendingPathComponent("main.go")
        try Data("package main".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o444],
            ofItemAtPath: fixture.cache.appendingPathComponent("download").path)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.cache.path)
        let review = ToolCommandRemoval.goModuleCache(at: fixture.cache, executable: executable)
        let entry = FileEntry(url: fixture.cache, displayName: "Go module cache", kind: .cache,
            allocatedBytes: 65_536, removalMethod: .toolCommand(review))
        let outcome = try await fixture.remove(entry)
        #expect(outcome.toolCommandResults.first?.status == .completed)
        #expect(outcome.toolCommandResults.first?.exitStatus == 0)
        #expect(outcome.removedCount == 1)
        #expect(FileIdentity.isAbsent(fixture.cache))
        #expect(try Data(contentsOf: marker) == Data("package main".utf8))
    }

    @Test("Symbolic link ancestors and changed executable contents cannot pass review", arguments: [true, false])
    func changedPathOrTool(symbolicLink: Bool) async throws {
        let fixture = try Fixture()
        let entry = fixture.entry()
        if symbolicLink {
            let parent = fixture.cache.deletingLastPathComponent()
            let original = fixture.root.appendingPathComponent("original-pkg")
            try FileManager.default.moveItem(at: parent, to: original)
            try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: original)
        } else {
            let handle = try FileHandle(forWritingTo: fixture.executable)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("# changed executable\n".utf8))
            try handle.close()
        }
        let outcome = try await fixture.remove(entry)
        #expect(outcome.toolCommandResults.first?.status == .notStarted)
        #expect(outcome.toolCommandResults.first?.exitStatus == nil)
    }
}
