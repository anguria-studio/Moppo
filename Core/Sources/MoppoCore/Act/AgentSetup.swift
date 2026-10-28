import Foundation

/// Installs the command-line tool and the agent skill that ship inside Moppo.app.
/// The tool is a symbolic link, so app updates also update the command.
/// Replaced skill folders move to Trash.
public struct AgentSetup: Sendable {
    public enum Client: String, CaseIterable, Identifiable, Sendable {
        case claudeCode, codex, cursor

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .claudeCode: "Claude Code"
            case .codex: "Codex"
            case .cursor: "Cursor"
            }
        }

        /// The personal skill folder that each client reads, relative to the home folder.
        var skillsPath: String {
            switch self {
            case .claudeCode: ".claude/skills"
            case .codex: ".agents/skills"
            case .cursor: ".cursor/skills"
            }
        }
    }

    public enum State: Equatable, Sendable {
        /// Nothing uses the name.
        case notInstalled
        /// The installed item matches this copy of Moppo.
        case installed
        /// Another version uses the name. Replacement needs the user's confirmation.
        case different
        /// A file that Moppo did not create uses the name. Moppo does not replace it.
        case blocked
    }

    public enum SetupError: Error, Equatable, Sendable { case sourceMissing, blocked, confirmationRequired }

    public static let skillName = "moppo-cleanup"
    public static let pathLine = #"export PATH="$HOME/.local/bin:$PATH""#

    let home: URL
    let toolSource: URL
    let skillSource: URL
    private let moveToTrash: @Sendable (URL) throws -> Void

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, toolSource: URL, skillSource: URL,
                moveToTrash: @escaping @Sendable (URL) throws -> Void = {
                    try FileManager.default.trashItem(at: $0, resultingItemURL: nil)
                }) {
        self.home = home
        self.toolSource = toolSource
        self.skillSource = skillSource
        self.moveToTrash = moveToTrash
    }

    /// The sources inside an app bundle.
    public init(appBundle: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(home: home, toolSource: appBundle.appendingPathComponent("Contents/Helpers/moppo"),
                  skillSource: appBundle.appendingPathComponent("Contents/Resources/skills/" + Self.skillName))
    }

    public var toolLink: URL { home.appendingPathComponent(".local/bin/moppo") }

    public func skillFolder(for client: Client) -> URL {
        home.appendingPathComponent(client.skillsPath).appendingPathComponent(Self.skillName)
    }

    // MARK: Command-line tool

    public var toolState: State {
        let fileManager = FileManager.default
        guard let destination = try? fileManager.destinationOfSymbolicLink(atPath: toolLink.path) else {
            var info = stat()
            return lstat(toolLink.path, &info) == 0 ? .blocked : .notInstalled
        }
        let resolved = URL(fileURLWithPath: destination, relativeTo: toolLink.deletingLastPathComponent())
        return resolved.standardizedFileURL.path == toolSource.standardizedFileURL.path ? .installed : .different
    }

    /// Creates the link. `replace` must be true to change a link to another Moppo copy.
    public func installTool(replace: Bool = false) throws {
        guard FileManager.default.isExecutableFile(atPath: toolSource.path) else { throw SetupError.sourceMissing }
        switch toolState {
        case .installed: return
        case .blocked: throw SetupError.blocked
        case .different:
            guard replace else { throw SetupError.confirmationRequired }
            try FileManager.default.removeItem(at: toolLink)
        case .notInstalled: break
        }
        try FileManager.default.createDirectory(at: toolLink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: toolLink, withDestinationURL: toolSource)
    }

    /// Removes only a symbolic link. Moppo never removes a file that it did not create.
    public func removeTool() throws {
        guard toolState == .installed || toolState == .different else { return }
        try FileManager.default.removeItem(at: toolLink)
    }

    // MARK: Agent skill

    public func skillState(for client: Client) -> State {
        let folder = skillFolder(for: client)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else { return .notInstalled }
        guard isDirectory.boolValue else { return .blocked }
        let installed = try? Data(contentsOf: folder.appendingPathComponent("SKILL.md"))
        let source = try? Data(contentsOf: skillSource.appendingPathComponent("SKILL.md"))
        return installed != nil && installed == source ? .installed : .different
    }

    /// Copies the bundled skill. `replace` must be true to move a different version to Trash first.
    public func installSkill(for client: Client, replace: Bool = false) throws {
        guard FileManager.default.fileExists(atPath: skillSource.appendingPathComponent("SKILL.md").path) else {
            throw SetupError.sourceMissing
        }
        let folder = skillFolder(for: client)
        switch skillState(for: client) {
        case .installed: return
        case .blocked: throw SetupError.blocked
        case .different:
            guard replace else { throw SetupError.confirmationRequired }
            try moveToTrash(folder)
        case .notInstalled: break
        }
        try FileManager.default.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: skillSource, to: folder)
    }

    /// Moves the installed skill folder to Trash.
    public func removeSkill(for client: Client) throws {
        guard skillState(for: client) == .installed || skillState(for: client) == .different else { return }
        try moveToTrash(skillFolder(for: client))
    }
}
