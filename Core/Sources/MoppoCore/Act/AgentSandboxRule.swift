import Darwin
import Foundation

/// Agent clients can run commands in a sandbox that blocks Moppo's records, Trash, and cleanup targets.
/// Skill setup also adds a client rule that lets `moppo` run outside that sandbox.
/// Cursor keeps its command allowlist in its own settings, so it has no rule file.
extension AgentSetup {
    /// Claude Code merges this list with the sandbox settings of each project.
    public static let claudeExcludedCommand = "moppo *"

    static let codexRulesMarker = "# Moppo Settings > Advanced manages this file."
    static let codexRules = """
    \(codexRulesMarker)
    # Moppo saves private records in ~/Library/Application Support/Moppo and moves approved items to Trash.
    prefix_rule(
        pattern = ["moppo"],
        decision = "allow",
        justification = "Moppo saves its records and moves approved items to Trash outside the sandbox.",
    )
    prefix_rule(
        pattern = ["moppo", "plan", "remove"],
        decision = "prompt",
        justification = "Removal changes files. Approve only the plan that you reviewed.",
    )

    """

    public func sandboxRuleFile(for client: Client) -> URL? {
        switch client {
        case .claudeCode: home.appendingPathComponent(".claude/settings.json")
        case .codex: home.appendingPathComponent(".codex/rules/moppo.rules")
        case .cursor: nil
        }
    }

    /// Nil when the client has no rule file. `.blocked` means that Moppo cannot change the file safely.
    public func sandboxRuleState(for client: Client) -> State? {
        guard let file = sandboxRuleFile(for: client) else { return nil }
        guard let isLink = Self.isSymbolicLink(file) else { return .notInstalled }
        switch client {
        case .claudeCode:
            guard let settings = try? ClaudeSettings(contentsOf: file) else { return .blocked }
            if settings.excludedCommands.contains(Self.claudeExcludedCommand) { return .installed }
            // An atomic write would replace a linked settings file with a copy.
            return isLink ? .blocked : .notInstalled
        case .codex, .cursor:
            guard !isLink, let text = try? String(contentsOf: file, encoding: .utf8) else { return .blocked }
            if text == Self.codexRules { return .installed }
            return text.hasPrefix(Self.codexRulesMarker) ? .different : .blocked
        }
    }

    /// Adds the rule. An earlier Moppo version of the Codex rule moves to Trash.
    public func installSandboxRule(for client: Client) throws {
        guard let file = sandboxRuleFile(for: client) else { return }
        switch sandboxRuleState(for: client) {
        case .installed, nil: return
        case .blocked: throw SetupError.sandboxRuleBlocked(client)
        case .different: try moveToTrash(file)
        case .notInstalled: break
        }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if client == .claudeCode {
            var settings = try ClaudeSettings(contentsOf: file)
            settings.excludedCommands.append(Self.claudeExcludedCommand)
            try settings.write(to: file)
        } else {
            try Data(Self.codexRules.utf8).write(to: file, options: .atomic)
        }
    }

    /// Removes only the rule that Moppo added. Other settings stay.
    public func removeSandboxRule(for client: Client) throws {
        guard let file = sandboxRuleFile(for: client) else { return }
        switch sandboxRuleState(for: client) {
        case .installed, .different: break
        case .blocked, .notInstalled, nil: return
        }
        if client == .claudeCode {
            guard Self.isSymbolicLink(file) == false else { throw SetupError.sandboxRuleBlocked(client) }
            var settings = try ClaudeSettings(contentsOf: file)
            settings.excludedCommands.removeAll { $0 == Self.claudeExcludedCommand }
            try settings.write(to: file)
        } else {
            try moveToTrash(file)
        }
    }

    /// Nil when nothing uses the path. A link can point to a missing file.
    private static func isSymbolicLink(_ file: URL) -> Bool? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT == S_IFLNK
    }
}

/// The Claude Code user settings file. Moppo changes only `sandbox.excludedCommands` and keeps every other value.
private struct ClaudeSettings {
    private var object: [String: Any]

    /// A missing file is empty. A file that is not a JSON object, or has unexpected sandbox types, is an error.
    init(contentsOf file: URL) throws {
        guard FileManager.default.fileExists(atPath: file.path) else { object = [:]; return }
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let sandbox = object["sandbox"] {
            guard let sandbox = sandbox as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            if let list = sandbox["excludedCommands"], !(list is [String]) { throw CocoaError(.fileReadCorruptFile) }
        }
        self.object = object
    }

    var excludedCommands: [String] {
        get { (object["sandbox"] as? [String: Any])?["excludedCommands"] as? [String] ?? [] }
        set {
            var sandbox = object["sandbox"] as? [String: Any] ?? [:]
            sandbox["excludedCommands"] = newValue.isEmpty ? nil : newValue
            object["sandbox"] = sandbox.isEmpty ? nil : sandbox
        }
    }

    func write(to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }
}
