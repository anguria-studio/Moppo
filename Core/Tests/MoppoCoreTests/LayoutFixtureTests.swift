import Foundation
import Testing
@testable import MoppoCore

/// Each rule in `rules/` recognizes the layout that it records, and no other layout.
///
/// The suite reads the registry files and builds each layout in a temporary home:
/// the folder with the items that its `layout` and `identifiedBy` fields name, and the
/// same folder without them. A rule with items must recognize the first and refuse the
/// second. A rule without items recognizes the folder by its name.
///
/// `Fixtures/Layouts/<tool>.txt` holds the names from the #216 manifests of a rented Mac:
/// folders at two levels and the files that rules name, with no contents. Where a tool
/// has such a fixture, the suite also builds it and checks that each rule of the tool
/// recognizes the real layout. A new tool needs one JSON file and, when a manifest
/// exists, one fixture file.
@Suite("Registry rules recognize their layouts")
struct LayoutFixtureTests {

    // MARK: - The registry

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    struct Rule: CustomStringConvertible {
        let tool: String
        let table: String
        let treatment: String
        let path: String
        let identifiedBy: [String]
        let layout: [String]
        let name: String?
        var description: String { "\(tool): \(path)" }
    }

    /// Every rule with a table, in registry order.
    static let rules: [Rule] = {
        let folder = repository.appendingPathComponent("rules")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return files.flatMap { file -> [Rule] in
            guard file.hasSuffix(".json"), file != "sections.json",
                  let data = try? Data(contentsOf: folder.appendingPathComponent(file)),
                  let tool = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = tool["id"] as? String, let storage = tool["storage"] as? [[String: Any]]
            else { return [] }
            return storage.flatMap { entry -> [Rule] in
                guard let table = entry["table"] as? String else { return [] }
                let paths = (entry["paths"] as? [String]) ?? [entry["path"] as? String].compactMap { $0 }
                return paths.map {
                    Rule(tool: id, table: table, treatment: entry["treatment"] as? String ?? "",
                         path: $0, identifiedBy: entry["identifiedBy"] as? [String] ?? [],
                         layout: entry["layout"] as? [String] ?? [], name: entry["name"] as? String)
                }
            }
        }
    }()

    static func rules(table: String, treatment: String? = nil) -> [Rule] {
        rules.filter { $0.table == table && (treatment == nil || $0.treatment == treatment) }
    }

    // MARK: - A temporary Mac

    /// A home, a Homebrew prefix, a shared folder, and an applications folder, all empty.
    final class Mac {
        let root: URL
        var home: URL { root.appendingPathComponent("home", isDirectory: true) }
        var homebrew: URL { root.appendingPathComponent("homebrew", isDirectory: true) }
        var shared: URL { root.appendingPathComponent("shared", isDirectory: true) }
        var applications: URL { root.appendingPathComponent("applications", isDirectory: true) }

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("moppo-layouts-\(UUID().uuidString)", isDirectory: true)
            for folder in [home, homebrew, shared, applications] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// The folder of a registry path. `<name>` and `*` become `x`.
        func url(_ path: String) -> URL {
            let literal = path.replacingOccurrences(of: "<[^>]+>", with: "x", options: .regularExpression)
                .replacingOccurrences(of: "*", with: "x")
            let bases = ["~/": home, "/opt/homebrew/": homebrew, "/Users/Shared/": shared, "/Applications/": applications]
            for (prefix, base) in bases where literal.hasPrefix(prefix) {
                return base.appendingPathComponent(String(literal.dropFirst(prefix.count)))
            }
            return URL(fileURLWithPath: literal)
        }

        /// Writes a folder, or a small file when the path has no final `/` and looks like a file.
        func write(_ url: URL, folder: Bool) throws {
            if folder {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(repeating: 0x41, count: 64 * 1024).write(to: url)
            }
        }

        /// Writes an item from `identifiedBy` or `layout` inside a folder. A final `/` is a folder.
        func writeItem(_ item: String, in folder: URL) throws {
            let literal = item.replacingOccurrences(of: "*", with: "x")
            let isFolder = literal.hasSuffix("/") || !literal.split(separator: "/").last!.contains(".")
            try write(folder.appendingPathComponent(String(literal.trimmingCharacters(in: CharacterSet(charactersIn: "/")))),
                      folder: isFolder)
        }
    }

    // MARK: - Recognition

    private static func recognized(_ rule: Rule, on mac: Mac) -> Bool {
        switch rule.table {
        case "databaseStorage":
            return DatabaseStorage.locations(home: mac.home, homebrewPrefixes: [mac.homebrew])
                .contains { $0.url.standardizedFileURL == mac.url(rule.path).standardizedFileURL }
        case "toolHomeLocations":
            return ToolHomeFolders.existingLocations(home: mac.home, sharedFolder: mac.shared)
                .contains { $0.url.standardizedFileURL == mac.url(rule.path).standardizedFileURL }
        case "aiToolStorage":
            guard let root = AIToolStorage.roots.first(where: { ($0.base == .home ? "~/" : "/Applications/") + $0.path == rule.path })
            else { return false }
            return AIToolStorage.location(of: root, home: mac.home, applications: mac.applications) != nil
        case "applicationDataFolders":
            return ApplicationDataFolders.byBundleIdentifier.contains { identifier, folders in
                folders.contains { "~/" + $0.path == rule.path }
                    && ApplicationDataFolders.folders(for: identifier, home: mac.home)
                        .contains { $0.standardizedFileURL == mac.url(rule.path).standardizedFileURL }
            }
        default:
            return false
        }
    }

