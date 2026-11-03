import Foundation

/// Application data folders that use a name other than the application name or bundle identifier.
///
/// Each folder is user data. The Applications scan shows it with its application,
/// App Uninstaller lists it for review, and Application Leftovers lists it after the
/// application is removed. A folder name alone is not evidence. Each entry comes from
/// an installed application with this bundle identifier, as the comments record.
enum ApplicationDataFolders {
    struct Folder: Sendable {
        /// The folder, relative to the home folder.
        let path: String
        /// Paths in the folder that must exist before Moppo connects it.
        /// Use them when the folder name is not specific to the application.
        var identifiedBy: [String] = []
    }

    /// Folders by bundle identifier.
    ///
    /// The #216 tests on 3 November 2026 found each folder on a rented Mac
    /// (macOS 27.2) after the first start of the signed application.
    static let byBundleIdentifier: [String: [Folder]] = [
        // AnythingLLM 1.19.0, team 35S2NMU3G4. The Electron package name is `anythingllm-desktop`.
        "com.anythingllm": [Folder(path: "Library/Application Support/anythingllm-desktop")],
        // Cherry Studio 2.1.10, team 87242QY66T. The Electron package name is `CherryStudio`.
        // `~/.cherrystudio` holds the downloaded tools and the `config` folder of the application.
        "com.kangfenmao.CherryStudio": [
            Folder(path: "Library/Application Support/CherryStudio"),
            Folder(path: ".cherrystudio")
        ],
        // Stability Matrix 2.16.5, team 78LBV9V26G. The folder holds `global.json` and the logs.
        "ai.lykos.stabilitymatrix": [Folder(path: "Library/Application Support/StabilityMatrix")],
        // VoiceInk 2.21, team V6J6A3VWY2. VoiceInk also uses its bundle identifier folder.
        "com.prakashjoshipax.VoiceInk": [Folder(path: "Library/Application Support/VoiceInk")],
        // T3 Code 0.1.6, team ARK85ZXQ4Z. The application sets this folder. Its package name is `t3code`.
        // `~/.t3` is not here: the T3 Code command-line server also uses it.
        "com.t3tools.t3code": [Folder(path: "Library/Application Support/t3code-v2")],
        // DBeaver, team 42B6MDKMW8. The folder holds the workspace, drivers, and settings.
        "org.jkiss.dbeaver.core.product": [Folder(path: "Library/DBeaverData")],
        // Superwhisper 3.1.0, team XDP69BYUP9. `~/superwhisper` holds settings, modes, and recordings.
        "com.superduper.superwhisper": [
            Folder(path: "Library/Application Support/superwhisper"),
            Folder(path: "superwhisper", identifiedBy: ["settings/settings.json", "modes"])
        ]
    ]

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
