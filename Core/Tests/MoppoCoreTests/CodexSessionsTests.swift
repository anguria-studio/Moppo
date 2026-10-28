import Darwin
import Foundation
import SQLite3
import Testing
@testable import MoppoCore

@Suite("Codex session deletion")
struct CodexSessionsTests {
    private final class Fixture {
        let sandbox: AllocatedSizeMeasurerTests.Sandbox
        let home: URL
        let executable: String
        let parent = "00000000-0000-0000-0000-000000000101"
        let child = "00000000-0000-0000-0000-000000000102"
        let archived = "00000000-0000-0000-0000-000000000103"

        init() async throws {
            sandbox = try .init()
            let directory = try sandbox.directory(".codex")
            let canonical = try #require(realpath(directory.path, nil))
            home = URL(fileURLWithPath: String(cString: canonical))
            free(canonical)
            let tool = sandbox.root.appendingPathComponent("fixture-codex")
            executable = tool.path
            let script = #"""
            #!/usr/bin/python3
            import json, os, pathlib, sqlite3, sys
            if sys.argv[1:] == ['delete', '--help']:
                print('Permanently delete a saved session --force')
                sys.exit(0)
            assert sys.argv[1:3] == ['delete', '--force']
            home = pathlib.Path(os.environ['CODEX_HOME'])
            if (home / 'force-failure').exists():
                sys.exit(43)
            db = sqlite3.connect(home / 'state_5.sqlite')
            ids = [sys.argv[3]]
            for thread_id in ids:
                ids.extend(r[0] for r in db.execute('SELECT child_thread_id FROM thread_spawn_edges WHERE parent_thread_id=?', (thread_id,)))
            for thread_id in ids:
                path = db.execute('SELECT rollout_path FROM threads WHERE id=?', (thread_id,)).fetchone()[0]
                pathlib.Path(path).unlink()
                if (home / 'partial-failure').exists():
                    sys.exit(44)
                db.execute('DELETE FROM threads WHERE id=?', (thread_id,))
            db.commit()
            (home / 'native-called').write_text(json.dumps(sys.argv[1:]))
            print('Deleted session.')
            """#
            try Data(script.utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            try await sql("""
                CREATE TABLE threads(id TEXT PRIMARY KEY, rollout_path TEXT, name TEXT, title TEXT);
                CREATE TABLE thread_spawn_edges(parent_thread_id TEXT, child_thread_id TEXT PRIMARY KEY, status TEXT);
                """)
        }

        func sql(_ query: String) async throws {
            try await ProcessRunner().run("/usr/bin/sqlite3", [home.appendingPathComponent("state_5.sqlite").path, query])
        }

        @discardableResult
        func session(_ id: String, archived: Bool = false, name: String = "Fixture session", compressed: Bool = false) async throws -> URL {
            let folder = archived ? "archived_sessions" : "sessions"
            let suffix = compressed ? ".jsonl.zst" : ".jsonl"
            let url = home.appendingPathComponent("\(folder)/rollout-2026-01-01T00-00-00-\(id)\(suffix)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let header: [String: Any] = ["type": "session_meta", "payload": ["id": id]]
            var data = try JSONSerialization.data(withJSONObject: header)
            data.append(Data("\n".utf8))
            data.append(Data(repeating: 0x20, count: 8192))
            // The command fixture owns these contents. Moppo must not parse compressed history.
            if compressed { data = Data("Opaque compressed history fixture".utf8) }
            try data.write(to: url)
            try await sql("INSERT INTO threads VALUES ('\(id)', '\(url.path)', '\(name)', '\(name)');")
            return url
        }

        func scan(_ context: ScanContext = .init()) async throws -> ScanCategoryResult {
            try await AIToolsScanner(home: home.deletingLastPathComponent(), codexExecutable: executable).scan(context: context)
        }

        func row(_ id: String) async throws -> FileEntry {
            let result = try await scan()
            return try #require(result.entries.flatMap(\.children).first { $0.codexSession?.threadID == id })
        }

        func service() -> CleanupService {
            let home = home
            let executable = executable
            return CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) },
                log: RemovalLog(directory: home.appendingPathComponent("moppo-receipts")),
                deleteCodexSession: { try await CodexSessions(home: home, executable: executable).remove($0) })
        }

        func lock(_ id: String) throws -> Int32 {
            let directory = home.appendingPathComponent("thread-writer-locks")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let descriptor = open(directory.appendingPathComponent(id + ".lock").path, O_CREAT | O_RDWR, 0o600)
            try #require(descriptor >= 0)
            try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
            return descriptor
        }
    }

    @Test("Session groups count child history once and protect active writers")
    func reviewedInventory() async throws {
        let fixture = try await Fixture()
        try await fixture.session(fixture.parent, name: "Parent session")
        try await fixture.session(fixture.child, archived: true, compressed: true)
        try await fixture.session(fixture.archived, archived: true, name: "Archived session")
        try await fixture.sql("INSERT INTO thread_spawn_edges VALUES ('\(fixture.parent)', '\(fixture.child)', 'completed');")
        let result = try await fixture.scan()
        let rows = result.entries.flatMap(\.children).filter { $0.codexSession != nil }
        #expect(rows.count == 2)
        #expect(result.entries.filter { $0.url.lastPathComponent != ".codex" }
            .allSatisfy { $0.aiStorageSection?.owner == .codex })
        let parent = try #require(rows.first { $0.codexSession?.threadID == fixture.parent })
        #expect(parent.displayName == "Parent session")
        #expect(parent.codexSession?.members.count == 2)
        #expect(rows.allSatisfy { $0.protectionReason == .userData && !$0.regeneratesSafely })
        #expect(result.safeToRemoveBytes == 0)
        #expect(result.totalBytes == (try await AllocatedSizeMeasurer().measure(fixture.home)).allocatedBytes)
        #expect(CleanupSelection.ids(in: [result], selected: Set(rows.map(\.id)), scope: .safe).isEmpty)

        let descriptor = try fixture.lock(fixture.child)
        defer { close(descriptor) }
        let active = try await fixture.row(fixture.parent)
        #expect(active.protectionReason == .inventory)
        #expect(!CleanupService.removalAllowed(active, userDataRemovalOverrides: [active.id]))
    }

    @Test("A history path without the private folder prefix matches its scanned file", arguments: [false, true])
    func privateFolderPath(compressed: Bool) async throws {
        let fixture = try await Fixture()
        let url = try await fixture.session(fixture.parent, compressed: compressed)
        try #require(url.path.hasPrefix("/private/"))
        try await fixture.sql("UPDATE threads SET rollout_path='\(url.path.dropFirst("/private".count))';")
        #expect(try await fixture.row(fixture.parent).codexSession?.members.map(\.url) == [url])
    }

    @Test("Reviewed deletion uses Codex, includes children, and records permanent removal", arguments: [false, true])
    func nativeDeletion(compressed: Bool) async throws {
        let fixture = try await Fixture()
        let parent = try await fixture.session(fixture.parent, compressed: compressed)
        let child = try await fixture.session(fixture.child, archived: true, compressed: compressed)
        try await fixture.sql("INSERT INTO thread_spawn_edges VALUES ('\(fixture.parent)', '\(fixture.child)', 'completed');")
        let retainedPaths = ["auth.json", "config.toml", "memories/memory_summary.md",
                             "attachments/original.png", "generated_images/output.png"]
        var retained: [URL: Data] = [:]
        for path in retainedPaths {
            let url = fixture.home.appendingPathComponent(path)
            let data = Data("Keep \(path)".utf8)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            retained[url] = data
        }
        let row = try await fixture.row(fixture.parent)
        let refused = try await fixture.service().remove(entries: [row], trashFirst: true)
        #expect(refused.failed == [row.url.path])
        #expect(FileManager.default.fileExists(atPath: parent.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("native-called").path))

        let outcome = try await fixture.service().remove(entries: [row], trashFirst: true,
                                                        userDataRemovalOverrides: [row.id])
        #expect(outcome.failed.isEmpty)
        #expect(outcome.deletedCount == 2 && outcome.trashedCount == 0)
        #expect(!FileManager.default.fileExists(atPath: parent.path))
        #expect(!FileManager.default.fileExists(atPath: child.path))
        for (url, data) in retained { #expect(try Data(contentsOf: url) == data) }
        let receipt = RemovalLog(directory: fixture.home.appendingPathComponent("moppo-receipts")).recentEntries()
        #expect(receipt.filter { $0.disposition == .deleted }.count == 2)
        #expect(receipt.filter { $0.disposition == .deleted }.allSatisfy { $0.trashedPath == nil })
        #expect(!CleanupService.alwaysMovesToTrash(row))
        var unprotected = row
        unprotected.protectionReason = nil
        #expect(!CleanupService.removalAllowed(unprotected, userDataRemovalOverrides: []))
    }

    enum Installation: CaseIterable {
        case noDeletion, missingDatabase, legacySchema, differentDatabaseVersion, unreadableDatabase, unreadableWAL, invalidDatabase
    }

    @Test("CLI history remains visible and protected when verified deletion is unavailable", arguments: Installation.allCases)
    func compatibleInventory(_ installation: Installation) async throws {
        let fixture = try await Fixture()
        let parent = try await fixture.session(fixture.parent, name: "CLI conversation")
        let archived = try await fixture.session(fixture.archived, archived: true, name: "Archived CLI conversation", compressed: true)
        let database = fixture.home.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        var unreadablePath: String?
        defer {
            if let unreadablePath {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadablePath)
            }
            sqlite3_close(connection)
        }
        var executable = fixture.executable
        switch installation {
        case .noDeletion:
            executable = "/usr/bin/false"
        case .missingDatabase:
            try FileManager.default.removeItem(at: database)
        case .legacySchema:
            try await fixture.sql("ALTER TABLE threads DROP COLUMN name; DROP TABLE thread_spawn_edges;")
        case .differentDatabaseVersion:
            try FileManager.default.moveItem(at: database, to: fixture.home.appendingPathComponent("state_6.sqlite"))
        case .unreadableDatabase:
            unreadablePath = database.path
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: database.path)
        case .unreadableWAL:
            try #require(sqlite3_open(database.path, &connection) == SQLITE_OK)
            try #require(sqlite3_exec(connection, "PRAGMA journal_mode=WAL; UPDATE threads SET title=title;", nil, nil, nil) == SQLITE_OK)
            unreadablePath = database.path + "-wal"
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: database.path + "-wal")
        case .invalidDatabase:
            try Data("Private fixture contents must not appear in diagnostics.".utf8).write(to: database)
        }
        let scanner = AIToolsScanner(home: fixture.home.deletingLastPathComponent(), codexExecutable: executable)
        let log = try ScanDiagnostics(directory: fixture.sandbox.root.appendingPathComponent("diagnostics"))
        let result = try await ScanDiagnostics.$current.withValue(log.context) {
            try await scanner.scan(context: .init())
        }
        log.finish(outcome: "completed")
        log.flush()
        let groups = result.entries.filter { ["sessions", "archived_sessions"].contains($0.url.lastPathComponent) }
        let rows = groups.flatMap(\.children)
        #expect(groups.count == 2)
        #expect(Set(rows.map(\.url)) == [parent, archived])
        #expect(rows.allSatisfy { $0.protectionReason == .inventory && $0.codexSession == nil })
        #expect(rows.allSatisfy { !CleanupService.removalAllowed($0, userDataRemovalOverrides: [$0.id]) })
        #expect(groups.allSatisfy { $0.aiStorageSection?.owner == .codex })
        #expect(result.safeToRemoveBytes == 0)
        #expect(result.totalBytes == (try await AllocatedSizeMeasurer().measure(fixture.home)).allocatedBytes)
        if [.missingDatabase, .unreadableDatabase, .unreadableWAL, .invalidDatabase].contains(installation) {
            #expect(rows.first { $0.url == parent }?.displayName.contains(fixture.parent) == true)
        } else {
            #expect(rows.first { $0.url == parent }?.displayName == "CLI conversation")
        }
        let excluded = try await scanner.scan(context: .init(excludedPaths: [parent.standardizedFileURL.path]))
        #expect(!excluded.entries.flatMap(\.children).contains { $0.url == parent })
        #expect(FileManager.default.fileExists(atPath: parent.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("native-called").path))
        if unreadablePath != nil || installation == .invalidDatabase {
            let text = try String(contentsOf: log.fileURL, encoding: .utf8)
            #expect(!text.contains("Private fixture contents"))
            let events = try text.split(separator: "\n").map {
                try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
            }
            let access = events.filter { $0["event"] as? String == "codex_database_file_access" }
                .compactMap { $0["details"] as? [String: String] }
            #expect(Set(access.compactMap { $0["path"] }) == [fixture.home.path, database.path,
                database.path + "-wal", database.path + "-shm"])
            let probes = events.filter { $0["event"] as? String == "codex_database_read_probe" }
                .compactMap { $0["details"] as? [String: String] }
            #expect(Set(probes.compactMap { $0["operation"] }) == ["session_inventory", "session_titles"])
            #expect(probes.allSatisfy { $0["readable"] == "false" })
            if let unreadablePath {
                #expect(access.filter { $0["path"] == unreadablePath }.allSatisfy { $0["read_open_errno"] == "\(EACCES)" })
                #expect(probes.allSatisfy { $0["system_errno"] == "\(EACCES)" })
            } else {
                #expect(probes.allSatisfy { $0["extended_error_code"] == "26" })
            }
        }
    }

    @Test("A partial native failure records removed history and retains the failure")
    func partialNativeFailure() async throws {
        let fixture = try await Fixture()
        let parent = try await fixture.session(fixture.parent)
        let child = try await fixture.session(fixture.child)
        try await fixture.sql("INSERT INTO thread_spawn_edges VALUES ('\(fixture.parent)', '\(fixture.child)', 'completed');")
        let row = try await fixture.row(fixture.parent)
        try Data().write(to: fixture.home.appendingPathComponent("partial-failure"))
        let outcome = try await fixture.service().remove(entries: [row], trashFirst: true,
                                                        userDataRemovalOverrides: [row.id])
        #expect(outcome.deletedCount == 1 && outcome.trashedCount == 0)
        #expect(outcome.failed == [row.url.path])
        #expect(!FileManager.default.fileExists(atPath: parent.path))
        #expect(FileManager.default.fileExists(atPath: child.path))
        let records = RemovalLog(directory: fixture.home.appendingPathComponent("moppo-receipts")).recentEntries()
        #expect(records.contains { $0.originalPath == parent.path && $0.disposition == .deleted })
        #expect(records.contains { $0.disposition == .failed })
    }

    enum Change: CaseIterable { case appendHistory, replaceFile, addChild, writer, openHistory, symlink, nativeFailure, changeFormat }

    @Test("Changes after review stop native deletion", arguments: Change.allCases, [false, true])
    func revalidate(_ change: Change, compressed: Bool) async throws {
        let fixture = try await Fixture()
        var url = try await fixture.session(fixture.parent, compressed: compressed)
        let row = try await fixture.row(fixture.parent)
        var descriptor: Int32?
        var handle: FileHandle?
        defer {
            if let descriptor { close(descriptor) }
            try? handle?.close()
        }
        switch change {
        case .appendHistory:
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("Changed history".utf8))
            try handle.close()
        case .replaceFile:
            let data = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url)
            try data.write(to: url)
        case .addChild:
            try await fixture.session(fixture.child)
            try await fixture.sql("INSERT INTO thread_spawn_edges VALUES ('\(fixture.parent)', '\(fixture.child)', 'completed');")
        case .writer:
            descriptor = try fixture.lock(fixture.parent)
        case .openHistory:
            handle = try FileHandle(forWritingTo: url)
        case .symlink:
            let moved = fixture.home.appendingPathComponent("retained.jsonl")
            try FileManager.default.moveItem(at: url, to: moved)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: moved)
        case .nativeFailure:
            try Data().write(to: fixture.home.appendingPathComponent("force-failure"))
        case .changeFormat:
            let moved = compressed ? url.deletingPathExtension() : url.appendingPathExtension("zst")
            try FileManager.default.moveItem(at: url, to: moved)
            try await fixture.sql("UPDATE threads SET rollout_path='\(moved.path)';")
            url = moved
        }
        let outcome = try await fixture.service().remove(entries: [row], trashFirst: false,
                                                        userDataRemovalOverrides: [row.id])
        #expect(outcome.removedCount == 0)
        #expect(outcome.failed == [row.url.path])
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("native-called").path))
    }

    enum CompressedPath: CaseIterable { case beforeCompression, unrelated, existingPlaintext }

    @Test("Compressed history accepts only its own missing plaintext path", arguments: CompressedPath.allCases)
    func compressedPath(_ path: CompressedPath) async throws {
        let fixture = try await Fixture()
        let url = try await fixture.session(fixture.parent, archived: true, compressed: true)
        let saved: URL
        switch path {
        case .beforeCompression:
            saved = url.deletingPathExtension()
        case .unrelated:
            saved = url.deletingLastPathComponent().appendingPathComponent("other.jsonl")
        case .existingPlaintext:
            saved = url.deletingPathExtension()
            try Data("Unknown metadata\n".utf8).write(to: saved)
        }
        try await fixture.sql("UPDATE threads SET rollout_path='\(saved.path)';")
        let rows = try await fixture.scan().entries.flatMap(\.children)
        if path == .beforeCompression {
            let row = try #require(rows.first { $0.codexSession != nil })
            #expect(row.protectionReason == .userData)
            #expect(row.codexSession?.members.map(\.url) == [url])
            let excluded = try await fixture.scan(ScanContext(excludedPaths: [url.standardizedFileURL.path]))
            #expect(excluded.entries.flatMap(\.children).allSatisfy { $0.codexSession == nil })
        } else {
            #expect(rows.allSatisfy { $0.codexSession == nil && $0.protectionReason == .inventory })
        }
    }

    @Test("Exclusions and unknown session metadata prevent reviewed deletion")
    func unsupportedStorage() async throws {
        let fixture = try await Fixture()
        let url = try await fixture.session(fixture.parent)
        let excluded = try await fixture.scan(ScanContext(excludedPaths: [url.standardizedFileURL.path]))
        #expect(excluded.entries.flatMap(\.children).allSatisfy { $0.codexSession == nil })
        try Data("Unknown format\n".utf8).write(to: url)
        let unknown = try await fixture.scan()
        #expect(unknown.entries.flatMap(\.children).allSatisfy { $0.codexSession == nil })
        #expect(unknown.entries.allSatisfy { $0.protectionReason == .inventory })
        #expect(unknown.safeToRemoveBytes == 0)
    }

    @Test("Additional history copies keep the whole deletion group locked")
    func additionalHistoryFiles() async throws {
        let fixture = try await Fixture()
        let url = try await fixture.session(fixture.parent)
        let copied = url.deletingLastPathComponent().appendingPathComponent("additional.jsonl")
        try FileManager.default.copyItem(at: url, to: copied)
        var scan = try await fixture.scan()
        #expect(scan.entries.flatMap(\.children).allSatisfy { $0.codexSession == nil })
        try FileManager.default.removeItem(at: copied)
        try Data("Compressed fixture".utf8).write(to: url.appendingPathExtension("zst"))
        scan = try await fixture.scan()
        #expect(scan.entries.flatMap(\.children).allSatisfy { $0.codexSession == nil })
        let rows = scan.entries.filter { $0.url.lastPathComponent == "sessions" }.flatMap(\.children)
        #expect(Set(rows.map(\.url)) == [url, url.appendingPathExtension("zst")])
        #expect(rows.allSatisfy { $0.protectionReason == .inventory })
        #expect(scan.totalBytes == (try await AllocatedSizeMeasurer().measure(fixture.home)).allocatedBytes)

        let unknownName = url.deletingLastPathComponent().appendingPathComponent("extra-\(fixture.parent).jsonl.zst")
        try FileManager.default.moveItem(at: url.appendingPathExtension("zst"), to: unknownName)
        let ambiguous = try await fixture.scan()
        #expect(ambiguous.entries.flatMap(\.children).allSatisfy { $0.codexSession == nil })
    }
}
