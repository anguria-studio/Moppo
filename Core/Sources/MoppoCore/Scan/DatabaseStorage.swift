import Foundation

/// Database data folders from the Databases section of docs/tool-catalog.md.
/// The `roots` table is in `Generated/ToolRules.swift`. Change a rule in `rules/<tool>.json`.
///
/// Database files are user data. Moppo shows these folders with their sizes and
/// never offers them, or a file in them, for removal. This includes MySQL binary
/// logs and the data folder of an older PostgreSQL version.
///
/// A folder is protected only when its database files identify it. A folder name
/// alone is not evidence: an empty `var/mysql` gets no rule.
enum DatabaseStorage {
    struct Root: Sendable {
        /// The folder that holds `path`.
        enum Base: Sendable { case homebrew, home }

        /// A path below the base. A glob component matches any child.
        let path: String
        let name: String
        var base: Base = .homebrew
        /// Paths in the folder that identify the database. One path is sufficient.
        /// A glob component matches any child. A final `/` requires a folder.
        let identifiedBy: [String]
        /// The tool that manages the data.
        let tool: String
        /// What the folder holds, for the row explanation.
        var contents: String? = nil
        /// Only an application row shows this folder. Hidden & System Data does not measure it.
        /// Hidden & System Data lists the other folders. When an application row also lists
        /// one, such as `~/Library/DBeaverData`, the scan keeps only the application row.
        var listedWithApplication = false
    }

    struct Location: Sendable {
        let root: Root
        let url: URL

        /// The folder name follows the rule name when the rule path ends in a glob.
        var displayName: String {
            let last = root.path.split(separator: "/").last.map(String.init) ?? ""
            guard last.contains(where: { "*?[".contains($0) }) else { return root.name }
            return "\(root.name) (\(url.lastPathComponent))"
        }

        var explanation: String {
            "This folder contains \(root.contents ?? root.tool + " database files"). Moppo never removes database data. Use \(root.tool) to manage this data."
        }
    }

    /// Apple silicon and Intel Homebrew prefixes.
    static let homebrewPrefixes = [
        URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
        URL(fileURLWithPath: "/usr/local", isDirectory: true)
    ]

    /// The recognized database folders that exist.
    static func locations(home: URL, homebrewPrefixes: [URL] = []) -> [Location] {
        roots.flatMap { root -> [Location] in
            let bases = root.base == .home ? [home] : homebrewPrefixes
            return bases.flatMap { ApplicationsScanner.expand(root.path, under: $0) }
                .filter { isIdentified($0, by: root.identifiedBy) }
                .map { Location(root: root, url: $0.standardizedFileURL) }
        }
    }

    /// The first database folder at `url`, inside it, or around it.
    static func location(overlapping url: URL, in locations: [Location]) -> Location? {
        let path = url.standardizedFileURL.path
        return locations.first { ApplicationsScanner.overlaps(path, $0.url.path) }
    }

    private static func isIdentified(_ folder: URL, by markers: [String]) -> Bool {
        guard isDirectory(folder) else { return false }
        return markers.contains { marker in
            let requiresFolder = marker.hasSuffix("/")
            return ApplicationsScanner.expand(marker, under: folder).contains { url in
                requiresFolder ? isDirectory(url) : FileManager.default.fileExists(atPath: url.path)
            }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && directory.boolValue
    }
}
