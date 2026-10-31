import AppKit
import SwiftUI
import MoppoCore

/// Settings → Advanced: installs the `moppo` command and the agent skill in one step each.
struct AgentSetupSection: View {

    var setup = AgentSetup(appBundle: Bundle.main.bundleURL)

    /// File system state is not observable. Changing this value reads it again.
    @State private var revision = 0
    @State private var message: String?
    @State private var pendingReplacement: Replacement?

    private enum Replacement: Identifiable {
        case tool
        case skill(AgentSetup.Client)
        var id: String {
            switch self {
            case .tool: "tool"
            case .skill(let client): client.rawValue
            }
        }
    }

    var body: some View {
        PrefSection("Command line and agents") {
            toolRow
            PrefDivider()
            pathRow
            ForEach(AgentSetup.Client.allCases) { client in
                PrefDivider()
                skillRow(client)
            }
            if let message {
                PrefDivider()
                Text(message)
                    .font(.callout)
                    .foregroundStyle(Token.color(.red))
                    .padding(.horizontal, PrefMetrics.rowPaddingH)
                    .padding(.vertical, PrefMetrics.rowPaddingV)
            }
        }
        .id(revision)
        .alert(item: $pendingReplacement) { replacement in
            switch replacement {
            case .tool:
                Alert(
                    title: Text("Replace the moppo command?"),
                    message: Text("~/.local/bin/moppo links to another copy of Moppo. The command will use this copy."),
                    primaryButton: .default(Text("Replace")) { run { try setup.installTool(replace: true) } },
                    secondaryButton: .cancel()
                )
            case .skill(let client):
                Alert(
                    title: Text("Update the \(client.displayName) skill?"),
                    message: Text("The installed version is different. Moppo moves it to the Trash, then installs this version."),
                    primaryButton: .default(Text("Update")) { run { try setup.installSkill(for: client, replace: true) } },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    // MARK: Rows

    /// Only the shell line uses the path font. The sentence uses the normal description style.
    private var pathRow: some View {
        HStack(spacing: PrefMetrics.controlGap) {
            VStack(alignment: .leading, spacing: PrefMetrics.labelGap) {
                PrefLabel(title: "Terminal path", description: "If Terminal cannot find moppo, add this line to ~/.zprofile.")
                Text(AgentSetup.pathLine)
                    .font(.mcMonoPath)
                    .foregroundStyle(Token.Text.tertiary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: PrefMetrics.controlGap)
            Button("Copy Line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(AgentSetup.pathLine, forType: .string)
            }
            .buttonStyle(SecondaryButtonStyle(fill: Token.Fill.buttonOnCard))
        }
        .padding(.horizontal, PrefMetrics.rowPaddingH)
        .padding(.vertical, PrefMetrics.rowPaddingV)
        .frame(maxWidth: .infinity, minHeight: PrefMetrics.rowHeight)
    }

    private var toolRow: some View {
        let state = setup.toolState
        let description: String = switch state {
        case .notInstalled: "Adds moppo to ~/.local/bin. App updates also update the command."
        case .installed: "~/.local/bin/moppo uses this copy of Moppo."
        case .different: "~/.local/bin/moppo uses another copy of Moppo."
        case .blocked: "Another file uses ~/.local/bin/moppo. Moppo does not replace it."
        }
        return PrefRow(title: "Command-line tool", description: description) {
            switch state {
            case .notInstalled: button("Install") { try setup.installTool() }
            case .installed: button("Remove") { try setup.removeTool() }
            case .different: button("Replace…") { pendingReplacement = .tool }
            case .blocked: button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([setup.toolLink])
            }
            }
        }
    }

    private func skillRow(_ client: AgentSetup.Client) -> some View {
        let state = setup.skillState(for: client)
        let rule = setup.sandboxRuleState(for: client)
        let ruleMissing = state == .installed && (rule == .notInstalled || rule == .different)
        let folder = (setup.skillFolder(for: client).path as NSString).abbreviatingWithTildeInPath
        let description: String = switch state {
        case .notInstalled:
            ["Lets \(client.displayName) scan and clean up with moppo. Removal always needs your approval.",
             Self.sandboxSentence(client, action: "Setup also")].compactMap { $0 }.joined(separator: " ")
        case .installed where ruleMissing: Self.sandboxSentence(client, action: "Allow") ?? folder
        case .installed where rule == .blocked: Self.blockedRuleMessage(client)
        case .installed: folder
        case .different: "A different version is in \(folder)."
        case .blocked: "A file uses \(folder). Moppo does not replace it."
        }
        return PrefRow(title: "\(client.displayName) skill", description: description,
                       descriptionIsPath: state == .installed && !ruleMissing && rule != .blocked) {
            switch state {
            case .notInstalled: button("Install") { try setup.installSkill(for: client) }
            case .installed where ruleMissing: button("Allow") { try setup.installSandboxRule(for: client) }
            case .installed: button("Remove") { try setup.removeSkill(for: client) }
            case .different: button("Update…") { pendingReplacement = .skill(client) }
            case .blocked: button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([setup.skillFolder(for: client)])
            }
            }
        }
    }

    /// Says what setup changes outside the skill folder. Cursor keeps its allowlist in its own settings.
    private static func sandboxSentence(_ client: AgentSetup.Client, action: String) -> String? {
        switch client {
        case .claudeCode: "\(action) lets moppo run outside the Claude Code sandbox."
        case .codex: "\(action) lets moppo run outside the Codex sandbox. Restart Codex after this change."
        case .cursor: nil
        }
    }

    private static func blockedRuleMessage(_ client: AgentSetup.Client) -> String {
        switch client {
        case .claudeCode:
            #"Moppo cannot change ~/.claude/settings.json. Edit the "moppo *" entry in sandbox.excludedCommands yourself."#
        case .codex, .cursor:
            "Another file uses ~/.codex/rules/moppo.rules. Moppo does not replace it."
        }
    }

    // MARK: Actions

    private func button(_ title: String, action: @escaping () throws -> Void) -> some View {
        Button(title) { run(action) }
            .buttonStyle(SecondaryButtonStyle(fill: Token.Fill.buttonOnCard))
    }

    private func run(_ action: () throws -> Void) {
        do {
            try action()
            message = nil
        } catch AgentSetup.SetupError.sourceMissing {
            message = "This copy of Moppo does not include the command-line tool or the skill."
        } catch AgentSetup.SetupError.sandboxRuleBlocked(let client) {
            message = Self.blockedRuleMessage(client)
        } catch {
            message = "Moppo could not change this item. " + error.localizedDescription
        }
        revision += 1
    }
}

#Preview("Agent setup") {
    PrefPane { AgentSetupSection() }
        .preferredColorScheme(.dark)
}
