import Foundation

/// A model store folder at its default path, or at a path that a variable sets.
public struct ModelStoreFolder: Sendable, Equatable {
    public let url: URL
    /// The variable that set the folder. Nil for the default path.
    public let variable: String?
    /// True when the folder is outside the home folder. Moppo shows its models but does not remove them.
    public let isOutsideHome: Bool
    /// No path component below this folder can be a link. The home folder for a folder inside it, or the store folder.
    let base: URL
}

extension LocalModelStores {
    /// A store that a variable can move. The generated `customLocations` table lists them.
    struct CustomLocation: Sendable {
        struct Variable: Sendable {
            let name: String
            var append: String? = nil
        }

        let tool: String
        let store: String
        /// The default path below the home folder.
        let defaultPath: String
        /// The first variable with a value sets the folder. Later variables are not read.
        let variables: [Variable]
        /// Paths in the folder that identify the store. One of them must exist. A glob component matches any child.
        let identifiedBy: [String]
        /// The tool expands `~` at the start of the value.
        var expandsHome = false
        /// The tool removes spaces and quotes around the value, as Ollama does.
        var trimsQuotes = false
    }

    /// System folders that never hold a model store, with the folders below them.
    static let systemFolders = ["/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/dev", "/cores"]
    /// Folders that hold other folders of many owners. A store can be below them, but not at them.
    static let sharedParents = ["/", "/Volumes", "/Users", "/private", "/opt"]
    /// Home folders that hold data of many owners. A store can be below them, but cannot be or contain them.
    static let homeParents = [
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures", "Public", "Applications",
        "Library", "Library/Caches", "Library/Application Support", "Library/Containers",
        "Library/Group Containers", "Library/Mobile Documents",
        ".cache", ".config", ".local", ".local/share", ".local/state"
    ]

    /// The variables that the custom locations read: from the process, then from `launchctl getenv`.
    /// An app started from the Dock does not see variables that only a shell profile sets.
    public static func environment(
        process: [String: String] = ProcessInfo.processInfo.environment,
        launchd: (String) async -> String?
    ) async -> [String: String] {
        var values: [String: String] = [:]
        for name in locationVariables {
            if let value = process[name] {
                values[name] = value
            } else if let value = await launchd(name), !value.isEmpty {
                values[name] = value
            }
        }
        return values
    }
}

/// The model store folders of one scan. Moppo reads the default folders and the folders that variables set.
struct ModelStoreFolders: Sendable {
    /// The accepted custom folders, by store name.
    private(set) var custom: [String: [ModelStoreFolder]] = [:]
    let home: URL

    init(home: URL, environment: [String: String], systemFolders: [String] = LocalModelStores.systemFolders) {
        self.home = home
        guard !environment.isEmpty else { return }
        let foreign = AIToolStorage.claimedPaths(home: home)
        var found: [(location: LocalModelStores.CustomLocation, folder: ModelStoreFolder)] = []
        for location in LocalModelStores.customLocations {
            guard let folder = Self.folder(for: location, home: home, environment: environment,
                                           foreignClaims: foreign, systemFolders: systemFolders) else { continue }
            found.append((location, folder))
        }
        // Two tools cannot claim the same bytes. Folders of different tools that overlap are not read.
        for (location, folder) in found where !found.contains(where: {
            $0.location.tool != location.tool && ApplicationsScanner.overlaps($0.folder.url.path, folder.url.path)
        }) {
            if !(custom[location.store] ?? []).contains(folder) { custom[location.store, default: []].append(folder) }
        }
    }

    /// The default folders of a store, then its custom folders.
    func folders(_ store: String, defaults: [String]) -> [ModelStoreFolder] {
        defaults.map {
            ModelStoreFolder(url: home.appendingPathComponent($0, isDirectory: true), variable: nil,
                             isOutsideHome: false, base: home)
        } + (custom[store] ?? [])
    }

    /// Every custom folder. AI Tools claims them, so other categories do not list them again.
    var claimedPaths: [String] { custom.values.flatMap { $0.map(\.url.path) } }

    /// The folder that the first variable with a value sets, when the folder passes every check.
    static func folder(
        for location: LocalModelStores.CustomLocation, home: URL, environment: [String: String],
        foreignClaims: [String], systemFolders: [String]
    ) -> ModelStoreFolder? {
        let set = location.variables.lazy.compactMap { variable -> (LocalModelStores.CustomLocation.Variable, String)? in
            guard var value = environment[variable.name] else { return nil }
            if location.trimsQuotes {
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
            return value.isEmpty ? nil : (variable, value)
        }.first
        guard let (variable, raw) = set else { return nil }

        let homePath = normalized(home.path)
        var value = raw
        if location.expandsHome, value == "~" || value.hasPrefix("~/") { value = homePath + value.dropFirst() }
        // A relative value depends on the folder that the tool starts in, so Moppo cannot know the store.
        guard value.hasPrefix("/") else { return nil }
        let path = normalized(value + "/" + (variable.append ?? ""))
        let url = URL(fileURLWithPath: path, isDirectory: true)

        // The default folder is already read.
        if path == normalized(homePath + "/" + location.defaultPath) { return nil }
        let isInsideHome = path.hasPrefix(homePath + "/")
        guard isAcceptable(path, homePath: homePath, isInsideHome: isInsideHome, systemFolders: systemFolders) else {
            return nil
        }
        // A folder that another tool claims, or that contains one, would count its bytes twice.
        let own = (LocalModelStores.storePathsByTool[location.tool] ?? []).map { homePath + "/" + $0 }
        let others = LocalModelStores.storePathsByTool.filter { $0.key != location.tool }
            .flatMap { $0.value.map { homePath + "/" + $0 } }
        let claims = foreignClaims.map(normalized).filter { claim in !own.contains { ApplicationsScanner.overlaps(claim, $0) } } + others
        guard !claims.contains(where: { ApplicationsScanner.overlaps($0, path) }) else { return nil }

        guard hasNoLinks(path, below: isInsideHome ? homePath : "/"), isDirectory(url) else { return nil }
        // A variable alone is not evidence. The folder must hold items from the tool's layout.
        guard location.identifiedBy.contains(where: { marker in
            ApplicationsScanner.expand(marker, under: url).contains { FileManager.default.fileExists(atPath: $0.path) }
        }) else { return nil }
        return ModelStoreFolder(url: url, variable: variable.name, isOutsideHome: !isInsideHome,
                                base: isInsideHome ? home : url)
    }

    private static func isAcceptable(_ path: String, homePath: String, isInsideHome: Bool, systemFolders: [String]) -> Bool {
        if path == homePath || homePath.hasPrefix(path + "/") { return false }
        if LocalModelStores.sharedParents.contains(path) { return false }
        if systemFolders.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return false }
        guard isInsideHome else { return true }
        return !LocalModelStores.homeParents.contains { parent in
            let parentPath = homePath + "/" + parent
            return parentPath == path || parentPath.hasPrefix(path + "/")
        }
    }

    /// The absolute path without `.`, `..`, and empty components.
    /// `standardizedFileURL` also removes `/private` from paths such as `/private/tmp`, so it is not used here.
    static func normalized(_ path: String) -> String {
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": _ = components.popLast()
            default: components.append(component)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    /// True when no component of `path` below `root` is a symbolic link.
    static func hasNoLinks(_ path: String, below root: String) -> Bool {
        let relative: Substring
        if root == "/" { relative = path.dropFirst() }
        else if path.hasPrefix(root + "/") { relative = path.dropFirst(root.count + 1) }
        else { return false }
        var current = URL(fileURLWithPath: root, isDirectory: true)
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return false }
        }
        return true
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
