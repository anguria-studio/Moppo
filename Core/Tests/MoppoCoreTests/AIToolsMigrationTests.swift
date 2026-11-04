import Testing
@testable import MoppoCore

/// The generated `AIToolStorage.roots`, `ApplicationsScanner.curations`, `FileEntry.AITool`, and
/// `AIStorageSection.Owner` equal the tables and enums that the Swift files held before #352.
/// This test leaves with the old tables, after the pull request records that it passed.
@Suite("AI tools migration")
struct AIToolsMigrationTests {
    private typealias Root = AIToolStorage.Root
    private typealias Part = AIToolStorage.Part
    private typealias AppDataCuration = ApplicationsScanner.AppDataCuration
    private static let electronRegenerable = ApplicationsScanner.electronRegenerable

    private     static let oldRoots: [Root] = [
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
        // The native installers keep each installed version in `versions`. `~/.local/bin` links to the active one.
        Root(path: ".local/share/claude", name: "Claude Code versions",
             section: .init(owner: .claudeCode, title: "Installed versions",
                 summary: "Versions from the native installer."),
             explanation: "The native installer keeps the installed Claude Code versions here. Moppo keeps them protected.",
             reviewsWorktrees: false, identifiedBy: ["versions"]),
        Root(path: ".local/share/cursor-agent", name: "Cursor CLI versions",
             section: .init(owner: .cursor, title: "CLI versions",
                 summary: "Versions from the Cursor CLI installer."),
             explanation: "The Cursor CLI installer keeps the installed versions here. Moppo keeps them protected.",
             reviewsWorktrees: false, identifiedBy: ["versions"]),
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
        ]),
        // Gemini CLI and Antigravity share this folder. One root counts each byte once.
        Root(path: ".gemini", name: "Gemini and Antigravity shared data",
             section: .init(owner: .gemini, title: "Shared data",
                 summary: "Gemini CLI and Antigravity settings, history, and installed tools."),
             explanation: "Gemini CLI and Antigravity share this folder. Moppo keeps all files protected, including credentials, settings, and unknown files.",
             reviewsWorktrees: false, parts: [
            Part(path: "antigravity", name: "Antigravity data", explanation: "Antigravity task data and settings. Use Antigravity to manage these files."),
            Part(path: "antigravity-cli", name: "Antigravity CLI data", explanation: "Antigravity command-line data and settings. Use Antigravity to manage these files."),
            Part(path: "antigravity-ide", name: "Antigravity editor data", explanation: "Antigravity editor data and settings. Use Antigravity to manage these files."),
            Part(path: "history", name: "Shared history", explanation: "Saved history can contain task content. Moppo keeps these files protected."),
            Part(path: "bin", name: "Shared installed tools", explanation: "Gemini CLI or Antigravity can require these tools. Moppo keeps them protected."),
            Part(path: "logs", name: "Shared logs", explanation: "The folder name does not prove that removal is safe. Moppo keeps these files protected."),
            Part(path: "tmp", name: "Shared temporary files", explanation: "These files can belong to active tasks. Moppo keeps them protected.")
        ]),
        Root(path: "Library/Application Support/Antigravity", name: "Antigravity desktop data",
             section: .init(owner: .antigravity, title: "Desktop data",
                 summary: "Desktop profile, settings, credentials, and caches."),
             explanation: "Moppo has not verified which Antigravity desktop files are safe to remove. All files remain protected, including cache folders.",
             reviewsWorktrees: false),
        // The #216 inventory on 3 November 2026 found the roots below. They are inventory only.
        Root(path: "Library/Application Support/t3code-v2", name: "T3 Code desktop data",
             section: .init(owner: .t3Code, title: "Desktop data",
                 summary: "Desktop profile, settings, and caches."),
             explanation: "Moppo has not verified which T3 Code desktop files are safe to remove. All files remain protected, including cache folders.",
             reviewsWorktrees: false),
        Root(path: ".copilot", name: "GitHub Copilot CLI data",
             section: .init(owner: .copilot, title: "CLI data",
                 summary: "Sessions, settings, plugins, and logs."),
             explanation: "Copilot CLI keeps sessions, settings, and plugins here. Moppo keeps all files protected, including unknown files.",
             reviewsWorktrees: false, parts: [
            Part(path: "session-state", name: "Copilot sessions", explanation: "Saved sessions, checkpoints, and file snapshots. Use Copilot CLI to manage them."),
            Part(path: "installed-plugins", name: "Copilot plugins", explanation: "Installed plugins and their files. Use Copilot CLI to manage plugins."),
            Part(path: "logs", name: "Copilot logs", explanation: "The folder name does not prove that removal is safe. Moppo keeps these files protected.")
        ]),
        Root(path: ".local/share/opencode", name: "OpenCode data",
             section: .init(owner: .openCode, title: "Local data",
                 summary: "Session database, snapshots, and logs."),
             explanation: "OpenCode keeps its session database and other data here. Moppo keeps all files protected, including unknown files.",
             reviewsWorktrees: false, parts: [
            Part(path: "snapshot", name: "OpenCode snapshots", explanation: "OpenCode can use snapshots to undo file changes. Moppo keeps them protected."),
            Part(path: "log", name: "OpenCode logs", explanation: "The folder name does not prove that removal is safe. Moppo keeps these files protected.")
        ]),
        Root(path: ".local/state/opencode", name: "OpenCode state",
             section: .init(owner: .openCode, title: "State",
                 summary: "Files that OpenCode uses while it runs."),
             explanation: "OpenCode uses these files while it runs. Moppo keeps them protected.",
             reviewsWorktrees: false),
        Root(path: ".config/opencode", name: "OpenCode settings",
             section: .init(owner: .openCode, title: "Settings",
                 summary: "Settings and service files."),
             explanation: "Settings can contain provider keys. Moppo keeps these files protected.",
             reviewsWorktrees: false),
        Root(path: ".local/share/goose", name: "Goose data",
             section: .init(owner: .goose, title: "Local data",
                 summary: "Sessions, apps, and the model catalog."),
             explanation: "Goose keeps sessions and other data here. Moppo keeps all files protected, including unknown files.",
             reviewsWorktrees: false, parts: [
            Part(path: "sessions", name: "Goose sessions", explanation: "Saved sessions and task history. Use Goose to manage them."),
            Part(path: "model_catalog", name: "Goose model catalog", explanation: "Goose downloads this list of models. The evidence does not show that removal is safe.")
        ]),
        Root(path: ".local/state/goose", name: "Goose logs",
             section: .init(owner: .goose, title: "Logs",
                 summary: "Logs, including requests to models."),
             explanation: "Logs can contain requests to models. Moppo keeps these files protected.",
             reviewsWorktrees: false),
        Root(path: ".config/goose", name: "Goose settings",
             section: .init(owner: .goose, title: "Settings",
                 summary: "Settings, sign-in data, and local keys."),
             explanation: "Settings, sign-in data, and local keys remain protected. Use Goose to manage them.",
             reviewsWorktrees: false),
        Root(path: ".openclaw", name: "OpenClaw data",
             section: .init(owner: .openClaw, title: "Local data",
                 summary: "Agent sessions, workspace files, state, and settings."),
             explanation: "OpenClaw keeps agent data and settings here. Moppo keeps all files protected, including unknown files.",
             reviewsWorktrees: false, parts: [
            Part(path: "agents", name: "OpenClaw agent sessions", explanation: "Agent settings and saved sessions. Use OpenClaw to manage them."),
            Part(path: "workspace", name: "OpenClaw workspace", explanation: "Workspace files and their Git history can be the only copies. Moppo keeps them protected."),
            Part(path: "state", name: "OpenClaw state", explanation: "OpenClaw uses these databases while it runs. Moppo keeps them protected.")
        ]),
        Root(path: ".kiro", name: "Kiro data",
             section: .init(owner: .kiro, title: "Local data",
                 summary: "Sessions, extensions, powers, and logs."),
             explanation: "Kiro keeps sessions and settings here. Moppo keeps all files protected, including unknown files.",
             reviewsWorktrees: false, parts: [
            Part(path: "sessions", name: "Kiro sessions", explanation: "Saved sessions and task history. Use Kiro to manage them."),
            Part(path: "logs", name: "Kiro logs", explanation: "The folder name does not prove that removal is safe. Moppo keeps these files protected.")
        ]),
        Root(path: ".kiro-shared", name: "Kiro shared state",
             section: .init(owner: .kiro, title: "Shared state",
                 summary: "State that Kiro windows share."),
             explanation: "Kiro uses this state database. Moppo keeps it protected.",
             reviewsWorktrees: false),
        // Devin Desktop, Windsurf, and Codeium extensions can share `~/.codeium`.
        Root(path: ".codeium", name: "Devin and Windsurf shared data",
             section: .init(owner: .devin, title: "Shared data",
                 summary: "Memories, rules, and agent data for Devin Desktop and Windsurf."),
             explanation: "Devin Desktop, Windsurf, and Codeium tools can share this folder. Moppo keeps all files protected, including memories and rules.",
             reviewsWorktrees: false, parts: [
            Part(path: "windsurf/memories", name: "Devin memories and rules", explanation: "Memories and global rules remain protected. Use Devin Desktop to manage them."),
            Part(path: "windsurf/cascade", name: "Cascade conversations", explanation: "Saved conversations can be the only local copies. Moppo keeps them protected.")
        ]),
        Root(path: ".devin", name: "Devin editor data",
             section: .init(owner: .devin, title: "Editor data",
                 summary: "Extensions and startup settings."),
             explanation: "Devin Desktop keeps extensions and settings here. Moppo keeps them protected.",
             reviewsWorktrees: false),
        Root(path: ".devin-shared", name: "Devin shared state",
             section: .init(owner: .devin, title: "Shared state",
                 summary: "State that Devin Desktop windows share."),
             explanation: "Devin Desktop uses this state database. Moppo keeps it protected.",
             reviewsWorktrees: false),
        Root(path: ".local/share/devin", name: "Devin CLI data",
             section: .init(owner: .devin, title: "CLI data",
                 summary: "CLI sessions, plugins, and logs."),
             explanation: "Devin CLI keeps its session database and plugins here. Moppo keeps all files protected.",
             reviewsWorktrees: false, parts: [
            Part(path: "cli/logs", name: "Devin CLI logs", explanation: "The folder name does not prove that removal is safe. Moppo keeps these files protected.")
        ]),
        Root(path: ".config/devin", name: "Devin CLI settings",
             section: .init(owner: .devin, title: "CLI settings",
                 summary: "Devin CLI settings."),
             explanation: "Settings remain protected. Use Devin CLI to manage them.",
             reviewsWorktrees: false),
        Root(path: "Library/Application Support/anythingllm-desktop", name: "AnythingLLM desktop data",
             section: .init(owner: .anythingLLM, title: "Desktop data",
                 summary: "Workspaces, documents, vector data, downloaded engines, and caches."),
             explanation: "Moppo has not verified which AnythingLLM files are safe to remove. All files remain protected, including keys and cache folders.",
             reviewsWorktrees: false, parts: [
            Part(path: "storage/documents", name: "AnythingLLM documents", explanation: "Documents added to workspaces can be the only local copies."),
            Part(path: "storage/lancedb", name: "AnythingLLM vector database", explanation: "Workspace search data. Moppo keeps it protected."),
            Part(path: "storage/models", name: "AnythingLLM models", explanation: "Downloaded models and model data. Use AnythingLLM to manage them."),
            Part(path: "storage/engines", name: "AnythingLLM downloaded engines", explanation: "AnythingLLM can require these downloaded tools. Moppo keeps them protected.")
        ]),
        Root(path: ".cherrystudio", name: "Cherry Studio data",
             section: .init(owner: .cherryStudio, title: "Local data",
                 summary: "Downloaded tools and settings."),
             explanation: "Cherry Studio keeps downloaded tools and settings here. Moppo keeps all files protected.",
             reviewsWorktrees: false, parts: [
            Part(path: "bin", name: "Cherry Studio installed tools", explanation: "Cherry Studio can require these tools. Moppo keeps them protected.")
        ]),
        Root(path: "Library/Application Support/CherryStudio", name: "Cherry Studio desktop data",
             section: .init(owner: .cherryStudio, title: "Desktop data",
                 summary: "Notes, agents, toolchains, credentials, and caches."),
             explanation: "Moppo has not verified which Cherry Studio files are safe to remove. All files remain protected, including credentials and cache folders.",
             reviewsWorktrees: false, parts: [
            Part(path: "Data", name: "Cherry Studio library", explanation: "Notes, agents, skills, and the main database can be the only local copies."),
            Part(path: "Toolchain", name: "Cherry Studio toolchain", explanation: "Cherry Studio can require these downloaded tools. Moppo keeps them protected."),
            Part(path: "Runtime", name: "Cherry Studio runtime data", explanation: "Cherry Studio uses this model and provider data. Moppo keeps it protected.")
        ]),
        // Comfy Desktop 1.1.8 made these folders. Its launcher folder and ComfyUI identify an installation.
        Root(path: "ComfyUI-Installs", name: "ComfyUI installations",
             section: .init(owner: .comfy, title: "Installations",
                 summary: "ComfyUI, its Python environment, models, outputs, and custom nodes."),
             explanation: "Comfy Desktop installs ComfyUI here. Moppo keeps all files protected, including models and outputs.",
             reviewsWorktrees: false, identifiedBy: ["*/.launcher", "*/ComfyUI/main.py"], parts: [
            Part(path: "*/ComfyUI/models", name: "ComfyUI models", explanation: "Downloaded and added models. Use Comfy Desktop to manage them."),
            Part(path: "*/ComfyUI/output", name: "ComfyUI outputs", explanation: "Generated images and other outputs can be the only copies."),
            Part(path: "*/ComfyUI/user", name: "ComfyUI workflows and settings", explanation: "Saved workflows and settings can be the only copies."),
            Part(path: "*/ComfyUI/custom_nodes", name: "ComfyUI custom nodes", explanation: "Installed custom nodes and their files. Use Comfy Desktop to manage them."),
            Part(path: "*/ComfyUI/.venv", name: "ComfyUI Python packages", explanation: "ComfyUI needs these installed packages to run. Moppo keeps them protected."),
            Part(path: "*/standalone-env", name: "ComfyUI Python runtime", explanation: "ComfyUI needs this Python runtime to run. Moppo keeps it protected.")
        ]),
        Root(path: "ComfyUI-Shared", name: "ComfyUI shared files",
             section: .init(owner: .comfy, title: "Shared files",
                 summary: "Models, input files, and outputs that installations share."),
             explanation: "Comfy Desktop installations share these files. Moppo keeps all files protected.",
             reviewsWorktrees: false, identifiedBy: ["models/checkpoints", "models/loras", "output"], parts: [
            Part(path: "models", name: "ComfyUI shared models", explanation: "Models that installations share. Use Comfy Desktop to manage them."),
            Part(path: "input", name: "ComfyUI shared input files", explanation: "Input files can be the only copies. Moppo keeps them protected."),
            Part(path: "output", name: "ComfyUI shared outputs", explanation: "Generated images and other outputs can be the only copies.")
        ]),
        // Stability Matrix 2.16.5 in portable mode keeps `Data` next to the application.
        Root(path: "Data", name: "Stability Matrix data",
             section: .init(owner: .stabilityMatrix, title: "Portable data",
                 summary: "Models, settings, and the Stability Matrix database."),
             base: .applications,
             explanation: "Stability Matrix keeps its portable data next to the application. Moppo keeps all files protected.",
             reviewsWorktrees: false, identifiedBy: [".sm-portable", "StabilityMatrix.db"], parts: [
            Part(path: "Models", name: "Stability Matrix models", explanation: "Models that the installed packages share. Use Stability Matrix to manage them.")
        ])
    ]

    private static let oldCurations: [String: AppDataCuration] = [
        // Chrome mixes multi-gigabyte regenerable trees with the user's logins,
        // history and bookmarks, and the generic leftover candidates cannot see
        // the difference. The on-device models are routinely the largest single
        // item in the folder.
        "com.google.Chrome": AppDataCuration(
            root: "Library/Application Support/Google/Chrome",
            regenerable: [
                "OptGuideOnDeviceModel", "OptGuideOnDeviceClassifierModel",
                "optimization_guide_model_store", "component_crx_cache",
                "SODA", "SODALanguagePacks", "screen_ai", "WasmTtsEngine",
                "GrShaderCache", "ShaderCache", "Crashpad",
                // Per-profile caches. The caches inside a profile regenerate, the
                // databases beside them are the user's life.
                //
                // Nothing under `Service Worker` is offered — not `CacheStorage`,
                // not `ScriptCache`, not `Database`. It reads like three folders
                // and behaves like one: `Database` holds the registration, and the
                // registration addresses script bodies in `ScriptCache` by resource
                // id. An installed worker's script is served from there and is
                // *not* re-fetched on the next visit, so taking the caches while
                // the registration survives leaves Chrome pointing at resources
                // that are gone.
                //
                // Moppo took 721.5 MB of `CacheStorage` and 72.8 MB of `ScriptCache`
                // out of this Mac's Chrome profiles on 30 Aug 2026 and left
                // `Database` behind; the wreckage was a `CacheStorage` bucket with
                // no `index.txt` beside Instagram's and YouTube's, which still had
                // theirs. `www.reddit.com` went black at the same time and this
                // was blamed for it — wrongly, as far as anyone has shown:
                // clearing the site's data changed nothing. The fault that was
                // later caught by name is the dictionary one below.
                //
                // Chrome's own "Clear browsing data" removes the three together.
                // Moppo removes none of them: a site's offline data belongs in the
                // locked remainder next to the cookies that go with it.
                //
                // `Shared Dictionary` is withheld too, and it was the one that
                // could be seen failing. It was offered because it is
                // self-contained on disk — index and dictionaries in one folder —
                // and that was the wrong test: a running Chrome holds the index in
                // memory. Remove the folder under it and Chrome goes on sending
                // `Available-Dictionary` for bodies that are gone; the server
                // answers with a response only that dictionary can decode, and
                // the document fails with `net::ERR_DICTIONARY_LOAD_FAILED`.
                // Seen on 19 Sep 2026: `www.reddit.com` blank after a Safe to
                // Remove sweep, unmoved by "Clear site data", cured by
                // relaunching Chrome. 52.2 MB across eight profiles is not worth
                // a site that will not load.
                "Default/Code Cache",
                "Default/GPUCache",
                "Profile */Code Cache",
                "Profile */GPUCache"
            ],
            remainderName: "Chrome profiles and settings"
        ),

        // Claude Desktop is Electron, but it keeps its renderers in per-feature
        // partitions, so its Chromium caches sit one level down and the marker
        // test below never sees them at the top of the folder. Verified against a
        // real install.
        //
        // `claude-code` and `claude-code-vm` are the two largest items here and
        // are deliberately left in the locked remainder: an installed CLI and its
        // VM image are not caches, and nothing observed says the app rebuilds
        // them on demand.
        "com.anthropic.claudefordesktop": AppDataCuration(
            root: "Library/Application Support/Claude",
            regenerable: electronRegenerable + ["Partitions/*/Cache", "Partitions/*/Code Cache"],
            remainderName: "Claude settings and data"
        ),

        // VS Code uses the historical product name `Code` rather than either its
        // display name or bundle identifier, so the generic Electron lookup cannot
        // reach it. `User`, workspaceStorage, History and extensions deliberately
        // remain in the protected remainder.
        "com.microsoft.VSCode": AppDataCuration(
            root: "Library/Application Support/Code",
            regenerable: electronRegenerable + [
                "CachedData", "CachedExtensions", "CachedExtensionVSIXs",
                "CachedProfilesData", "CachedConfigurations"
            ],
            remainderName: "Visual Studio Code settings and data"
        ),

        // Cursor keeps its desktop profile after the application is removed.
        // Its stable bundle identifier links this named root to the leftover review.
        "com.todesktop.230313mzl4w4u92": AppDataCuration(
            root: "Library/Application Support/Cursor",
            regenerable: electronRegenerable,
            remainderName: "Cursor settings and data"
        ),

        // Antigravity desktop 2.28.1 uses this identifier and support folder.
        // The evidence does not verify its cache folders, so no path counts as regenerable.
        "com.google.antigravity": AppDataCuration(
            root: "Library/Application Support/Antigravity",
            regenerable: [],
            remainderName: "Antigravity settings and data"
        ),

        // Grok Bot 0.70.2 uses Chromium partitions and rebuilds V8 caches from bundled JavaScript.
        // Credentials, session state, and staged attachments remain outside these cache paths.
        "com.anysphere.sand": AppDataCuration(
            root: "Library/Application Support/Grok Bot",
            regenerable: electronRegenerable + [
                "Partitions/*/Cache", "Partitions/*/Code Cache", "Partitions/*/GPUCache",
                "Partitions/*/DawnWebGPUCache", "Partitions/*/DawnGraphiteCache",
                "Partitions/*/DawnCache", "v8-code-cache"
            ],
            remainderName: "Grok Bot settings and data"
        ),

        // The ChatGPT desktop bundle currently identifies as `com.openai.codex`
        // and stores its Chromium profile under `Codex`; neither identifier nor
        // display name points to that folder.
        "com.openai.codex": AppDataCuration(
            root: "Library/Application Support/Codex",
            regenerable: electronRegenerable + [
                "Default/Cache", "Default/Code Cache", "Default/GPUCache"
            ],
            remainderName: "ChatGPT profiles and settings"
        ),

        // Figma keeps one Chromium profile per desktop engine version. Old engine
        // caches are often the bulk of the folder, while the files beside them and
        // the bundled agents are installation/user state.
        "com.figma.Desktop": AppDataCuration(
            root: "Library/Application Support/Figma",
            regenerable: [
                "DesktopProfile/*/Cache", "DesktopProfile/*/Code Cache",
                "DesktopProfile/*/GPUCache", "DesktopProfile/*/Crashpad"
            ],
            remainderName: "Figma settings and data"
        ),

        // Ferdium has normal Electron caches at the root plus a Chromium partition
        // per configured messaging service. Recipes, configuration, cookies and
        // sessions remain protected.
        "org.ferdium.ferdium-app": AppDataCuration(
            root: "Library/Application Support/Ferdium",
            regenerable: electronRegenerable + [
                "Partitions/*/Cache", "Partitions/*/Code Cache",
                "Partitions/*/GPUCache"
            ],
            remainderName: "Ferdium accounts and settings"
        ),

        // Tor Browser deliberately separates disposable browser caches from the
        // profile and Tor keys. The whole profile root must never be called cache.
        "org.torproject.torbrowser": AppDataCuration(
            root: "Library/Application Support/TorBrowser-Data",
            regenerable: ["Browser/Caches"],
            remainderName: "Tor Browser profile and settings"
        )
    ]


    private static let oldTools: [(String, String)] = [
        ("codex", "Codex"),
        ("chatGPT", "ChatGPT"),
        ("claude", "Claude"),
        ("cursor", "Cursor"),
        ("grokBot", "GrokBot"),
        ("t3Code", "T3Code"),
        ("ollama", "Ollama"),
        ("huggingFace", "HuggingFace"),
        ("lmStudio", "LMStudio"),
        ("pyTorch", "PyTorch"),
        ("whisper", "Whisper"),
        ("keras", "Keras"),
        ("gpt4All", "GPT4All"),
        ("gemini", "Gemini"),
        ("antigravity", "Antigravity"),
        ("copilot", "Copilot"),
        ("openCode", "OpenCode"),
        ("goose", "Goose"),
        ("openClaw", "OpenClaw"),
        ("kiro", "Kiro"),
        ("devin", "Devin"),
        ("anythingLLM", "AnythingLLM"),
        ("cherryStudio", "CherryStudio"),
        ("comfy", "Comfy"),
        ("stabilityMatrix", "StabilityMatrix"),
    ]

    private static let oldOwners: [(String, String)] = [
        ("codex", "Codex"),
        ("chatGPT", "ChatGPT"),
        ("claudeCode", "Claude Code"),
        ("claude", "Claude"),
        ("cursor", "Cursor"),
        ("grokBot", "Grok Bot"),
        ("t3Code", "T3 Code"),
        ("ollama", "Ollama"),
        ("huggingFace", "Hugging Face"),
        ("lmStudio", "LM Studio"),
        ("pyTorch", "PyTorch"),
        ("whisper", "Whisper"),
        ("keras", "Keras"),
        ("gpt4All", "GPT4All"),
        ("gemini", "Gemini"),
        ("antigravity", "Antigravity"),
        ("copilot", "GitHub Copilot"),
        ("openCode", "OpenCode"),
        ("goose", "Goose"),
        ("openClaw", "OpenClaw"),
        ("kiro", "Kiro"),
        ("devin", "Devin"),
        ("anythingLLM", "AnythingLLM"),
        ("cherryStudio", "Cherry Studio"),
        ("comfy", "Comfy Desktop"),
        ("stabilityMatrix", "Stability Matrix"),
    ]

    private static let oldOwnerTools: [AIStorageSection.Owner: FileEntry.AITool] = [
        .codex: .codex,
        .chatGPT: .chatGPT,
        .claudeCode: .claude,
        .claude: .claude,
        .cursor: .cursor,
        .grokBot: .grokBot,
        .t3Code: .t3Code,
        .ollama: .ollama,
        .huggingFace: .huggingFace,
        .lmStudio: .lmStudio,
        .pyTorch: .pyTorch,
        .whisper: .whisper,
        .keras: .keras,
        .gpt4All: .gpt4All,
        .gemini: .gemini,
        .antigravity: .antigravity,
        .copilot: .copilot,
        .openCode: .openCode,
        .goose: .goose,
        .openClaw: .openClaw,
        .kiro: .kiro,
        .devin: .devin,
        .anythingLLM: .anythingLLM,
        .cherryStudio: .cherryStudio,
        .comfy: .comfy,
        .stabilityMatrix: .stabilityMatrix,
    ]

    private static func description(_ root: Root) -> String {
        let parts = root.parts.map { "\($0.path)|\($0.name)|\($0.explanation)" }.sorted()
        return "\(root.base) \(root.path) | \(root.name) | \(root.section.owner) \(root.section.title) \(root.section.summary) | "
            + "\(root.explanation) | \(root.curationIdentifier ?? "-") | \(root.reviewsWorktrees) | \(root.identifiedBy) | \(parts)"
    }

    @Test("the generated AI roots equal the old table")
    func generatedRootsEqualOldTable() {
        #expect(AIToolStorage.roots.map(Self.description).sorted() == Self.oldRoots.map(Self.description).sorted())
    }

    @Test("the generated curations equal the old table")
    func generatedCurationsEqualOldTable() {
        #expect(ApplicationsScanner.curations == Self.oldCurations)
    }

    @Test("the generated enums equal the old enums")
    func generatedEnumsEqualOldEnums() {
        #expect(FileEntry.AITool.allCases.map { "\($0)=\($0.rawValue)" }.sorted()
                == Self.oldTools.map { "\($0.0)=\($0.1)" }.sorted())
        for (name, raw) in Self.oldOwners {
            let owner = AIStorageSection.Owner(rawValue: raw)
            #expect(owner.map { "\($0)" } == name)
            #expect(owner?.tool == Self.oldOwnerTools[owner!])
        }
        #expect(Self.oldOwnerTools.count == Self.oldOwners.count)
    }

    @Test("the generated icon identifiers equal the old table")
    func generatedIconsEqualOldTable() {
        let old: [FileEntry.AITool: String] = [
            .chatGPT: "com.openai.codex", .claude: "com.anthropic.claudefordesktop", .cursor: "com.todesktop.230313mzl4w4u92",
            .grokBot: "com.anysphere.sand", .t3Code: "com.t3tools.t3code", .antigravity: "com.google.antigravity",
            .gpt4All: "gpt4all", .openCode: "ai.opencode.desktop", .goose: "com.electron.goose", .kiro: "dev.kiro.desktop",
            .devin: "com.exafunction.windsurf", .anythingLLM: "com.anythingllm", .cherryStudio: "com.kangfenmao.CherryStudio",
            .comfy: "com.todesktop.241012ess7yxs0e", .stabilityMatrix: "ai.lykos.stabilitymatrix"
        ]
        #expect(ToolIcons.bundleIdentifiers == old)
        #expect(ToolIcons.paddedFallbacks == [.codex, .t3Code, .gpt4All, .openCode, .goose, .kiro, .devin, .anythingLLM,
                                              .cherryStudio, .comfy, .stabilityMatrix])
    }
}
