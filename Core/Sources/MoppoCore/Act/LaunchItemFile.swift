import Darwin
import Foundation

/// A launch agent or launch daemon file, and the keys that identify its application.
///
/// Many applications give these files a name that is not their bundle identifier.
/// The rented Mac for #56 on 3 November 2026 had `com.carriez.RustDesk_server.plist`
/// for `com.carriez.rustdesk`, and `ai.perplexity.CometUpdater.wake.plist` for the
/// updater in `Comet.app`. Only two keys connect a file to an application:
///
/// - `AssociatedBundleIdentifiers`, a string or an array of strings.
/// - The program: `Program`, or the first `ProgramArguments` item.
///
/// A file name alone is not evidence. Moppo reads the file and does not run the program.
struct LaunchItemFile: Sendable, Equatable {
    let url: URL
    /// Valid bundle identifiers from `AssociatedBundleIdentifiers`.
    let associatedBundleIdentifiers: Set<String>
    /// The absolute program path. Nil when the file gives a relative path or no program.
    let program: URL?

    /// Larger files are not launchd job files.
    static let maximumFileSize = 1_048_576

    /// The launch files in the folders, without symbolic links.
    static func files(in directories: [URL]) -> [LaunchItemFile] {
        directories.flatMap { directory in
            AppUninstallPlanner.directoryNames(directory)
                .filter { $0.hasSuffix(".plist") }
                .sorted()
                .compactMap { read(directory.appendingPathComponent($0)) }
        }
    }

    /// Reads one file. Returns nil when it is a symbolic link, too large, or not a dictionary.
    static func read(_ url: URL) -> LaunchItemFile? {
        var information = stat()
        guard lstat(url.path, &information) == 0,
              (information.st_mode & S_IFMT) == S_IFREG,
              information.st_size <= maximumFileSize,
              let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any]
        else { return nil }

        let rawIdentifiers: [String] = switch plist["AssociatedBundleIdentifiers"] {
        case let value as String: [value]
        case let values as [Any]: values.compactMap { $0 as? String }
        default: []
        }
        let rawProgram = (plist["Program"] as? String)
            ?? ((plist["ProgramArguments"] as? [Any])?.first as? String)
        let program = rawProgram.flatMap { path in
            path.hasPrefix("/") ? URL(fileURLWithPath: path).standardizedFileURL : nil
        }
        return LaunchItemFile(
            url: url.standardizedFileURL,
            associatedBundleIdentifiers: Set(rawIdentifiers.compactMap(AppUninstallPlanner.verifiedBundleIdentifier)),
            program: program
        )
    }

    /// The installed application that contains the program, if the program exists.
    ///
    /// A program in an application bundle belongs to that application,
    /// whatever `AssociatedBundleIdentifiers` says.
    func installedApplication(in roots: [URL]) -> URL? {
        guard let program, AppUninstallPlanner.isInside(program, oneOf: roots),
              FileManager.default.fileExists(atPath: program.path)
        else { return nil }
        var url = program
        var outermost: URL?
        while AppUninstallPlanner.isInside(url, oneOf: roots) {
            if url.pathExtension.lowercased() == "app" { outermost = url }
            url = url.deletingLastPathComponent()
        }
        return outermost
    }
}
