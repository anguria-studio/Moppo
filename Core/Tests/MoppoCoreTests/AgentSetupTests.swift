import Foundation
import Testing
@testable import MoppoCore

struct AgentSetupTests {
    private struct Fixture {
        let root: URL
        let setup: AgentSetup
        let trash: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-setup-" + UUID().uuidString)
            let app = root.appendingPathComponent("Moppo.app")
            let tool = app.appendingPathComponent("Contents/Helpers/moppo")
            let skill = app.appendingPathComponent("Contents/Resources/skills/moppo-cleanup")
            try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
            try Data("skill v2".utf8).write(to: skill.appendingPathComponent("SKILL.md"))
            let trash = root.appendingPathComponent("Trash")
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            self.trash = trash
            setup = AgentSetup(home: root.appendingPathComponent("home"), toolSource: tool, skillSource: skill,
                moveToTrash: { url in
                    try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
                })
        }
    }

    @Test func toolLinkInstallsReplacesOnlyWithConfirmationAndNeverRemovesOtherFiles() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        #expect(f.setup.toolState == .notInstalled)
        try f.setup.installTool()
        #expect(f.setup.toolState == .installed)
        #expect(FileManager.default.isExecutableFile(atPath: f.setup.toolLink.path))

        // A link to another Moppo copy, such as an older app or a development build.
        try FileManager.default.removeItem(at: f.setup.toolLink)
        try FileManager.default.createSymbolicLink(at: f.setup.toolLink, withDestinationURL: f.root.appendingPathComponent("other"))
        #expect(f.setup.toolState == .different)
        #expect(throws: AgentSetup.SetupError.confirmationRequired) { try f.setup.installTool() }
        try f.setup.installTool(replace: true)
        #expect(f.setup.toolState == .installed)
        try f.setup.removeTool()
        #expect(f.setup.toolState == .notInstalled)

        // A regular file that the user created.
        try Data("mine".utf8).write(to: f.setup.toolLink)
        #expect(f.setup.toolState == .blocked)
        #expect(throws: AgentSetup.SetupError.blocked) { try f.setup.installTool(replace: true) }
        try f.setup.removeTool()
        #expect(try Data(contentsOf: f.setup.toolLink) == Data("mine".utf8))
    }

    @Test func skillInstallsPerClientAndMovesReplacedVersionsToTrash() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        for client in AgentSetup.Client.allCases { #expect(f.setup.skillState(for: client) == .notInstalled) }
        try f.setup.installSkill(for: .claudeCode)
        #expect(f.setup.skillState(for: .claudeCode) == .installed)
        #expect(f.setup.skillState(for: .codex) == .notInstalled)
        #expect(f.setup.skillFolder(for: .codex).path.hasSuffix(".agents/skills/moppo-cleanup"))

        let installed = f.setup.skillFolder(for: .claudeCode).appendingPathComponent("SKILL.md")
        try Data("skill v1 with local edits".utf8).write(to: installed)
        #expect(f.setup.skillState(for: .claudeCode) == .different)
        #expect(throws: AgentSetup.SetupError.confirmationRequired) { try f.setup.installSkill(for: .claudeCode) }
        try f.setup.installSkill(for: .claudeCode, replace: true)
        #expect(try Data(contentsOf: installed) == Data("skill v2".utf8))
        let trashed = try FileManager.default.contentsOfDirectory(at: f.trash, includingPropertiesForKeys: nil)
        #expect(trashed.count == 1)
        #expect(try Data(contentsOf: trashed[0].appendingPathComponent("SKILL.md")) == Data("skill v1 with local edits".utf8))

        try f.setup.removeSkill(for: .claudeCode)
        #expect(f.setup.skillState(for: .claudeCode) == .notInstalled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).count == 2)
    }

    private func settings(_ file: URL) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    @Test func claudeSandboxRuleChangesOnlyItsOwnEntry() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let file = try #require(f.setup.sandboxRuleFile(for: .claudeCode))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"""
        {"$schema": "https://json.schemastore.org/claude-code-settings.json", "model": "opus",
         "sandbox": {"enabled": true, "excludedCommands": ["docker *"], "filesystem": {"allowWrite": ["~/.kube"]}}}
        """#.utf8).write(to: file)
        #expect(f.setup.sandboxRuleState(for: .claudeCode) == .notInstalled)

        try f.setup.installSkill(for: .claudeCode)
        try f.setup.installSkill(for: .claudeCode)
        #expect(f.setup.sandboxRuleState(for: .claudeCode) == .installed)
        var saved = try settings(file)
        var sandbox = try #require(saved["sandbox"] as? [String: Any])
        #expect(saved["model"] as? String == "opus")
        #expect(saved["$schema"] as? String == "https://json.schemastore.org/claude-code-settings.json")
        #expect(sandbox["enabled"] as? Bool == true)
        #expect(sandbox["excludedCommands"] as? [String] == ["docker *", "moppo *"])
        #expect((sandbox["filesystem"] as? [String: Any])?["allowWrite"] as? [String] == ["~/.kube"])

        try f.setup.removeSkill(for: .claudeCode)
        #expect(f.setup.sandboxRuleState(for: .claudeCode) == .notInstalled)
        saved = try settings(file)
        sandbox = try #require(saved["sandbox"] as? [String: Any])
        #expect(sandbox["excludedCommands"] as? [String] == ["docker *"])
        #expect(sandbox["enabled"] as? Bool == true)

        // Without other settings, removal leaves an empty object.
        try FileManager.default.removeItem(at: file)
        try f.setup.installSandboxRule(for: .claudeCode)
        #expect(try settings(file)["sandbox"] as? [String: [String]] == ["excludedCommands": ["moppo *"]])
        try f.setup.removeSandboxRule(for: .claudeCode)
        #expect(try settings(file).isEmpty)
    }

    @Test func unreadableOrLinkedClaudeSettingsStayUnchanged() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let file = try #require(f.setup.sandboxRuleFile(for: .claudeCode))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let linked = f.root.appendingPathComponent("dotfiles-settings.json")
        try Data(#"{"model": "opus"}"#.utf8).write(to: linked)
        let cases: [(String, () throws -> Void)] = [
            ("invalid JSON", { try Data("{ // comment".utf8).write(to: file) }),
            ("unexpected sandbox type", { try Data(#"{"sandbox": "on"}"#.utf8).write(to: file) }),
            ("linked file", { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: linked) }),
        ]
        for (name, make) in cases {
            try? FileManager.default.removeItem(at: file)
            try make()
            let before = try Data(contentsOf: file)
            #expect(f.setup.sandboxRuleState(for: .claudeCode) == .blocked, "\(name)")
            #expect(throws: AgentSetup.SetupError.sandboxRuleBlocked(.claudeCode)) { try f.setup.installSkill(for: .claudeCode) }
            #expect(f.setup.skillState(for: .claudeCode) == .installed, "\(name)")
            #expect(try Data(contentsOf: file) == before, "\(name)")
        }
        #expect(try Data(contentsOf: linked) == Data(#"{"model": "opus"}"#.utf8))
    }

    @Test func codexRulesFileIsMoppoOwnedAndCursorHasNoRuleFile() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let file = try #require(f.setup.sandboxRuleFile(for: .codex))
        #expect(file.path.hasSuffix(".codex/rules/moppo.rules"))
        try f.setup.installSkill(for: .codex)
        #expect(try String(contentsOf: file, encoding: .utf8) == AgentSetup.codexRules)
        #expect(f.setup.sandboxRuleState(for: .codex) == .installed)

        // A rules file from an earlier Moppo version moves to Trash.
        try Data((AgentSetup.codexRulesMarker + "\nprefix_rule(pattern = [\"moppo\"])\n").utf8).write(to: file)
        #expect(f.setup.sandboxRuleState(for: .codex) == .different)
        try f.setup.installSandboxRule(for: .codex)
        #expect(f.setup.sandboxRuleState(for: .codex) == .installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.trash.path).count == 1)

        try f.setup.removeSkill(for: .codex)
        #expect(f.setup.sandboxRuleState(for: .codex) == .notInstalled)

        // A file that the user wrote stays in place.
        try Data("prefix_rule(pattern = [\"moppo\"], decision = \"prompt\")\n".utf8).write(to: file)
        #expect(throws: AgentSetup.SetupError.sandboxRuleBlocked(.codex)) { try f.setup.installSkill(for: .codex) }
        try f.setup.removeSandboxRule(for: .codex)
        #expect(FileManager.default.fileExists(atPath: file.path))

        #expect(f.setup.sandboxRuleFile(for: .cursor) == nil)
        #expect(f.setup.sandboxRuleState(for: .cursor) == nil)
        try f.setup.installSkill(for: .cursor)
        #expect(f.setup.skillState(for: .cursor) == .installed)
    }

    @Test func appBundleLayoutProvidesBothSources() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let setup = AgentSetup(appBundle: f.root.appendingPathComponent("Moppo.app"), home: f.root.appendingPathComponent("home"))
        try setup.installTool()
        try setup.installSkill(for: .codex)
        #expect(setup.toolState == .installed)
        #expect(setup.skillState(for: .codex) == .installed)
    }

    @Test func missingSourcesInstallNothing() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let empty = AgentSetup(home: f.root.appendingPathComponent("home"),
                               toolSource: f.root.appendingPathComponent("missing/moppo"),
                               skillSource: f.root.appendingPathComponent("missing/skill"))
        #expect(throws: AgentSetup.SetupError.sourceMissing) { try empty.installTool() }
        #expect(throws: AgentSetup.SetupError.sourceMissing) { try empty.installSkill(for: .cursor) }
        #expect(empty.toolState == .notInstalled)
        #expect(empty.skillState(for: .cursor) == .notInstalled)
    }
}
