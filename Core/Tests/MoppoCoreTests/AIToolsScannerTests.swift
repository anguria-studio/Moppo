import Foundation
import Testing
@testable import MoppoCore

@Suite("AI storage")
struct AIToolsScannerTests {
    private final class Sandbox {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-ai-\(UUID().uuidString)")
        init() throws { try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true) }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ path: String, bytes: Int = 1024 * 1024) throws -> URL {
            let url = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }
    }

    @Test("History, unknown caches, and downloaded runtimes remain visible and locked")
    func inventoryProtection() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".codex/sessions/task.jsonl")
        try sandbox.file(".codex/cache/unknown.sqlite")
        try sandbox.file(".codex/auth.json", bytes: 4096)
        try sandbox.file(".codex/config.toml", bytes: 4096)
        try sandbox.file(".codex/memories/memory_summary.md")
        try sandbox.file(".codex/attachments/original.png")
        try sandbox.file(".codex/generated_images/output.png")
        try sandbox.file(".claude/projects/task/conversation.jsonl")
        try sandbox.file(".claude/projects/task/memory/MEMORY.md")
        try sandbox.file(".claude/projects/task/session/subagents/child.jsonl")
        try sandbox.file(".claude/projects/task/session/tool-results/image.png")
        try sandbox.file(".claude/agent-memory/reviewer/MEMORY.md")
        try sandbox.file(".claude/file-history/previous.txt")
        try sandbox.file(".claude/paste-cache/paste.txt")
        try sandbox.file(".claude/image-cache/session/image.png")
        try sandbox.file(".claude/uploads/session/original.pdf")
        try sandbox.file(".claude/settings.json", bytes: 4096)
        try sandbox.file(".claude/.credentials.json", bytes: 4096)
        try sandbox.file(".cursor/projects/task/state.json")
        try sandbox.file(".cursor/chats/workspace/session/store.db")
        try sandbox.file(".cache/codex-runtimes/runtime/bin/python")
        let context = ScanContext()
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        #expect(ai.entries.count == 5)
        let taskData = try #require(ai.entries.first { $0.url.lastPathComponent == ".codex" })
        let runtimes = try #require(ai.entries.first { $0.url.lastPathComponent == "codex-runtimes" })
        #expect(taskData.aiStorageSection?.owner == .codex)
        #expect(taskData.aiStorageSection?.title == "Task data")
        #expect(runtimes.aiStorageSection?.owner == .codex)
        #expect(runtimes.aiStorageSection?.title == "Downloaded tools")
        for entry in ai.entries {
            #expect(entry.displayBytes == (try await context.measurer.measure(entry.url)).allocatedBytes)
            #expect(entry.reclaimableBytes == 0)
            for row in [entry] + entry.children {
                #expect(row.isRemovalLocked)
                #expect(!row.regeneratesSafely)
                #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
            }
        }
        #expect(ai.safeToRemoveBytes == 0)
        #expect(ai.needsReviewBytes == ai.totalBytes)
        #expect(ai.totalBytes == (try await context.measurer.measure(sandbox.home)).allocatedBytes)
        let claude = try #require(ai.entries.first { $0.displayName == "Claude Code data" })
        #expect(claude.aiStorageSection?.owner == .claudeCode)
        #expect(claude.children.count == 6)
        #expect(claude.children.first { $0.url.lastPathComponent == "projects" }?.protectionExplanation?.contains("persistent memories") == true)
        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: context)
        let system = try await SystemCachesScanner(
            cachesRoot: sandbox.home.appendingPathComponent("Library/Caches"),
            logsRoot: sandbox.home.appendingPathComponent("Library/Logs"),
            dotCacheRoot: sandbox.home.appendingPathComponent(".cache")
        ).scan(context: context)
        #expect(hidden.entries.isEmpty)
        #expect(system.entries.isEmpty)
    }

    @Test("T3 Code sections retain unknown files and nested worktrees in one protected inventory")
    func t3Storage() async throws {
        let sandbox = try Sandbox()
        for path in ["userdata/state.db", "scratch/project/node_modules/.pnpm/dependency/index.js",
                     "tools/codex/bin/codex", "caches/pull-requests/state.json", "worktrees/task/source.txt"] {
            try sandbox.file(".t3/" + path)
        }
        for path in ["scratch/project/.git", "worktrees/task/.git", "unknown/task/.git"] {
            let marker = try sandbox.file(".t3/" + path, bytes: 0)
            try Data("gitdir: /missing/.git/worktrees/task\n".utf8).write(to: marker)
            #expect(GitWorktreeDetector.isWorktree(marker.deletingLastPathComponent()))
        }
        let unknown = try sandbox.file(".t3/unknown/records.db", bytes: 4096)
        let shared = try sandbox.file(".claude/projects/task/history.jsonl")
        let source = sandbox.home.appendingPathComponent(".t3/scratch/project/node_modules/.pnpm/dependency/index.js")
        try FileManager.default.linkItem(at: source, to: sandbox.home.appendingPathComponent(".t3/tools/shared.js"))
        let context = ScanContext()
        let log = try ScanDiagnostics(directory: sandbox.home.appendingPathComponent("logs"))
        let ai = try await ScanDiagnostics.$current.withValue(log.context) {
            try await AIToolsScanner(home: sandbox.home).scan(context: context)
        }
        log.finish(outcome: "completed")
        log.flush()
        let spans = try Data(contentsOf: log.fileURL).split(separator: 10).compactMap { line -> [String: String]? in
            let event = try #require(try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any])
            return event["event"] as? String == "span_end" ? event["details"] as? [String: String] : nil
        }
        let row = try #require(ai.entries.first { $0.aiStorageSection?.owner == .t3Code })
        #expect(row.aiTool == .t3Code)
        #expect(row.displayName == "T3 Code data")
        #expect(row.children.map(\.displayName) == ["T3 Code application data", "T3 Code scratch projects",
            "T3 Code downloaded tools", "T3 Code caches", "T3 Code worktrees"])
        #expect(row.allocatedBytes >= (try await context.measurer.measure(unknown)).allocatedBytes)
        #expect(row.displayBytes == (try await context.measurer.measure(row.url)).allocatedBytes)
        #expect(row.worktreeCount == 0)
        #expect(Set(([row] + row.children).map(\.id)).count == 6)
        for entry in [row] + row.children {
            #expect(entry.protectionReason == .inventory)
            #expect(entry.protectionExplanation?.isEmpty == false)
            #expect(!entry.regeneratesSafely)
            #expect(!CleanupService.removalAllowed(entry, userDataRemovalOverrides: [entry.id]))
        }
        let claude = try #require(ai.entries.first { $0.aiStorageSection?.owner == .claudeCode })
        #expect(claude.displayBytes == (try await context.measurer.measure(shared)).allocatedBytes)
        #expect(ai.totalBytes == row.displayBytes + claude.displayBytes)
        #expect(ai.safeToRemoveBytes == 0)
        #expect(ai.claimedStoragePaths.contains(row.url.path))
        #expect(spans.filter { $0["operation"]?.hasPrefix("measure_") == true
            && $0["path"]?.hasPrefix(row.url.path) == true }.count == 1)
        #expect(!spans.contains { $0["operation"] == "worktree_discovery" && $0["path"] == row.url.path })
        let excluded = try await AIToolsScanner(home: sandbox.home).scan(
            context: ScanContext(excludedPaths: [source.path]))
        let retained = try #require(excluded.entries.first { $0.aiTool == .t3Code })
        #expect(retained.isRemovalLocked)
        #expect(!retained.children.contains { $0.displayName == "T3 Code scratch projects" })
        #expect(retained.children.contains { $0.displayName == "T3 Code downloaded tools" })
        #expect(excluded.claimedStoragePaths.contains(row.url.path))
    }

    @Test("Gemini and Antigravity storage counts shared bytes once and keeps cache folders protected")
    func googleStorage() async throws {
        let sandbox = try Sandbox()
        for path in ["antigravity/brain/task.json", "antigravity-cli/settings.json", "antigravity-ide/state.db",
                     "history/project.json", "bin/agent", "logs/run.log", "tmp/project/checkpoint.json"] {
            try sandbox.file(".gemini/" + path)
        }
        let unknown = try sandbox.file(".gemini/oauth_creds.json", bytes: 4096)
        for path in ["Cache/data", "Code Cache/js/index", "GPUCache/data_0", "User/globalStorage/state.vscdb"] {
            try sandbox.file("Library/Application Support/Antigravity/" + path)
        }
        let context = ScanContext()
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        let shared = try #require(ai.entries.first { $0.aiStorageSection?.owner == .gemini })
        #expect(shared.aiTool == .gemini)
        #expect(shared.children.map(\.displayName) == ["Antigravity data", "Antigravity CLI data",
            "Antigravity editor data", "Shared history", "Shared installed tools", "Shared logs", "Shared temporary files"])
        #expect(shared.allocatedBytes >= (try await context.measurer.measure(unknown)).allocatedBytes)
        #expect(shared.displayBytes == (try await context.measurer.measure(shared.url)).allocatedBytes)
        let desktop = try #require(ai.entries.first { $0.aiStorageSection?.owner == .antigravity })
        #expect(desktop.aiTool == .antigravity)
        #expect(desktop.children.isEmpty)
        #expect(desktop.displayBytes == (try await context.measurer.measure(desktop.url)).allocatedBytes)
        for entry in [shared, desktop] + shared.children {
            #expect(entry.protectionReason == .inventory)
            #expect(entry.protectionExplanation?.isEmpty == false)
            #expect(!entry.regeneratesSafely)
            #expect(!CleanupService.removalAllowed(entry, userDataRemovalOverrides: [entry.id]))
        }
        #expect(ai.entries.count == 2)
        #expect(ai.totalBytes == shared.displayBytes + desktop.displayBytes)
        #expect(ai.safeToRemoveBytes == 0)
        #expect(ai.claimedStoragePaths.contains(shared.url.path))
        #expect(ai.claimedStoragePaths.contains(desktop.url.path))
        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: context)
        #expect(!hidden.entries.contains { $0.url.lastPathComponent == ".gemini" })
    }

    /// File and folder names come from the #216 layouts on 3 November 2026. Contents are placeholders.
    private static let inventoryLayout: [(root: String, owner: AIStorageSection.Owner, files: [String], children: [String])] = [
        (".local/share/claude", .claudeCode, ["versions/2.1.316", "versions/2.1.317"], []),
        (".local/share/cursor-agent", .cursor, ["versions/2026.10.22-27dcf5f/index.js",
            "versions/2026.10.22-27dcf5f/node_modules/sqlite3/package.json"], []),
        (".copilot", .copilot, ["session-state/8758cd1f/events.jsonl", "installed-plugins/plugin/plugin.json",
            "logs/process-1.log", "session-store.db", "config.json"], ["Copilot sessions", "Copilot plugins", "Copilot logs"]),
        (".local/share/opencode", .openCode, ["opencode.db", "snapshot/global/aec7d851/HEAD", "log/opencode.log"],
            ["OpenCode snapshots", "OpenCode logs"]),
        (".local/state/opencode", .openCode, ["service.json"], []),
        (".config/opencode", .openCode, ["service.json"], []),
        (".local/share/goose", .goose, ["sessions/sessions.db", "model_catalog/models_dev_api.json", "apps/clock.html"],
            ["Goose sessions", "Goose model catalog"]),
        (".local/state/goose", .goose, ["logs/llm_request.0.jsonl"], []),
        (".config/goose", .goose, ["config.yaml", "tls/server.pem"], []),
        (".openclaw", .openClaw, ["agents/main/sessions/session.jsonl", "workspace/AGENTS.md", "state/openclaw.sqlite",
            "openclaw.json"], ["OpenClaw agent sessions", "OpenClaw workspace", "OpenClaw state"]),
        (".kiro", .kiro, ["sessions/9f68821c/sess_62cb7786/state.json", "logs/20261103T125504357/kiro.log", "argv.json"],
            ["Kiro sessions", "Kiro logs"]),
        (".kiro-shared", .kiro, ["sharedStorage/state.vscdb"], []),
        (".codeium", .devin, ["windsurf/memories/global_rules.md", "windsurf/cascade/conversation.pb", "windsurf/installation_id"],
            ["Devin memories and rules", "Cascade conversations"]),
        (".devin", .devin, ["argv.json", "extensions/extensions.json"], []),
        (".devin-shared", .devin, ["sharedStorage/state.vscdb"], []),
        (".local/share/devin", .devin, ["cli/sessions.db", "cli/logs/devin.log"], ["Devin CLI logs"]),
        (".config/devin", .devin, ["config.json"], []),
        ("Library/Application Support/t3code-v2", .t3Code, ["Cache/Cache_Data/data_0", "Local Storage/leveldb/000003.log"], []),
        ("Library/Application Support/anythingllm-desktop", .anythingLLM, ["storage/anythingllm.db",
            "storage/documents/custom-documents/file.json", "storage/lancedb/workspace.lance/data", "storage/models/context-windows/data.json",
            "storage/engines/ffmpeg/ffmpeg", "GPUCache/data_0"],
            ["AnythingLLM documents", "AnythingLLM vector database", "AnythingLLM models", "AnythingLLM downloaded engines"]),
        (".cherrystudio", .cherryStudio, ["bin/uv"], ["Cherry Studio installed tools"]),
        ("Library/Application Support/CherryStudio", .cherryStudio, ["Data/cherrystudio.sqlite", "Toolchain/mise/bin/mise",
            "Runtime/models/model.json", "Cache/Cache_Data/data_0"],
            ["Cherry Studio library", "Cherry Studio toolchain", "Cherry Studio runtime data"]),
        ("ComfyUI-Installs", .comfy, ["ComfyUI/.launcher/snapshots/snapshot.json", "ComfyUI/ComfyUI/main.py",
            "ComfyUI/ComfyUI/models/checkpoints/model.safetensors", "ComfyUI/ComfyUI/output/image.png",
            "ComfyUI/ComfyUI/user/default/workflows/workflow.json", "ComfyUI/ComfyUI/custom_nodes/node/__init__.py",
            "ComfyUI/ComfyUI/.venv/lib/site.py", "ComfyUI/standalone-env/bin/python3"],
            ["ComfyUI models", "ComfyUI outputs", "ComfyUI workflows and settings", "ComfyUI custom nodes",
             "ComfyUI Python packages", "ComfyUI Python runtime"]),
        ("ComfyUI-Shared", .comfy, ["models/checkpoints/model.safetensors", "models/loras/lora.safetensors",
            "input/image.png", "output/image.png"], ["ComfyUI shared models", "ComfyUI shared input files", "ComfyUI shared outputs"]),
        ("Applications/Data", .stabilityMatrix, [".sm-portable", "StabilityMatrix.db", "settings.json",
            "Models/StableDiffusion/model.safetensors"], ["Stability Matrix models"])
    ]

    @Test("Tools from the #216 inventory show protected rows, and other categories do not list their paths again")
    func inventoryOnlyTools() async throws {
        let sandbox = try Sandbox()
        let applications = sandbox.home.appendingPathComponent("Applications")
        for tool in Self.inventoryLayout {
            for file in tool.files { try sandbox.file(tool.root + "/" + file, bytes: 8192) }
        }
        // Large folders that Hidden & System Data would list if AI Tools did not claim them.
        for path in [".copilot/logs/process-2.log", ".cherrystudio/bin/bun", ".config/goose/tls/server.key"] {
            try sandbox.file(path, bytes: 6 * 1024 * 1024)
        }
        try sandbox.file(".config/gh/hosts.bin", bytes: 6 * 1024 * 1024)
        let context = ScanContext()
        let ai = try await AIToolsScanner(home: sandbox.home, applications: applications).scan(context: context)
        #expect(ai.entries.count == Self.inventoryLayout.count)
        for tool in Self.inventoryLayout {
            let url = sandbox.home.appendingPathComponent(tool.root)
            let row = try #require(ai.entries.first { $0.url == url }, "\(tool.root)")
            #expect(row.aiStorageSection?.owner == tool.owner)
            #expect(row.aiTool == tool.owner.tool)
            #expect(row.children.map(\.displayName) == tool.children, "\(tool.root)")
            #expect(row.displayBytes == (try await context.measurer.measure(url)).allocatedBytes)
            for entry in [row] + row.children {
                #expect(entry.protectionReason == .inventory)
                #expect(entry.protectionExplanation?.isEmpty == false)
                #expect(!entry.regeneratesSafely)
                #expect(!CleanupService.removalAllowed(entry, userDataRemovalOverrides: [entry.id]))
            }
            #expect(ai.claimedStoragePaths.contains(url.path))
        }
        #expect(ai.totalBytes == ai.entries.reduce(0) { $0 + $1.displayBytes })
        #expect(ai.safeToRemoveBytes == 0)
        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: context)
        #expect(hidden.entries.map(\.displayName) == [".config/gh"])
    }

    @Test("Folder names alone do not identify Comfy Desktop, Stability Matrix, or installer storage")
    func unidentifiedToolFolders() async throws {
        let sandbox = try Sandbox()
        let applications = sandbox.home.appendingPathComponent("Applications")
        for path in ["Applications/Data/StabilityMatrix.db", "ComfyUI-Installs/ComfyUI/ComfyUI/main.py",
                     "ComfyUI-Shared/models/checkpoints/model.safetensors", "ComfyUI-Shared/output/image.png",
                     ".local/share/claude/notes.txt", ".local/share/cursor-agent/notes.txt"] {
            try sandbox.file(path, bytes: 8192)
        }
        let ai = try await AIToolsScanner(home: sandbox.home, applications: applications).scan(context: ScanContext())
        #expect(ai.entries.isEmpty)
        #expect(!ai.claimedStoragePaths.contains { $0.hasPrefix(sandbox.home.path + "/ComfyUI") || $0.hasPrefix(applications.path)
            || $0.hasPrefix(sandbox.home.path + "/.local/share/c") })
    }

    @Test("AI attachments cannot enter the archive sweep when AI Tools is disabled",
          arguments: [".cursor/chats/workspace/session", ".t3/userdata"])
    func sessionArchives(path: String) async throws {
        let sandbox = try Sandbox()
        let attachment = try sandbox.file(path + "/attachment.zip", bytes: 260 * 1024 * 1024)
        let context = ScanContext()
        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: context)
        #expect(hidden.entries.isEmpty)
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        let row = try #require(ai.entries.first)
        #expect(row.displayName == (path.hasPrefix(".t3") ? "T3 Code data" : "Cursor CLI sessions"))
        #expect(row.displayBytes == (try await context.measurer.measure(attachment)).allocatedBytes)
        #expect(row.isRemovalLocked)
        #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
    }

    @Test("Claude VM files use allocated bytes and only verified desktop caches count as safe")
    func vmAndDesktopCaches() async throws {
        let sandbox = try Sandbox()
        let prefix = "Library/Application Support/Claude/"
        try sandbox.file(prefix + "vm_bundles/claudevm.bundle/rootfs.img")
        try sandbox.file(prefix + "vm_bundles/claudevm.bundle/rootfs.img.zst")
        let session = try sandbox.file(prefix + "vm_bundles/claudevm.bundle/sessiondata.img", bytes: 4096)
        let handle = try FileHandle(forWritingTo: session)
        try handle.truncate(atOffset: 1024 * 1024 * 1024)
        try handle.close()
        try sandbox.file(prefix + "Cache/data")
        try sandbox.file(prefix + "Code Cache/js/data")
        try sandbox.file(prefix + "Partitions/feature/Cache/data")
        try sandbox.file(prefix + "Cookies", bytes: 4096)
        try sandbox.file(prefix + "Service Worker/CacheStorage/offline-state")
        let taskFiles = try sandbox.file(prefix + "local-agent-mode-sessions/account/task/uploads/original.pdf")
        try sandbox.file(prefix + "local-agent-mode-sessions/account/memory/MEMORY.md")
        let context = ScanContext()
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        let row = try #require(ai.entries.first)
        #expect(row.aiStorageSection?.owner == .claude)
        #expect(row.children.filter(\.isRegenerable).count == 3)
        #expect(row.children.filter { $0.protectionReason == .inventory }.count == 4)
        #expect(row.children.first { $0.url.lastPathComponent == "local-agent-mode-sessions" }?.protectionExplanation?.contains("persistent memories") == true)
        let sessionRow = try #require(row.children.first { $0.url == session })
        #expect(sessionRow.allocatedBytes == (try await context.measurer.measure(session)).allocatedBytes)
        #expect(sessionRow.allocatedBytes < 1024 * 1024 * 1024)
        #expect(row.displayBytes == (try await context.measurer.measure(row.url)).allocatedBytes)
        #expect(row.reclaimableBytes == ai.safeToRemoveBytes)
        #expect(ai.safeToRemoveBytes + ai.needsReviewBytes == ai.totalBytes)
        #expect(ai.filtered(safeToRemove: true).totalBytes == ai.safeToRemoveBytes)
        #expect(ai.filtered(safeToRemove: false).totalBytes == ai.needsReviewBytes)
        #expect(!row.children.contains { $0.url.path.contains("Service Worker") })
        #expect(!row.children.filter { !$0.isRemovalLocked }.contains { taskFiles.path.hasPrefix($0.url.path + "/") })

        var running = context
        running.runningApplications = [.init(name: "Claude", bundleIdentifier: "com.anthropic.claudefordesktop", bundlePath: "/Applications/Claude.app")]
        let inUse = try await AIToolsScanner(home: sandbox.home).scan(context: running)
        #expect(inUse.safeToRemoveBytes == 0)
        #expect(inUse.entries.flatMap(\.children).filter(\.isRegenerable).allSatisfy { $0.inUseBy != nil })
    }

    @Test("Grok Bot caches preserve desktop state and local computer data", arguments: [false, true])
    func grokBotStorage(running: Bool) async throws {
        let sandbox = try Sandbox()
        let prefix = "Library/Application Support/Grok Bot/"
        let cachePaths = [
            "Cache/data", "Code Cache/js/data", "GPUCache/data",
            "Partitions/sand-forever-box/Cache/data",
            "Partitions/sand-forever-box/Code Cache/js/data",
            "Partitions/sand-forever-box/GPUCache/data",
            "Partitions/sand-forever-box/DawnWebGPUCache/data",
            "Partitions/sand-forever-box/DawnGraphiteCache/data",
            "v8-code-cache/main-app-build.v8"
        ]
        for path in cachePaths { try sandbox.file(prefix + path) }
        let protectedPaths = [
            "Cookies", "sand-secrets.json", "sand-client-persistence/task.json",
            "Partitions/sand-forever-box/Local Storage/leveldb/CURRENT",
            "Partitions/sand-forever-box/Session Storage/state",
            "Partitions/sand-forever-box/Shared Dictionary/db",
            "Partitions/sand-forever-box/Service Worker/ScriptCache/state",
            "plugin-logo-cache/unknown-file"
        ]
        for path in protectedPaths { try sandbox.file(prefix + path) }
        try sandbox.file(".grokbot/local-exec-daemon-credential.json", bytes: 4096)
        try sandbox.file(".grokbot/settings.json", bytes: 4096)
        try sandbox.file(".grokbot/attachment-staging/original.zip", bytes: 6 * 1024 * 1024)

        var context = ScanContext()
        if running {
            context.runningApplications = [.init(
                name: "Grok Bot", bundleIdentifier: "com.anysphere.sand", bundlePath: "/Applications/Grok Bot.app"
            )]
        }
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        let desktop = try #require(ai.entries.first { $0.displayName == "Grok Bot desktop data" })
        let local = try #require(ai.entries.first { $0.displayName == "Grok Bot local computer data" })
        let caches = desktop.children.filter(\.isRegenerable)
        #expect(caches.count == cachePaths.count)
        #expect(caches.allSatisfy { $0.kind == .cache && !$0.isRemovalLocked })
        #expect(caches.allSatisfy { ($0.inUseBy != nil) == running })
        #expect(desktop.aiTool == .grokBot && local.aiTool == .grokBot)
        #expect(desktop.aiStorageSection?.owner == .grokBot && local.aiStorageSection?.owner == .grokBot)
        for path in protectedPaths {
            let url = sandbox.home.appendingPathComponent(prefix + path)
            #expect(!caches.contains { ApplicationsScanner.overlaps($0.url.path, url.path) })
        }
        for row in [desktop, local] + local.children {
            #expect(row.isRemovalLocked)
            #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
        }
        #expect(local.children.map(\.displayName) == ["Grok Bot staged attachments"])
        #expect(desktop.displayBytes == (try await context.measurer.measure(desktop.url)).allocatedBytes)
        #expect(local.displayBytes == (try await context.measurer.measure(local.url)).allocatedBytes)
        #expect(ai.totalBytes == desktop.displayBytes + local.displayBytes)
        #expect(ai.safeToRemoveBytes == (running ? 0 : caches.reduce(0) { $0 + $1.allocatedBytes }))
        #expect(ai.safeToRemoveBytes + ai.needsReviewBytes == ai.totalBytes)

        let hidden = try await HiddenDataScanner(home: sandbox.home).scan(context: context)
        #expect(hidden.entries.isEmpty)
    }

    @Test("AI ownership removes duplicate rows and retains installed application bundles")
    func categoryOwnership() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("Library/Application Support/Codex/Cache/data")
        try sandbox.file("Library/Application Support/Codex/Cookies")
        let ai = try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext())
        let root = try #require(ai.entries.first)
        let cache = try #require(root.children.first)
        let app = FileEntry(url: sandbox.home.appendingPathComponent("Applications/ChatGPT.app"), kind: .appBundle,
                            allocatedBytes: 2_000_000, children: [cache, root])
        #expect(root.aiStorageSection?.owner == .chatGPT)
        #expect(root.aiTool == .chatGPT)
        let hidden = FileEntry(url: root.url.appendingPathComponent("vm.img"), kind: .diskImage, allocatedBytes: 3_000_000)
        let results = ScanCoordinator.removingAIToolOverlaps(from: [
            ai, ScanCategoryResult(categoryID: .applications, entries: [app]),
            ScanCategoryResult(categoryID: .hiddenSystemData, entries: [hidden])
        ])
        #expect(results.first { $0.categoryID == .applications }?.entries.first?.children.isEmpty == true)
        #expect(results.first { $0.categoryID == .applications }?.totalBytes == app.allocatedBytes)
        #expect(results.first { $0.categoryID == .hiddenSystemData }?.availability == .empty)

        let excluded = try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext(excludedPaths: [cache.url.path]))
        let retained = try #require(excluded.entries.first)
        #expect(retained.id == root.id)
        #expect(retained.isRemovalLocked)
        #expect(!retained.children.contains { $0.id == cache.id })
        #expect(!excluded.claimedStoragePaths.isEmpty)
        let guarded = ScanCoordinator.removingAIToolOverlaps(from: [excluded,
            ScanCategoryResult(categoryID: .systemCaches, entries: [cache])])
        #expect(guarded.last?.entries.isEmpty == true)
    }

    @Test("Removed AI desktop data uses the leftover review and installed owners retain AI storage",
          arguments: ["Cursor", "Grok Bot", "Antigravity"])
    func desktopOwnership(appName: String) async throws {
        let sandbox = try Sandbox()
        let identifier = ["Cursor": "com.todesktop.230313mzl4w4u92", "Grok Bot": "com.anysphere.sand",
                          "Antigravity": "com.google.antigravity"][appName]!
        let desktop = sandbox.home.appendingPathComponent("Library/Application Support/" + appName, isDirectory: true)
        try sandbox.file("Library/Application Support/" + appName + "/Cache/data")
        try sandbox.file("Library/Application Support/" + appName + "/User/history.db")
        try sandbox.file(".cursor/projects/task/state.json")
        let applications = sandbox.home.appendingPathComponent("Applications")
        let planner = OrphanedAppLeftoverPlanner(pathPlanner: AppUninstallPlanner(
            home: sandbox.home,
            systemLibrary: sandbox.home.appendingPathComponent("SystemLibrary"),
            applicationRoots: [applications], darwinCache: nil, darwinTemp: nil
        ))
        let coordinator = ScanCoordinator(scanners: [
            ApplicationLeftoversScanner(planner: planner), AIToolsScanner(home: sandbox.home)
        ])

        let absent = try await coordinator.scan()
        let leftovers = try #require(absent.categories.first { $0.categoryID == .applicationLeftovers })
        let group = try #require(leftovers.entries.first)
        #expect(group.removalAction == .orphanedApplication(bundleIdentifier: identifier))
        #expect(group.children.map(\.url) == [desktop])
        #expect(group.children.first?.protectionReason == .userData)
        #expect(leftovers.safeToRemoveBytes == 0)
        #expect(leftovers.needsReviewBytes == leftovers.totalBytes)
        #expect(absent.categories.first { $0.categoryID == .aiTools }?.entries.map(\.displayName) == ["Cursor project data"])
        #expect(absent.totalBytes == (try await ScanContext().measurer.measure(desktop)).allocatedBytes
            + (try await ScanContext().measurer.measure(sandbox.home.appendingPathComponent(".cursor/projects"))).allocatedBytes)

        let registered = try await coordinator.scan(context: ScanContext(
            registeredApplicationBundleIdentifiers: [identifier]
        ))
        #expect(registered.categories.first { $0.categoryID == .applicationLeftovers }?.entries.isEmpty == true)
        #expect(registered.categories.first { $0.categoryID == .aiTools }?.entries.contains { $0.url == desktop } == true)

        let plist: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": appName,
                                   "CFBundlePackageType": "APPL", "CFBundleVersion": "1"]
        let info = try sandbox.file("Applications/" + appName + ".app/Contents/Info.plist", bytes: 0)
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: info)
        let installed = try await coordinator.scan()
        #expect(installed.categories.first { $0.categoryID == .applicationLeftovers }?.entries.isEmpty == true)
        #expect(installed.categories.first { $0.categoryID == .aiTools }?.entries.contains { $0.url == desktop } == true)
    }

    @Test("Absent roots, protected patterns, and symlink targets do not produce removal rows",
          arguments: [".claude", ".t3"])
    func missingAndProtectedPaths(root: String) async throws {
        let sandbox = try Sandbox()
        #expect(try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext()).availability == .empty)
        try FileManager.default.createDirectory(at: sandbox.home.appendingPathComponent(".t3/worktrees"),
                                                withIntermediateDirectories: true)
        #expect(try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext()).availability == .empty)
        try FileManager.default.removeItem(at: sandbox.home.appendingPathComponent(".t3"))
        let external = try sandbox.file("outside/feature/Cache/data")
        let linkedRoot = root == ".t3" ? ".claude" : ".t3"
        try FileManager.default.createSymbolicLink(at: sandbox.home.appendingPathComponent(linkedRoot),
                                                  withDestinationURL: external.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: sandbox.home.appendingPathComponent(".codex"),
                                                  withDestinationURL: external.deletingLastPathComponent())
        try sandbox.file(root + "/userdata/private.keychain-db")
        try sandbox.file("Library/Application Support/Claude/Cookies")
        let partition = sandbox.home.appendingPathComponent("Library/Application Support/Claude/Partitions")
        try FileManager.default.createSymbolicLink(at: partition,
                                                  withDestinationURL: external.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
        let result = try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext(excludedPatterns: ["*.keychain-db"]))
        #expect(result.entries.map(\.displayName) == ["Claude desktop data"])
        #expect(result.entries.first?.children.isEmpty == true)
        #expect(result.safeToRemoveBytes == 0)
    }

    @Test("Unreadable AI folders report a measurement gap and remain claimed", arguments: [".claude", ".t3"])
    func unreadableStorage(root: String) async throws {
        let sandbox = try Sandbox()
        let file = try sandbox.file(root + "/userdata/task.jsonl")
        let folder = file.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        let result = try await AIToolsScanner(home: sandbox.home).scan(context: ScanContext())
        #expect(result.unreadableCount > 0)
        #expect(result.claimedStoragePaths.contains(sandbox.home.appendingPathComponent(root).path))
        #expect(result.safeToRemoveBytes == 0)
    }
}
