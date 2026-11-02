import Foundation

/// A `vendor` folder that a package tool can install again.
///
/// The name alone does not identify the folder. Composer, Bundler, and Go write
/// `vendor`, but a project can also keep committed or patched code there. That code
/// can be the only copy. Thus Moppo offers the folder only when all of these are true:
///
/// - The folder holds the evidence of exactly one tool.
/// - The lockfile of that tool is next to the folder.
/// - The folder is not a Git repository of its own.
/// - Git tracks no file in the folder. See `GitTrackedFiles`.
///
/// Bundler writes only `vendor/bundle`. Other items in a Bundler `vendor` folder,
/// such as `vendor/javascript` in a Rails app, do not come back with
/// `bundle install`. So a Bundler `vendor` folder must hold only `bundle`.
///
/// In a Go workspace, `go work vendor` writes the folder, and `go mod vendor` fails.
/// So a Go `vendor` folder must not have `go.work` next to it.
///
/// A folder that fails a check stays in its project row. Moppo does not count a
/// vendor folder as safe to remove, and checks it again immediately before removal.
public struct VendorFolder: Sendable, Equatable {

    public enum Tool: String, Sendable, Equatable, CaseIterable {
        case composer, bundler, go

        public var name: String {
            switch self {
            case .composer: "Composer"
            case .bundler: "Bundler"
            case .go: "Go"
            }
        }

        /// The row label, in the style of `npm dependencies`.
        public var label: String { "\(name) dependencies" }

        /// The path in `vendor` that only this tool writes.
        var evidence: String {
            switch self {
            case .composer: "composer/installed.json"
            case .bundler: "bundle"
            case .go: "modules.txt"
            }
        }

        /// The files next to `vendor` that record the installed versions.
        public var lockfiles: [String] {
            switch self {
            case .composer: ["composer.lock"]
            case .bundler: ["Gemfile.lock"]
            case .go: ["go.mod", "go.sum"]
            }
        }

        public var restoreCommand: String {
            switch self {
            case .composer: "composer install"
            case .bundler: "bundle install"
            case .go: "go mod vendor"
            }
        }
    }

    public let url: URL
    public let tool: Tool

    init(url: URL, tool: Tool) {
        self.url = url.standardizedFileURL
        self.tool = tool
    }

    /// `composer.lock`, or `go.mod and go.sum`.
    public var lockfileDescription: String { tool.lockfiles.joined(separator: " and ") }

    /// The short text after the row path, in the style of `no lockfile`.
    public var caveat: String { "restore with \(tool.restoreCommand)" }

    /// The row help text and the command line detail.
    public var explanation: String {
        "\(tool.name) can install these dependencies again from \(lockfileDescription). "
            + "To restore them, run \(tool.restoreCommand) in the project folder. "
            + "Moppo does not select vendor folders automatically. Review this folder before removal."
    }

    /// The file checks for `url`. Nil when one check fails. This method does not run Git.
    public static func evidence(at url: URL) -> VendorFolder? {
        let url = url.standardizedFileURL
        guard url.lastPathComponent == "vendor", isDirectory(url),
              let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              // A repository of its own is not tool output.
              !contents.contains(".git")
        else { return nil }
        let matches = Tool.allCases.filter { tool in
            let evidence = url.appendingPathComponent(tool.evidence)
            return tool == .bundler ? isDirectory(evidence) : isFile(evidence)
        }
        guard matches.count == 1, let tool = matches.first else { return nil }
        let project = url.deletingLastPathComponent()
        guard tool.lockfiles.allSatisfy({ isFile(project.appendingPathComponent($0)) }) else { return nil }
        if tool == .bundler, contents.contains(where: { $0 != "bundle" && $0 != ".DS_Store" }) { return nil }
        if tool == .go, FileManager.default.fileExists(atPath: project.appendingPathComponent("go.work").path) { return nil }
        return VendorFolder(url: url, tool: tool)
    }

    /// Checks the evidence, the lockfile, and Git again. Run this check immediately before removal.
    public func isStillRemovable(git: GitTrackedFilesReader = GitTrackedFilesReader()) async throws -> Bool {
        guard Self.evidence(at: url) == self else { return false }
        return try await git.state(of: url) == .untracked
    }

    /// A real folder, not a symbolic link.
    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    /// A file, or a symbolic link to a file.
    private static func isFile(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
