import Foundation
import Testing
@testable import MoppoCore

/// The documents and the Swift tables record the same rules.
///
/// `docs/tool-catalog.md` and `docs/ai-storage.md` record tool storage for people.
/// The Swift tables hold the rules that Moppo uses. A row that names a rule Moppo
/// does not have, or a rule with no row, misleads the next person who adds a rule
/// from the catalog. #335 found such rows on `main`. Change a document and its
/// table together.
///
/// The catalog rows for `<project>` folders describe lockfile checks in code, not
/// table rules, so this suite does not compare them.
@Suite("Rule documents match the Swift tables")
struct RuleDocumentTests {

    // MARK: - The documents

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MoppoCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Core
        .deletingLastPathComponent()   // The repository

    private static func document(_ name: String) throws -> [String] {
        let url = repository.appendingPathComponent("docs").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// One row of a Markdown table: its cells, without the outer bars.
    private static func cells(_ line: String) -> [String]? {
        guard line.hasPrefix("| ") else { return nil }
        return line.trimmingCharacters(in: .whitespaces)
            .dropFirst().dropLast()
            .components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func codeSpans(_ cell: String) -> [String] {
        cell.components(separatedBy: "`").enumerated().compactMap { $0.offset % 2 == 1 ? $0.element : nil }
    }

    struct CatalogRow {
        let line: Int
        let paths: [String]
        let type: String
        let today: String
    }

    /// The rows of each ecosystem table, with the `Moppo today` value of each row.
    private static func catalogRows() throws -> [CatalogRow] {
        try document("tool-catalog.md").enumerated().compactMap { index, line in
            guard let cells = cells(line), cells.count == 7, cells[0].hasPrefix("`") else { return nil }
            return CatalogRow(line: index + 1, paths: codeSpans(cells[0]), type: cells[1], today: cells[5])
        }
    }

    /// The values that the `Columns` table defines for `Moppo today`.
    private static func catalogVocabulary() throws -> Set<String> {
        let legend = try document("tool-catalog.md").first { $0.hasPrefix("| Moppo today |") }
        let words = codeSpans(legend ?? "").filter { word in
            word.allSatisfy(\.isLetter)
        }
        return Set(words)
    }

    /// The `Default paths` of the AI Tools coverage table.
    struct AIStoragePath {
        let line: Int
        let tool: String
        let path: String
    }

    private static func aiStoragePaths() throws -> [AIStoragePath] {
        try document("ai-storage.md").enumerated().flatMap { index, line -> [AIStoragePath] in
            guard let cells = cells(line), cells.count == 3, !cells[1].hasPrefix("-") else { return [] }
            return codeSpans(cells[1]).filter { $0.hasPrefix("~/") || $0.hasPrefix("/") }
                .map { AIStoragePath(line: index + 1, tool: cells[0], path: $0) }
        }
    }

    // MARK: - The tables

    enum Treatment { case offer, protect }

    struct Rule: CustomStringConvertible {
        let path: String
        let treatment: Treatment
        let table: String
        var description: String { "\(path) (\(table))" }
    }

    /// Every path with a dedicated rule, in the `~/` form that the documents use.
    private static let rules: [Rule] = {
        var rules: [Rule] = []
        for root in PackageManagerScanner.roots {
            rules.append(Rule(path: "~/" + root.components.joined(separator: "/"), treatment: .offer,
                              table: "PackageManagerScanner.roots"))
        }
        rules.append(Rule(path: "~/go/pkg/mod", treatment: .offer, table: "PackageManagerScanner.scan"))
        for (path, folder, table) in toolHomeFolders {
            rules.append(Rule(path: path, treatment: .protect, table: table))
            for cache in folder.caches {
                rules.append(Rule(path: path + "/" + cache.path, treatment: .offer, table: table + ".caches"))
            }
        }
        for root in DatabaseStorage.roots {
            let base = root.base == .home ? "~/" : "/opt/homebrew/"
            rules.append(Rule(path: base + root.path, treatment: .protect, table: "DatabaseStorage.roots"))
        }
        for root in AIToolStorage.roots {
            let base = root.base == .home ? "~/" : "/Applications/"
            rules.append(Rule(path: base + root.path, treatment: .protect, table: "AIToolStorage.roots"))
        }
        for folder in ApplicationDataFolders.byBundleIdentifier.values.joined() {
            rules.append(Rule(path: "~/" + folder.path, treatment: .protect,
                              table: "ApplicationDataFolders.byBundleIdentifier"))
        }
        for curation in ApplicationsScanner.curations.values {
            rules.append(Rule(path: "~/" + curation.root, treatment: .protect, table: "ApplicationsScanner.curations"))
            for subpath in curation.regenerable {
                rules.append(Rule(path: "~/" + curation.root + "/" + subpath, treatment: .offer,
                                  table: "ApplicationsScanner.curations.regenerable"))
            }
        }
        for cache in SystemCachesScanner.applicationSupportCaches {
            rules.append(Rule(path: "~/Library/Application Support/" + cache.components.joined(separator: "/"),
                              treatment: .offer, table: "SystemCachesScanner.applicationSupportCaches"))
        }
        for editor in EditorExtensionStores.editors {
            rules.append(Rule(path: "~/" + editor.dotFolder + "/extensions", treatment: .offer,
                              table: "EditorExtensionStores.editors"))
        }
        for path in modelStorePaths {
            rules.append(Rule(path: path, treatment: .protect, table: "LocalModelStores"))
        }
        return rules
    }()

    /// The protected home folders and the tool storage locations, each with its path in the `~/` form.
    private static let toolHomeFolders: [(path: String, folder: ToolHomeFolders.Folder, table: String)] =
        ToolHomeFolders.all.map { ("~/" + $0.name, $0, "ToolHomeFolders.all") }
        + ToolHomeFolders.locations.map {
            (($0.base == .home ? "~/" : "/Users/Shared/") + $0.path, $0.folder, "ToolHomeFolders.locations")
        }

    /// The folders that the model readers claim or read. Model rows need review, so they count as protected here.
    private static let modelStorePaths: [String] =
        LocalModelStores.homeDotFolders.map { "~/" + $0 }
        + LocalModelStores.dotCacheFolders.map { "~/.cache/" + $0 }
        + LocalModelStores.partlyClaimedFolders.flatMap { folder, children in children.map { "~/" + folder + "/" + $0 } }
        + LocalModelStores.lmStudioStores.map { "~/" + $0 }
        + ["~/" + LocalModelStores.gpt4AllStore]

    // MARK: - Matching

    /// `<version>` in a document and `*` in a table both stand for any one component.
    private static func components(_ path: String) -> [String] {
        path.replacingOccurrences(of: "<[^>]+>", with: "*", options: .regularExpression)
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty || path.hasPrefix("/") }
    }

    private static func component(_ a: String, matches b: String) -> Bool {
        a == b || fnmatch(a, b, 0) == 0 || fnmatch(b, a, 0) == 0
    }

    /// The two paths name the same item.
    static func same(_ documentPath: String, _ rulePath: String) -> Bool {
        let a = components(documentPath), b = components(rulePath)
        return a.count == b.count && zip(a, b).allSatisfy { component($0, matches: $1) }
    }

    /// The rule path is the document path or a folder above it.
    static func covers(_ rulePath: String, _ documentPath: String) -> Bool {
        let a = components(documentPath), b = components(rulePath)
        return a.count >= b.count && zip(a, b).allSatisfy { component($0, matches: $1) }
    }

    private static func rules(matching path: String) -> [Rule] {
        rules.filter { same(path, $0.path) }
    }

    private static func rules(covering path: String) -> [Rule] {
        rules.filter { covers($0.path, path) }
    }

    private static var catalogPathsForComparison: [String] {
        get throws { try catalogRows().flatMap(\.paths).filter { !$0.hasPrefix("<project>") } }
    }

    /// Every path that `docs/ai-storage.md` names, in a table or in a sentence.
    /// That document has priority for AI storage, such as the ai-coustics models that a location protects.
    private static var aiStorageMentions: [String] {
        get throws {
            try document("ai-storage.md").flatMap(codeSpans).filter { $0.hasPrefix("~/") || $0.hasPrefix("/") }
        }
    }

    // MARK: - The catalog

    @Test("the Moppo today column uses only the values that the Columns table defines")
    func catalogColumnUsesDefinedValues() throws {
        let vocabulary = try Self.catalogVocabulary()
        #expect(vocabulary.isSuperset(of: ["Row", "Protected", "Caches", "Hidden", "Size", "No"]))
        let undefined = try Self.catalogRows().filter { row in
            !vocabulary.contains(row.today) && row.today.range(of: #"^#\d+$"#, options: .regularExpression) == nil
        }
        #expect(undefined.isEmpty, "\(undefined.map { "line \($0.line): \($0.today)" })")
    }

    @Test("each Row path is a path that a table offers")
    func rowPathsHaveOfferRules() throws {
        for row in try Self.catalogRows() where row.today == "Row" {
            for path in row.paths where !path.hasPrefix("<project>") {
                let offered = Self.rules(matching: path).filter { $0.treatment == .offer }
                #expect(!offered.isEmpty, "line \(row.line): no table offers \(path)")
            }
        }
    }

    @Test("each Protected path is in a path that a table protects")
    func protectedPathsHaveProtectionRules() throws {
        for row in try Self.catalogRows() where row.today == "Protected" {
            for path in row.paths where !path.hasPrefix("<project>") {
                let protected = Self.rules(covering: path).filter { $0.treatment == .protect }
                #expect(!protected.isEmpty, "line \(row.line): no table protects \(path)")
            }
        }
    }

    @Test("a path with a dedicated rule is not a Hidden, Caches, Size, or No row")
    func genericRowsHaveNoDedicatedRule() throws {
        for row in try Self.catalogRows() where ["Hidden", "Caches", "Size", "No"].contains(row.today) {
            for path in row.paths where !path.hasPrefix("<project>") {
                let dedicated = Self.rules(matching: path)
                #expect(dedicated.isEmpty, "line \(row.line): \(path) is \(row.today), but \(dedicated) is a rule")
            }
        }
    }

    @Test("each protected home folder and tool storage location is in a document")
    func protectedHomeFoldersHaveRows() throws {
        let paths = try Self.catalogPathsForComparison + Self.aiStorageMentions
        for (path, _, _) in Self.toolHomeFolders {
            #expect(paths.contains { Self.covers(path, $0) }, "no document names \(path) or a path in it")
        }
    }

    @Test("each verified cache in a protected home folder is a Row")
    func homeFolderCachesAreRows() throws {
        let rows = try Self.catalogRows()
        for (folderPath, folder, _) in Self.toolHomeFolders {
            for cache in folder.caches {
                let path = folderPath + "/" + cache.path
                let row = rows.first { $0.paths.contains { Self.same($0, path) } }
                #expect(row?.today == "Row", "\(path) is \(row?.today ?? "not in the catalog")")
            }
        }
    }

    @Test("each database data folder has a Protected catalog row")
    func databaseFoldersHaveRows() throws {
        let rows = try Self.catalogRows()
        for root in DatabaseStorage.roots {
            let path = (root.base == .home ? "~/" : "/opt/homebrew/") + root.path
            let row = rows.first { $0.paths.contains { Self.same($0, path) } }
            #expect(row?.today == "Protected", "\(path) is \(row?.today ?? "not in the catalog")")
        }
    }

    // MARK: - AI storage

    @Test("each AI Tools default path is an AI storage root, a model store, or an application data folder")
    func aiStoragePathsHaveRules() throws {
        let tables: Set<String> = ["AIToolStorage.roots", "LocalModelStores", "ApplicationDataFolders.byBundleIdentifier"]
        for entry in try Self.aiStoragePaths() {
            let covered = Self.rules(covering: entry.path).filter { tables.contains($0.table) }
            #expect(!covered.isEmpty, "line \(entry.line): \(entry.tool) names \(entry.path), which no root claims")
        }
    }

    @Test("each AI storage root is in the AI Tools coverage table")
    func aiStorageRootsAreDocumented() throws {
        let documented = try Self.aiStoragePaths().map(\.path)
        for root in AIToolStorage.roots {
            let path = (root.base == .home ? "~/" : "/Applications/") + root.path
            #expect(documented.contains { Self.same($0, path) }, "docs/ai-storage.md does not list \(path)")
        }
    }

    // MARK: - The matcher

    @Test("placeholders and globs match one component")
    func matching() {
        #expect(Self.same("/opt/homebrew/var/postgresql@<version>", "/opt/homebrew/var/postgresql@*"))
        #expect(Self.same("~/Library/Application Support/Postgres/var-<version>",
                          "~/Library/Application Support/Postgres/var-*"))
        #expect(Self.same("~/ComfyUI-Installs", "~/ComfyUI-Installs"))
        #expect(!Self.same("~/.cabal/packages", "~/.cache/cabal"))
        #expect(!Self.same("~/.m2", "~/.m2/repository"))
        #expect(Self.covers("~/.rustup", "~/.rustup/toolchains/<name>"))
        #expect(Self.covers("~/.cache/whisper", "~/.cache/whisper/*.pt"))
        #expect(!Self.covers("~/.rustup/toolchains", "~/.rustup"))
    }
}
