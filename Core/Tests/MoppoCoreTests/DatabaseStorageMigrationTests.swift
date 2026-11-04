import Testing
@testable import MoppoCore

/// The generated `DatabaseStorage.roots` equals the table that `DatabaseStorage.swift` held before #352.
/// This test leaves with the old table, after the pull request records that it passed.
@Suite("Database storage migration")
struct DatabaseStorageMigrationTests {
    private static let postgreSQL = ["PG_VERSION"]
    private static let mySQL = ["ibdata1", "mysql/"]
    private static let redis = ["dump.rdb", "appendonly*"]
    private static let search = ["nodes/*/_state/", "_state/"]

    private static let oldRoots: [DatabaseStorage.Root] = [
        .init(path: "var/postgresql@*", name: "PostgreSQL data", identifiedBy: postgreSQL, tool: "PostgreSQL"),
        .init(path: "var/postgres", name: "PostgreSQL data", identifiedBy: postgreSQL, tool: "PostgreSQL"),
        .init(path: "var/mysql", name: "MySQL data", identifiedBy: mySQL, tool: "MySQL"),
        .init(path: "var/mongodb", name: "MongoDB data", identifiedBy: ["WiredTiger*"], tool: "MongoDB"),
        .init(path: "var/db/redis", name: "Redis data", identifiedBy: redis, tool: "Redis"),
        .init(path: "var/lib/opensearch", name: "OpenSearch data", identifiedBy: search, tool: "OpenSearch"),
        .init(path: "var/lib/elasticsearch", name: "Elasticsearch data", identifiedBy: search, tool: "Elasticsearch"),
        .init(path: "Library/DBeaverData", name: "DBeaver data", base: .home,
              identifiedBy: ["workspace6/*/.dbeaver/data-sources.json"], tool: "DBeaver",
              contents: "DBeaver connections, scripts, and settings"),
        .init(path: "Library/Application Support/Postgres/var-*", name: "Postgres.app data", base: .home,
              identifiedBy: postgreSQL, tool: "Postgres.app", listedWithApplication: true),
        .init(path: "Library/Application Support/com.tinyapp.DBngin/Engines/*/*", name: "DBngin data", base: .home,
              identifiedBy: postgreSQL + mySQL + redis, tool: "DBngin", listedWithApplication: true)
    ]

    private static func description(_ root: DatabaseStorage.Root) -> String {
        "\(root.base) \(root.path) | \(root.name) | \(root.identifiedBy) | \(root.tool) | \(root.contents ?? "-") | \(root.listedWithApplication)"
    }

    @Test("the generated roots equal the old table")
    func generatedRootsEqualOldTable() {
        #expect(DatabaseStorage.roots.map(Self.description).sorted() == Self.oldRoots.map(Self.description).sorted())
    }
}
