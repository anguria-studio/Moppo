import Foundation

/// Application data folders that use a name other than the application name or bundle identifier.
///
/// Each folder is user data. The Applications scan shows it with its application,
/// App Uninstaller lists it for review, and Application Leftovers lists it after the
/// application is removed. A folder name alone is not evidence. Each entry comes from
/// an installed application with this bundle identifier, as the rule notes record.
/// The `byBundleIdentifier` table is in `Generated/ToolRules.swift`. Change a rule in `rules/<tool>.json`.
enum ApplicationDataFolders {
    struct Folder: Sendable {
        /// The folder, relative to the home folder.
        let path: String
        /// Paths in the folder that must exist before Moppo connects it.
        /// Use them when the folder name is not specific to the application.
        var identifiedBy: [String] = []
    }


    /// The folders of one application that exist and match their layout.
    static func folders(for bundleIdentifier: String, home: URL) -> [URL] {
        (byBundleIdentifier[bundleIdentifier] ?? []).compactMap { location(of: $0, home: home) }
    }

    /// The bundle identifiers that have at least one folder on this Mac.
    static func identifiersWithFolders(home: URL) -> Set<String> {
        Set(byBundleIdentifier.keys.filter { !folders(for: $0, home: home).isEmpty })
    }

    /// Folders outside the library folders that the planners can remove.
    /// Removal accepts each one only as the complete folder or a path in it.
    static func foldersOutsideLibrary(home: URL) -> [URL] {
        byBundleIdentifier.values.joined()
            .filter { !$0.path.hasPrefix("Library/") }
            .map { home.appendingPathComponent($0.path, isDirectory: true).standardizedFileURL }
    }

    private static func location(of folder: Folder, home: URL) -> URL? {
        let url = home.appendingPathComponent(folder.path, isDirectory: true).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              folder.identifiedBy.allSatisfy({
                  FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
              })
        else { return nil }
        return url
    }
}