    private static let recognizedTables = ["databaseStorage", "toolHomeLocations", "aiToolStorage", "applicationDataFolders"]

    @Test("a rule recognizes a folder with its items, and refuses the folder without them",
          arguments: rules.filter { rule in
              recognizedTables.contains(rule.table) && rule.treatment == "protect" && !isPart(rule)
          })
    func recognition(rule: Rule) throws {
        let complete = try Mac()
        let folder = mac(complete, rule)
        try complete.write(folder, folder: true)
        for item in rule.identifiedBy + rule.layout {
            try complete.writeItem(item, in: folder)
        }
        #expect(Self.recognized(rule, on: complete), "\(rule) does not recognize its layout")

        guard !rule.identifiedBy.isEmpty else { return }
        let bare = try Mac()
        try bare.write(mac(bare, rule), folder: true)
        try bare.write(mac(bare, rule).appendingPathComponent("unrelated.txt"), folder: false)
        #expect(!Self.recognized(rule, on: bare), "\(rule) recognizes a folder without its items")
    }

    private func mac(_ mac: Mac, _ rule: Rule) -> URL { mac.url(rule.path) }

    /// An AI tool rule below another AI tool root is a part, which the root's recognition covers.
    private static func isPart(_ rule: Rule) -> Bool {
        rule.table == "aiToolStorage" && rules.contains { other in
            other.table == "aiToolStorage" && other.path != rule.path && rule.path.hasPrefix(other.path + "/")
        }
    }

    @Test("a home folder offers its caches only with its layout and their markers",
          arguments: rules(table: "toolHomeFolders", treatment: "protect").filter { folder in
              rules.contains { $0.table == "toolHomeFolders" && $0.treatment != "protect" && $0.path.hasPrefix(folder.path + "/") }
          })
    func homeFolderCaches(folder rule: Rule) throws {
        let name = String(rule.path.dropFirst(2))
        let folder = try #require(ToolHomeFolders.folder(named: name))
        let caches = Self.rules(table: "toolHomeFolders").filter { $0.treatment != "protect" && $0.path.hasPrefix(rule.path + "/") }

        let complete = try Mac()
        let url = complete.url(rule.path)
        try complete.write(url, folder: true)
        for item in rule.layout { try complete.writeItem(item, in: url) }
        for cache in caches {
            let cacheURL = complete.url(cache.path)
            try complete.write(cacheURL, folder: !cache.path.split(separator: "/").last!.contains("."))
            for marker in cache.identifiedBy { try complete.writeItem(marker, in: cacheURL) }
        }
        let offered = ToolHomeFolders.offeredCaches(of: folder, in: url).map { $0.url.standardizedFileURL }
        #expect(Set(offered) == Set(caches.map { complete.url($0.path).standardizedFileURL }), "\(rule) offers \(offered)")

        guard !rule.layout.isEmpty else { return }
        let bare = try Mac()
        let bareURL = bare.url(rule.path)
        try bare.write(bareURL, folder: true)
        for cache in caches { try bare.write(bare.url(cache.path), folder: !cache.path.split(separator: "/").last!.contains(".")) }
        #expect(ToolHomeFolders.offeredCaches(of: folder, in: bareURL).isEmpty, "\(rule) offers caches without its layout")
    }

    // MARK: - The fixtures

    static let fixtures: [(tool: String, paths: [String])] = {
        let folder = repository.appendingPathComponent("Core/Tests/MoppoCoreTests/Fixtures/Layouts")
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        return files.compactMap { file in
            guard file.hasSuffix(".txt"),
                  let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
            else { return nil }
            return (String(file.dropLast(4)), text.split(separator: "\n").map(String.init))
        }
    }()

    @Test("each rule of a tool recognizes the real layout of the tool", arguments: fixtures.map(\.tool))
    func fixture(tool: String) throws {
        let paths = try #require(Self.fixtures.first { $0.tool == tool }).paths
        let mac = try Mac()
        for path in paths {
            try mac.write(mac.url(path), folder: path.hasSuffix("/"))
        }
        let rules = Self.rules.filter { rule in
            let literal = rule.path.replacingOccurrences(of: "<[^>]+>", with: "x", options: .regularExpression)
            return rule.tool == tool && Self.recognizedTables.contains(rule.table) && rule.treatment == "protect"
                && !Self.isPart(rule) && paths.contains { path in path.hasPrefix(literal) }
        }
        for rule in rules {
            #expect(Self.recognized(rule, on: mac), "\(rule) does not recognize the layout from the manifest")
        }
    }
}
