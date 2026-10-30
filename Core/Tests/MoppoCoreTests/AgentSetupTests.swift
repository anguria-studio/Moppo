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
