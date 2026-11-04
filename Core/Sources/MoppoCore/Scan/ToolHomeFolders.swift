import Foundation

/// Home dot folders that hold installed toolchains, virtual machines, or credentials.
/// A name with `.config/` is a folder in `~/.config`, which Hidden System Data lists child by child.
///
/// Hidden System Data lists large home dot folders, and a listed folder could move to
/// the Trash as one item. For these folders, that removed Rust toolchains, container
/// volumes, and registry tokens (#321). Hidden System Data now shows each of these
/// folders with its size and locks it.
///
/// The `all` and `locations` tables are in `Generated/ToolRules.swift`. Change a rule in
/// `rules/<tool>.json`.
///
/// Only caches that `docs/tool-catalog.md` verified for a Trash move become separate
/// rows. Moppo offers such a cache only when the tool layout is present, because a
/// folder name alone does not identify the tool.
enum ToolHomeFolders {
    struct Folder: Sendable {
        let name: String
        let explanation: String
        /// Items in the folder that identify the tool layout. Each one must exist before Moppo offers a cache.
        var layout: [String] = []
        var caches: [Cache] = []
    }

    struct Cache: Sendable {
        let path: String
        /// An item in the cache that identifies its layout. A glob component matches any child.
        var marker: String?
        /// True when the tool makes the cache again without a network connection.
        let isRegenerable: Bool
        let caveat: String?

        static func cache(_ path: String) -> Self {
            Cache(path: path, isRegenerable: true, caveat: nil)
        }

        static func download(_ path: String, marker: String? = nil, caveat: String) -> Self {
            Cache(path: path, marker: marker, isRegenerable: false, caveat: caveat)
        }
    }

    static let names: Set<String> = Set(all.map(\.name))

    static func folder(named name: String) -> Folder? {
        all.first { $0.name == name }
    }

    // MARK: - Tool storage outside the listed folders

    /// Tool storage that no other row shows, such as folders in `~/.local` (#323).
    /// Hidden System Data shows each location with its size and locks it, as it does for the folders above.
    struct Location: Sendable {
        /// The folder that holds `path`.
        enum Base: Sendable { case home, sharedFolder }

        let path: String
        /// The row name. It names the tool that owns the storage.
        let name: String
        var base: Base = .home
        /// Items in the location that identify the tool. One item is sufficient. A glob component matches any child.
        let identifiedBy: [String]
        let explanation: String
        var layout: [String] = []
        var caches: [Cache] = []

        var folder: Folder { Folder(name: path, explanation: explanation, layout: layout, caches: caches) }
    }

    /// `/Users/Shared`, where DBngin keeps its server versions.
    static let sharedFolder = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)

    /// The locations that exist and that their layout identifies. A location with a link in its path is not used.
    static func existingLocations(home: URL, sharedFolder: URL?) -> [(location: Location, url: URL)] {
        locations.compactMap { location in
            guard let base = location.base == .home ? home : sharedFolder else { return nil }
            let url = base.appendingPathComponent(location.path)
            guard isOwned(url, under: base), (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  location.identifiedBy.contains(where: { ApplicationsScanner.expand($0, under: url).contains(where: exists) })
            else { return nil }
            return (location, url)
        }
    }

    /// The caches that Moppo can offer in `url`. A link is never a cache.
    static func offeredCaches(of folder: Folder, in url: URL) -> [(url: URL, cache: Cache)] {
        guard folder.layout.allSatisfy({ exists(url.appendingPathComponent($0)) }) else { return [] }
        return folder.caches.compactMap { cache in
            let cacheURL = url.appendingPathComponent(cache.path)
            guard isOwned(cacheURL, under: url),
                  cache.marker.map({ ApplicationsScanner.expand($0, under: cacheURL).contains(where: exists) }) ?? true
            else { return nil }
            return (cacheURL, cache)
        }
    }

    /// Does not follow a link, so a link with no target still counts.
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    /// The item and each folder between it and `root` exist and are not links.
    private static func isOwned(_ url: URL, under root: URL) -> Bool {
        var current = url
        while current.path.count > root.path.count {
            guard let type = (try? FileManager.default.attributesOfItem(atPath: current.path))?[.type] as? FileAttributeType,
                  type != .typeSymbolicLink else { return false }
            current.deleteLastPathComponent()
        }
        return true
    }
}
