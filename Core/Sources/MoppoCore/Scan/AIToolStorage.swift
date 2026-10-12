import Foundation

/// Default paths verified in vendor sources or installed applications. See docs/ai-storage.md.
enum AIToolStorage {
    struct Part: Sendable {
        let path: String
        let name: String
        let explanation: String
    }

    struct Root: Sendable {
        let path: String
        let name: String
        let tool: FileEntry.AITool
        var explanation: String = "Credentials, settings, memories, history, and installed files remain protected. Use the owning tool to manage them."
        var curationIdentifier: String? = nil
        var parts: [Part] = []
    }

    static let homeDotFolders: Set<String> = [".codex", ".claude"]
    static let dotCacheFolders: Set<String> = ["codex-runtimes"]

    static let roots: [Root] = [
        Root(path: ".codex", name: "Codex task data", tool: .codex, parts: [
            Part(path: "sessions", name: "Codex sessions", explanation: "Saved conversations and task history. Use Codex to manage these files."),
            Part(path: "archived_sessions", name: "Codex archived sessions", explanation: "Archived conversations can contain task history. Use Codex to manage these files."),
            Part(path: "attachments", name: "Codex attachments", explanation: "Files attached to tasks. These files can be the only local copies."),
            Part(path: "generated_images", name: "Codex generated images", explanation: "Images created in tasks. These files can be the only local copies."),
            Part(path: "memories", name: "Codex memories", explanation: "Persistent memories and supporting files remain protected. Session deletion does not select this folder."),
            Part(path: "plugins", name: "Codex plugins", explanation: "Installed plugins and their files. Use Codex to manage plugins."),
            Part(path: "cache", name: "Codex other cache files", explanation: "The folder name does not prove that removal is safe. Moppo keeps these files protected."),
            Part(path: ".tmp", name: "Codex temporary files", explanation: "These files can belong to active tasks. Moppo keeps them protected.")
        ]),
        Root(path: ".claude", name: "Claude Code data", tool: .claude,
             explanation: "Credentials, settings, memories, and session files remain protected. Claude Code purge also deletes memories.", parts: [
            Part(path: "projects", name: "Claude Code sessions and memories", explanation: "Conversations, child sessions, tool results, and persistent memories share this folder. Moppo keeps the whole folder protected."),
            Part(path: "agent-memory", name: "Claude Code agent memories", explanation: "Persistent agent memories remain protected. These files can be shared across sessions."),
            Part(path: "file-history", name: "Claude Code file history", explanation: "Saved file versions support checkpoint recovery. Moppo keeps these files protected."),
            Part(path: "paste-cache", name: "Claude Code pasted text", explanation: "Saved pasted text can contain session content. The cache name does not make it disposable."),
            Part(path: "image-cache", name: "Claude Code saved images", explanation: "Earlier Claude Code versions stored attached images here. These files can be the only local copies."),
            Part(path: "uploads", name: "Claude Code uploaded files", explanation: "Files and photos attached to local sessions. These files can be the only local copies.")
        ]),
        Root(path: ".cursor/projects", name: "Cursor project data", tool: .cursor,
             explanation: "Project history and task files can be the only local copies. Moppo keeps them protected."),
        Root(path: ".cursor/chats", name: "Cursor CLI sessions", tool: .cursor,
             explanation: "Local conversations have no cloud backup. Moppo cannot verify inactive sessions and keeps this folder protected."),
        Root(path: ".cursor/worktrees", name: "Cursor worktrees", tool: .cursor),
        Root(path: ".cache/codex-runtimes", name: "Codex downloaded runtimes", tool: .codex),
        Root(path: "Library/Application Support/Codex", name: "ChatGPT desktop data", tool: .codex, curationIdentifier: "com.openai.codex"),
        Root(path: "Library/Application Support/Claude", name: "Claude desktop data", tool: .claude, curationIdentifier: "com.anthropic.claudefordesktop", parts: [
            Part(path: "vm_bundles/*/rootfs.img", name: "Claude VM system disk", explanation: "Linux system and installed tools. This disk can also contain task files. Use Claude to manage it."),
            Part(path: "vm_bundles/*/rootfs.img.zst", name: "Claude compressed VM download", explanation: "Compressed Linux runtime download. Moppo keeps it protected because Claude manages the VM installation."),
            Part(path: "vm_bundles/*/sessiondata.img", name: "Claude VM session disk", explanation: "This disk can contain local task files. Its allocated size can be smaller than its virtual capacity."),
            Part(path: "claude-code-vm", name: "Claude VM files", explanation: "Virtual machine runtime and task files. Use Claude to manage these files."),
            Part(path: "claude-code", name: "Claude downloaded tools", explanation: "Installed command-line tools. Use Claude to manage these files."),
            Part(path: "claude-code-sessions", name: "Claude desktop coding sessions", explanation: "Saved coding tasks and their files. Use Claude to manage these files."),
            Part(path: "local-agent-mode-sessions", name: "Claude local agent sessions", explanation: "Task history, uploaded files, and outputs share this folder with persistent memories and plugins. Moppo keeps the whole folder protected.")
        ]),
        Root(path: "Library/Application Support/Cursor", name: "Cursor desktop data", tool: .cursor, curationIdentifier: "com.todesktop.230313mzl4w4u92", parts: [
            Part(path: "User", name: "Cursor settings and workspace state", explanation: "Chat history, checkpoints, settings, and unsaved files remain protected. Delete individual chats in Cursor.")
        ])
    ]
}
