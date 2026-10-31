import Darwin
import Foundation

/// Agent clients can run commands in a sandbox that blocks Moppo's records, Trash, and cleanup targets.
/// Skill setup also adds a client rule that lets `moppo` run outside that sandbox.
/// The Cursor app keeps its command allowlist in its own settings. Moppo changes only the Cursor CLI file.
extension AgentSetup {
    /// Claude Code merges this list with the sandbox settings of each project.
    public static let claudeExcludedCommand = "moppo *"
    /// The Cursor CLI runs allowlisted commands outside its sandbox.
    public static let cursorAllowedCommand = "Shell(moppo)"

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
        case .cursor: home.appendingPathComponent(".cursor/cli-config.json")
        }
    }

    /// Nil when the client has no rule file, or when the Cursor CLI is not installed.
    /// `.blocked` means that Moppo cannot change the file safely.
    public func sandboxRuleState(for client: Client) -> State? {
        guard let file = sandboxRuleFile(for: client) else { return nil }
        guard let isLink = Self.isSymbolicLink(file) else { return client == .cursor ? nil : .notInstalled }
        switch client {
        case .claudeCode, .cursor:
            let entry = Self.listEntry(for: client)
            guard let settings = try? JSONSettingsList(contentsOf: file, client: client) else { return .blocked }
            if settings.values.contains(entry) { return .installed }
            // An atomic write would replace a linked settings file with a copy.
            return isLink ? .blocked : .notInstalled
        case .codex:
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
        if client != .codex {
            var settings = try JSONSettingsList(contentsOf: file, client: client)
            settings.values.append(Self.listEntry(for: client))
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
        if client != .codex {
            guard Self.isSymbolicLink(file) == false else { throw SetupError.sandboxRuleBlocked(client) }
            var settings = try JSONSettingsList(contentsOf: file, client: client)
            settings.values.removeAll { $0 == Self.listEntry(for: client) }
            try settings.write(to: file)
        } else {
            try moveToTrash(file)
        }
    }

    private static func listEntry(for client: Client) -> String {
        client == .cursor ? cursorAllowedCommand : claudeExcludedCommand
    }

    /// Nil when nothing uses the path. A link can point to a missing file.
    private static func isSymbolicLink(_ file: URL) -> Bool? {
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return nil }
        return info.st_mode & S_IFMT == S_IFLNK
    }
}

/// One string list in a client's JSON settings file. Moppo changes only that list and keeps every other value.
/// Claude Code: `sandbox.excludedCommands`. Cursor CLI: `permissions.allow`.
private struct JSONSettingsList {
    private var object: [String: Any]
    private let section: String
    private let key: String
    /// Claude Code settings drop empty keys. The Cursor CLI writes `permissions.allow` itself, so it stays.
    private let keepsEmptyList: Bool

    /// A missing file is empty. A file that is not a JSON object, or has unexpected types, is an error.
    init(contentsOf file: URL, client: AgentSetup.Client) throws {
        (section, key) = client == .cursor ? ("permissions", "allow") : ("sandbox", "excludedCommands")
        keepsEmptyList = client == .cursor
        guard FileManager.default.fileExists(atPath: file.path) else { object = [:]; return }
        let data = try Data(contentsOf: file)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let section = object[section] {
            guard let section = section as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            if let list = section[key], !(list is [String]) { throw CocoaError(.fileReadCorruptFile) }
        }
        self.object = object
    }

    var values: [String] {
        get { (object[section] as? [String: Any])?[key] as? [String] ?? [] }
        set {
            var section = object[self.section] as? [String: Any] ?? [:]
            section[key] = newValue.isEmpty && !keepsEmptyList ? nil : newValue
            object[self.section] = section.isEmpty ? nil : section
        }
    }

    func write(to file: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: object,
                                              options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
    }
}
