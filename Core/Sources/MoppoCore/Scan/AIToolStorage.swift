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
        let section: AIStorageSection
        var tool: FileEntry.AITool { section.owner.tool }
        var explanation: String = "Credentials, settings, memories, history, and installed files remain protected. Use the owning tool to manage them."
        var curationIdentifier: String? = nil
        var reviewsWorktrees: Bool = true
        var parts: [Part] = []
    }

    static let homeDotFolders: Set<String> = [".codex", ".claude", ".grokbot", ".t3"]
    static let dotCacheFolders: Set<String> = ["codex-runtimes"]

    static let roots: [Root] = [
        Root(path: ".codex", name: "Codex task data",
             section: .init(owner: .codex, title: "Task data",
                 summary: "Settings, attachments, plugins, and worktrees."), parts: [
            Part(path: "sessions", name: "Codex sessions", explanation: "Saved conversations and task history. Use Codex to manage these files."),
            Part(path: "archived_sessions", name: "Codex archived sessions", explanation: "Archived conversations can contain task history. Use Codex to manage these files."),
            Part(path: "attachments", name: "Codex attachments", explanation: "Files attached to tasks. These files can be the only local copies."),
            Part(path: "generated_images", name: "Codex generated images", explanation: "Images created in tasks. These files can be the only local copies."),
            Part(path: "memories", name: "Codex memories", explanation: "Persistent memories and supporting files remain protected. Session deletion does not select this folder."),
            Part(path: "plugins", name: "Codex plugins", explanation: "Installed plugins and their files. Use Codex to manage plugins."),
            Part(path: "cache", name: "Codex other cache files", explanation: "The folder name does not prove that removal is safe. Moppo keeps these files protected."),
            Part(path: ".tmp", name: "Codex temporary files", explanation: "These files can belong to active tasks. Moppo keeps them protected.")
        ]),
        Root(path: ".claude", name: "Claude Code data",
             section: .init(owner: .claudeCode, title: "Task data",
                 summary: "Conversations, memories, attachments, and recovery files."),
             explanation: "Credentials, settings, memories, and session files remain protected. Claude Code purge also deletes memories.", parts: [
            Part(path: "projects", name: "Claude Code sessions and memories", explanation: "Conversations, child sessions, tool results, and persistent memories share this folder. Moppo keeps the whole folder protected."),
            Part(path: "agent-memory", name: "Claude Code agent memories", explanation: "Persistent agent memories remain protected. These files can be shared across sessions."),
            Part(path: "file-history", name: "Claude Code file history", explanation: "Saved file versions support checkpoint recovery. Moppo keeps these files protected."),
            Part(path: "paste-cache", name: "Claude Code pasted text", explanation: "Saved pasted text can contain session content. The cache name does not make it disposable."),
            Part(path: "image-cache", name: "Claude Code saved images", explanation: "Earlier Claude Code versions stored attached images here. These files can be the only local copies."),
            Part(path: "uploads", name: "Claude Code uploaded files", explanation: "Files and photos attached to local sessions. These files can be the only local copies.")
        ]),
        Root(path: ".t3", name: "T3 Code data",
             section: .init(owner: .t3Code, title: "Local data",
                 summary: "Application data, scratch projects, downloaded tools, caches, and worktrees remain protected."),
             explanation: "T3 Code manages this storage. Moppo keeps all files protected, including unknown files and worktrees.",
             reviewsWorktrees: false, parts: [
            Part(path: "userdata", name: "T3 Code application data", explanation: "Settings, credentials, attachments, browser files, logs, and unknown state remain protected. Use T3 Code to manage them."),
            Part(path: "scratch", name: "T3 Code scratch projects", explanation: "Scratch projects can contain source files and dependencies. Moppo keeps the whole folder protected."),
            Part(path: "tools", name: "T3 Code downloaded tools", explanation: "Installed tools can be required by T3 Code. Moppo keeps them protected."),
            Part(path: "caches", name: "T3 Code caches", explanation: "The folder name does not prove that removal is safe. Moppo keeps these files protected."),
            Part(path: "worktrees", name: "T3 Code worktrees", explanation: "Worktrees can contain project files and local changes. Moppo keeps all T3 Code worktrees protected.")
        ]),
        Root(path: ".cursor/projects", name: "Cursor project data",
             section: .init(owner: .cursor, title: "Project data",
                 summary: "Project history and task files."),
             explanation: "Project history and task files can be the only local copies. Moppo keeps them protected."),
        Root(path: ".cursor/chats", name: "Cursor CLI sessions",
             section: .init(owner: .cursor, title: "CLI sessions",
                 summary: "Saved command-line conversations."),
             explanation: "Local conversations have no cloud backup. Moppo cannot verify inactive sessions and keeps this folder protected."),
        Root(path: ".cursor/worktrees", name: "Cursor worktrees",
             section: .init(owner: .cursor, title: "Worktrees",
                 summary: "Separate Git checkouts for tasks.")),
        Root(path: ".cache/codex-runtimes", name: "Codex downloaded runtimes",
             section: .init(owner: .codex, title: "Downloaded tools",
                 summary: "Downloaded runtimes used to run tasks.")),
        Root(path: ".grokbot", name: "Grok Bot local computer data",
             section: .init(owner: .grokBot, title: "Local computer data",
                 summary: "Credentials, settings, and files prepared for upload."),
             explanation: "Local computer credentials, settings, and staged attachments remain protected. Use Grok Bot to manage these files.", parts: [
            Part(path: "attachment-staging", name: "Grok Bot staged attachments", explanation: "Files prepared for upload can be the only local copies. Moppo keeps this folder protected.")
        ]),
        Root(path: "Library/Application Support/Grok Bot", name: "Grok Bot desktop data",
             section: .init(owner: .grokBot, title: "Desktop data",
                 summary: "Desktop profiles, settings, and caches."), curationIdentifier: "com.anysphere.sand"),
        Root(path: "Library/Application Support/Codex", name: "ChatGPT desktop data",
             section: .init(owner: .chatGPT, title: "Desktop data",
                 summary: "Desktop profiles, settings, and caches."), curationIdentifier: "com.openai.codex"),
        Root(path: "Library/Application Support/Claude", name: "Claude desktop data",
             section: .init(owner: .claude, title: "Desktop data",
                 summary: "Desktop profiles, caches, virtual machines, and local tasks."), curationIdentifier: "com.anthropic.claudefordesktop", parts: [
            Part(path: "vm_bundles/*/rootfs.img", name: "Claude VM system disk", explanation: "Linux system and installed tools. This disk can also contain task files. Use Claude to manage it."),
            Part(path: "vm_bundles/*/rootfs.img.zst", name: "Claude compressed VM download", explanation: "Compressed Linux runtime download. Moppo keeps it protected because Claude manages the VM installation."),
            Part(path: "vm_bundles/*/sessiondata.img", name: "Claude VM session disk", explanation: "This disk can contain local task files. Its allocated size can be smaller than its virtual capacity."),
            Part(path: "claude-code-vm", name: "Claude VM files", explanation: "Virtual machine runtime and task files. Use Claude to manage these files."),
            Part(path: "claude-code", name: "Claude downloaded tools", explanation: "Installed command-line tools. Use Claude to manage these files."),
            Part(path: "claude-code-sessions", name: "Claude desktop coding sessions", explanation: "Saved coding tasks and their files. Use Claude to manage these files."),
            Part(path: "local-agent-mode-sessions", name: "Claude local agent sessions", explanation: "Task history, uploaded files, and outputs share this folder with persistent memories and plugins. Moppo keeps the whole folder protected.")
        ]),
        Root(path: "Library/Application Support/Cursor", name: "Cursor desktop data",
             section: .init(owner: .cursor, title: "Desktop data",
                 summary: "Desktop settings, workspace state, and caches."), curationIdentifier: "com.todesktop.230313mzl4w4u92", parts: [
            Part(path: "User", name: "Cursor settings and workspace state", explanation: "Chat history, checkpoints, settings, and unsaved files remain protected. Delete individual chats in Cursor.")
        ])
    ]
}
