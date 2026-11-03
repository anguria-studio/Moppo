import Foundation
import Testing
@testable import MoppoCore

/// Database data folders in Hidden & System Data.
///
/// The fixture layouts copy the file names that the #257 checks recorded on macOS 27.2.
/// The files contain zeros, not database contents.
@Suite("Database data folders")
struct DatabaseStorageTests {
    private final class Sandbox {
        let root: URL
        let home: URL
        let homebrew: URL

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("moppo-databases-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            homebrew = root.appendingPathComponent("homebrew", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Writes each file below `base`. A path that ends in `/` is a folder.
        func layout(_ paths: [String], under base: URL, bytes: Int = 64 * 1024) throws {
            for path in paths {
                let url = base.appendingPathComponent(path)
                if path.hasSuffix("/") {
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                } else {
                    try FileManager.default.createDirectory(
                        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data(count: bytes).write(to: url)
                }
            }
        }

        func scan() async throws -> ScanCategoryResult {
            try await HiddenDataScanner(home: home, homebrewPrefixes: [homebrew]).scan(context: ScanContext())
        }
    }

    @Test("Each recognized database folder is a protected row with its size")
    func recognizedFoldersAreProtectedRows() async throws {
        let sandbox = try Sandbox()
        try sandbox.layout([
            "var/postgresql@18/PG_VERSION", "var/postgresql@18/base/1/1259", "var/postgresql@18/pg_wal/000000010000000000000001",
            // An older version stays after an upgrade.
            "var/postgresql@17/PG_VERSION", "var/postgresql@17/global/pg_control",
            "var/postgres/PG_VERSION",
            "var/mysql/ibdata1", "var/mysql/mysql/", "var/mysql/binlog.000001", "var/mysql/binlog.index",
            "var/mongodb/WiredTiger", "var/mongodb/WiredTiger.wt", "var/mongodb/journal/WiredTigerLog.0000000001",
            "var/lib/opensearch/nodes/0/_state/node-1.st", "var/lib/opensearch/nodes/0/node.lock",
            "var/lib/elasticsearch/_state/node-0.st"
        ], under: sandbox.homebrew)
        // Smaller than the 1 MiB noise floor.
        try sandbox.layout(["var/db/redis/dump.rdb"], under: sandbox.homebrew, bytes: 8 * 1024)
        try sandbox.layout([
            "Library/DBeaverData/workspace6/General/.dbeaver/data-sources.json",
            "Library/DBeaverData/workspace6/.metadata/dbeaver-workspace.properties"
        ], under: sandbox.home)
        // Large enough for the archive search, which must not offer a file in a database folder.
        try sandbox.layout(["Library/DBeaverData/workspace6/General/Scripts/export.zip"],
                           under: sandbox.home, bytes: 260 * 1024 * 1024)

        let result = try await sandbox.scan().filteringNoise(below: 1024 * 1024)

        let expected = [
            "PostgreSQL data (postgresql@17)", "PostgreSQL data (postgresql@18)", "PostgreSQL data", "MySQL data",
            "MongoDB data", "Redis data", "OpenSearch data", "Elasticsearch data", "DBeaver data"
        ]
        #expect(result.entries.map(\.displayName).sorted() == expected.sorted())
        for entry in result.entries {
            #expect(entry.protectionReason == .inventory)
            #expect(entry.protectionExplanation?.contains("Moppo never removes database data") == true)
            #expect(entry.allocatedBytes > 0 && entry.displayBytes == entry.allocatedBytes)
            #expect(entry.reclaimableBytes == 0)
        }
        #expect(result.totalBytes == result.entries.reduce(0) { $0 + $1.displayBytes })
    }

    @Test("A database folder name without its database files is not protected")
    func folderNameIsNotEvidence() async throws {
        let sandbox = try Sandbox()
        try sandbox.layout([
            "var/postgresql@16/postgresql.conf",
            "var/mysql/my.cnf", "var/mysql/mysql",
            "var/mongodb/mongod.conf",
            "var/db/redis/redis.conf",
            "var/lib/opensearch/nodes/0/node.lock",
            "var/lib/opensearch/_state"
        ], under: sandbox.homebrew)
        try sandbox.layout(["Library/DBeaverData/workspace6/General/.project"], under: sandbox.home)
        try sandbox.layout(["Library/Application Support/Postgres/var-18/PG_VERSION"], under: sandbox.home)

        #expect(DatabaseStorage.locations(home: sandbox.home, homebrewPrefixes: [sandbox.homebrew])
            .map(\.root.name) == ["Postgres.app data"])
        // The application row lists Postgres.app data. Hidden & System Data does not.
        #expect(try await sandbox.scan().entries.isEmpty)
    }
}
