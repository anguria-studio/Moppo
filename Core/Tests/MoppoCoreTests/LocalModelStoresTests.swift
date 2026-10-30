import Foundation
import Testing
@testable import MoppoCore

/// Checks protected inventory and shared model storage.
@Suite("Locally stored models")
struct LocalModelStoresTests {

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("moppo-models-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 1024, text: String? = nil) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try (text.map { Data($0.utf8) } ?? Data(repeating: 0x41, count: bytes)).write(to: url)
            return url
        }

        func link(_ relative: String, to destination: String) throws {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: destination)
        }

        /// An Ollama manifest naming a config blob and layer blobs by digest.
        func ollamaManifest(_ path: String, config: String, layers: [String]) throws {
            let layerJSON = layers.map { #"{"digest":"sha256:\#($0)","size":1}"# }.joined(separator: ",")
            try file(
                ".ollama/models/manifests/\(path)",
                text: #"{"schemaVersion":2,"config":{"digest":"sha256:\#(config)"},"layers":[\#(layerJSON)]}"#
            )
        }

        /// A hub repository in the shared-blob layout this Mac's store uses: the
        /// repository holds links, the bytes are in `hub/blobs/<aa>/<hash>`.
        func hubSharedBlob(_ hash: String, bytes: Int, usedBy repositories: [String]) throws {
            let shard = String(hash.prefix(2))
            try file(".cache/huggingface/hub/blobs/\(shard)/\(hash)", bytes: bytes)
            try file(".cache/huggingface/hub/blobs/\(shard)/\(hash).lock", bytes: 0)
            try file(
                ".cache/huggingface/hub/blobs/\(shard)/\(hash).refs",
                text: repositories.map { "\($0)/blobs/link-\(hash)" }.joined(separator: "\n") + "\n"
            )
            for repository in repositories {
                try link(".cache/huggingface/hub/\(repository)/blobs/link-\(hash)",
                         to: "../../blobs/\(shard)/\(hash)")
            }
        }
    }

    private let mb = 1024 * 1024

    @Test("Ollama models stay protected with legacy names, v2 aliases, and shared weights")
    func ollamaModelsStayProtected() async throws {
        let sandbox = try Sandbox()
        let weight = try sandbox.file(".ollama/models/blobs/sha256-weights", bytes: 4 * mb)
        try sandbox.ollamaManifest("registry.ollama.ai/library/qwen3/0.6b", config: "cfg", layers: ["weights"])
        try sandbox.file(".ollama/models/blobs/sha256-manifest",
            text: #"{"schemaVersion":2,"layers":[{"digest":"sha256:weights"}]}"#)
        try sandbox.link(".ollama/models/manifests-v2/ollama.com/library/test-alias/latest",
            to: "../../../../blobs/sha256-manifest")
        try sandbox.file(".ollama/id_ed25519", bytes: 400)
        let modelStore = sandbox.home.appendingPathComponent(".ollama/models")
        let context = ScanContext()
        let result = try await AIToolsScanner(home: sandbox.home).scan(context: context)
        let row = try #require(result.entries.first { $0.aiTool == .ollama })
        #expect(result.entries.filter { $0.aiTool == .ollama }.count == 1)
        #expect(row.url.path == modelStore.path)
        #expect(row.protectionReason == .inventory)
        #expect(row.isRemovalLocked && !row.isRegenerable)
        #expect(row.children.isEmpty && row.localModelPaths.isEmpty)
        #expect(row.allocatedBytes == (try await context.measurer.measure(modelStore)).allocatedBytes)
        #expect(row.allocatedBytes >= (try await context.measurer.measure(weight)).allocatedBytes)
        #expect(result.safeToRemoveBytes == 0)
        #expect(result.claimedStoragePaths.contains(sandbox.home.appendingPathComponent(".ollama").path))
        #expect(!result.entries.contains { $0.url.lastPathComponent == "id_ed25519" })
        #expect(LocalModelStores.all(home: sandbox.home).isEmpty)

        let excluded = try await AIToolsScanner(home: sandbox.home).scan(
            context: ScanContext(excludedPaths: [modelStore.path]))
        #expect(excluded.entries.isEmpty)
    }

    // MARK: - Hugging Face

    /// The layout read off this Mac: a 261 MB model in a repository folder that
    /// measured 0 bytes.
    @Test("hub repositories that share a large blob are one row; a blob with no record stays")
    func hubSharedBlobsFollowTheirRefs() throws {
        let sandbox = try Sandbox()
        try sandbox.hubSharedBlob("a5only", bytes: 5 * mb, usedBy: ["models--org--alone"])
        try sandbox.hubSharedBlob("b7both", bytes: 7 * mb,
                                  usedBy: ["models--org--alone", "models--org--other"])
        // A target with no record of who uses it is not thereby unused.
        try sandbox.hubSharedBlob("c9lost", bytes: 3 * mb, usedBy: ["models--org--other"])
        try FileManager.default.removeItem(
            at: sandbox.home.appendingPathComponent(".cache/huggingface/hub/blobs/c9/c9lost.refs")
        )

        let models = LocalModelStores.huggingFace(home: sandbox.home)

        let set = try #require(models.first)
        #expect(models.count == 1)
        #expect(set.memberNames == ["org/alone", "org/other"])
        #expect(set.primary.lastPathComponent == "models--org--alone")
        #expect(Set(set.exclusive.map(\.lastPathComponent)) == [
            "models--org--other",
            "a5only", "a5only.refs", "a5only.lock",
            "b7both", "b7both.refs", "b7both.lock"
        ])
        // `c9lost` has no record of who uses it, so it is nobody's to remove.
        #expect(set.sharedBytes >= Int64(3 * mb) && set.sharedBytes < Int64(4 * mb))
    }

    @Test("a classic hub repository keeps its own blobs, so the folder is the model")
    func hubClassicLayout() throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/huggingface/hub/models--org--classic/blobs/deadbeef", bytes: 4 * mb)
        try sandbox.link(".cache/huggingface/hub/models--org--classic/snapshots/rev/model.bin",
                         to: "../../blobs/deadbeef")
        try sandbox.file(".cache/huggingface/hub/datasets--org--corpus/blobs/feed", bytes: mb)

        let models = LocalModelStores.huggingFace(home: sandbox.home)

        #expect(models.map(\.name) == ["dataset org/corpus", "org/classic"])
        #expect(models.allSatisfy { $0.exclusive.isEmpty && $0.sharedBytes == 0 })
    }

    @Test("LM Studio models are publisher/repository folders, in either store")
    func lmStudioFolders() throws {
        let sandbox = try Sandbox()
        try sandbox.file(".lmstudio/models/lmstudio-community/Qwen-GGUF/q4.gguf", bytes: 5 * mb)
        try sandbox.file(".cache/lm-studio/models/TheBloke/Old-GGUF/q5.gguf", bytes: 3 * mb)

        let models = LocalModelStores.lmStudio(home: sandbox.home)

        #expect(models.map(\.name) == ["TheBloke/Old-GGUF", "lmstudio-community/Qwen-GGUF"])
    }

    @Test("An excluded Hugging Face repository keeps shared files and its sibling available")
    func excludedHubRepositoryKeepsSharedBlobs() async throws {
        let sandbox = try Sandbox()
        try sandbox.hubSharedBlob("a5both", bytes: 4 * mb,
            usedBy: ["models--org--keep", "models--org--other"])
        let kept = sandbox.home.appendingPathComponent(".cache/huggingface/hub/models--org--keep")
        let models = LocalModelStores.all(home: sandbox.home, context: ScanContext(excludedPaths: [kept.path]))
        let remaining = try #require(models.first)
        #expect(models.count == 1)
        #expect(remaining.name == "org/other")
        #expect(remaining.exclusive.isEmpty)
        #expect(remaining.sharedBytes >= Int64(4 * mb))
    }

    // MARK: - In the scan

    @Test("AI model stores remain separate from generic caches")
    func modelStoresStayOutsideGenericCaches() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".ollama/models/blobs/sha256-weights", bytes: 8 * mb)
        try sandbox.file(".ollama/models/blobs/sha256-cfg", bytes: 4096)
        try sandbox.ollamaManifest("registry.ollama.ai/library/gemma3/4b", config: "cfg", layers: ["weights"])
        try sandbox.file(".ollama/id_ed25519", bytes: 400)
        try sandbox.hubSharedBlob("a5only", bytes: 5 * mb, usedBy: ["models--org--alone"])
        try sandbox.hubSharedBlob("b7both", bytes: 7 * mb,
                                  usedBy: ["models--org--alone", "models--org--other"])
        try sandbox.file(".cache/huggingface/xet/chunks.bin", bytes: 2 * mb)
        try sandbox.file(".cache/sometool/blob", bytes: 2 * mb)

        let ai = try await scanner(sandbox).scan(context: ScanContext())
        let system = try await SystemCachesScanner(
            cachesRoot: sandbox.home.appendingPathComponent("Library/Caches"),
            logsRoot: sandbox.home.appendingPathComponent("Library/Logs"),
            dotCacheRoot: sandbox.home.appendingPathComponent(".cache")
        ).scan(context: ScanContext())

        let ollama = try #require(ai.entries.first { $0.aiTool == .ollama })
        #expect(ollama.displayName == "Ollama models")
        #expect(ollama.totalBytesIncludingChildren >= Int64(8 * mb))
        #expect(!ollama.isRegenerable && ollama.isRemovalLocked)
        #expect(ollama.protectionReason == .inventory)
        #expect(ollama.children.isEmpty)

        // The two repositories share seven megabytes, so they are one row and the
        // twelve go together. Apart, neither could have removed the seven.
        let set = try #require(ai.entries.first { $0.displayName == "org/alone + org/other" })
        #expect(set.totalBytesIncludingChildren >= Int64(12 * mb))
        #expect(set.parentDisplay.hasPrefix("2 Hugging Face models that share their weights"))
        #expect(set.removesAsUnit)

        let offered = (ai.entries + system.entries).flatMap { [$0] + $0.children }.map(\.url.path)
        #expect(!offered.contains { $0.hasSuffix("/.ollama") || $0.hasSuffix("id_ed25519") })
        #expect(!offered.contains { $0.hasSuffix("/.cache/huggingface") })
        #expect(offered.filter { $0.hasSuffix("b7both") }.count == 1, "offered once, by the set")
        #expect(ai.entries.contains { $0.url.lastPathComponent == "xet" })
        #expect(system.entries.map(\.url.lastPathComponent) == ["sometool"])
        #expect(ai.safeToRemoveBytes == 0)
    }

    // MARK: - Shared ownership and runtime use

    /// Replaces `lsof` with the given open files, keyed by `FileIdentity`.
    private func scanner(_ sandbox: Sandbox, open: [String: Set<String>] = [:],
                         issue: String? = nil) -> AIToolsScanner {
        var scanner = AIToolsScanner(home: sandbox.home)
        scanner.captureModelActivity = { WorktreeActivity(roots: $0, processes: open, issue: issue) }
        return scanner
    }

    private func modelRow(_ result: ScanCategoryResult, _ name: String) throws -> FileEntry {
        try #require(result.entries.first { $0.displayName == name })
    }

    @Test("LM Studio symbolic imports protect the Hugging Face files they use")
    func lmStudioSymbolicImportsProtectHubFiles() async throws {
        let sandbox = try Sandbox()
        // Classic layout: the snapshot links to a blob inside the repository.
        try sandbox.file(".cache/huggingface/hub/models--Qwen--classic/blobs/9217", bytes: 4 * mb)
        try sandbox.link(".cache/huggingface/hub/models--Qwen--classic/snapshots/rev/q4.gguf",
                         to: "../../blobs/9217")
        // Shared layout: the repository links to a blob in `hub/blobs`.
        try sandbox.hubSharedBlob("a5shared", bytes: 3 * mb, usedBy: ["models--Qwen--shared"])
        try sandbox.hubSharedBlob("b7free", bytes: 2 * mb, usedBy: ["models--org--unlinked"])
        let hub = sandbox.home.appendingPathComponent(".cache/huggingface/hub")
        try sandbox.link(".lmstudio/models/test/classic/q4.gguf",
                         to: hub.appendingPathComponent("models--Qwen--classic/snapshots/rev/q4.gguf").path)
        try sandbox.link(".lmstudio/models/test/shared/q4.gguf",
                         to: hub.appendingPathComponent("models--Qwen--shared/blobs/link-a5shared").path)

        let result = try await scanner(sandbox).scan(context: ScanContext())

        for name in ["Qwen/classic", "Qwen/shared"] {
            let row = try modelRow(result, name)
            #expect(row.protectionReason == .inventory && row.isRemovalLocked)
            #expect(row.protectionExplanation?.contains("LM Studio model links to these files") == true)
        }
        #expect(try modelRow(result, "org/unlinked").protectionReason == nil)
    }

    @Test("LM Studio links inside directory links protect Hugging Face files")
    func directoryLinkedDefaultLMStudioStoreProtectsHubFiles() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/huggingface/hub/models--Qwen--model/blobs/9217", bytes: 4 * mb)
        try sandbox.link(".cache/huggingface/hub/models--Qwen--model/snapshots/rev/q4.gguf",
                         to: "../../blobs/9217")
        let shared = sandbox.home.appendingPathComponent("Shared/models")
        try sandbox.link("Shared/models/test/qwen/q4.gguf", to: sandbox.home
            .appendingPathComponent(".cache/huggingface/hub/models--Qwen--model/snapshots/rev/q4.gguf").path)
        // A cycle must not stop the scan.
        try sandbox.link("Shared/models/loop", to: shared.path)
        try FileManager.default.createDirectory(at: sandbox.home.appendingPathComponent(".lmstudio"),
                                                withIntermediateDirectories: true)
        try sandbox.link(".lmstudio/models", to: shared.path)

        let row = try modelRow(try await scanner(sandbox).scan(context: ScanContext()), "Qwen/model")

        #expect(row.protectionReason == .inventory)
        #expect(row.protectionExplanation?.contains("LM Studio model links to these files") == true)
        #expect(LocalModelStores.lmStudioLinks(home: sandbox.home).isComplete)
        #expect(!LocalModelStores.lmStudioLinks(home: sandbox.home, entryLimit: 1).isComplete)
    }

    @Test("A link target that cannot be checked protects the model")
    func uncheckedLinkTargetProtectsTheModel() async throws {
        let sandbox = try Sandbox()
        let target = try sandbox.file("Private/weights/q4.gguf", bytes: 2 * mb)
        try sandbox.file(".lmstudio/models/test/denied/model.json", bytes: 4096)
        try sandbox.link(".lmstudio/models/test/denied/q4.gguf", to: target.path)
        try sandbox.file(".lmstudio/models/test/broken/model.json", bytes: 4096)
        try sandbox.link(".lmstudio/models/test/broken/q4.gguf", to: sandbox.home.appendingPathComponent("Missing/q4.gguf").path)
        let open = [FileIdentity.of(target)!: Set(["llmster"])]
        let parent = target.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        let result = try await scanner(sandbox, open: open).scan(context: ScanContext())

        let denied = try modelRow(result, "test/denied")
        #expect(denied.protectionReason == .inventory)
        #expect(denied.protectionExplanation == "Open files could not be checked. Scan again before removal.")
        #expect(try modelRow(result, "test/broken").protectionReason == nil)
    }

    @Test("Unreadable LM Studio folders protect Hugging Face models")
    func unreadableLMStudioLinksProtectHubModels() async throws {
        let sandbox = try Sandbox()
        try sandbox.hubSharedBlob("a5only", bytes: 2 * mb, usedBy: ["models--org--model"])
        let locked = try sandbox.file(".lmstudio/models/test/locked/q4.gguf").deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let row = try modelRow(try await scanner(sandbox).scan(context: ScanContext()), "org/model")

        #expect(row.protectionReason == .inventory)
        #expect(row.protectionExplanation?.contains("could not read all LM Studio links") == true)
    }

    @Test("Open model files and their link targets protect the model")
    func openModelFilesProtectTheModel() async throws {
        let sandbox = try Sandbox()
        let copy = try sandbox.file(".lmstudio/models/test/copy/q4.gguf", bytes: 2 * mb)
        let outside = try sandbox.file("Downloads/q4.gguf", bytes: 2 * mb)
        try sandbox.file(".lmstudio/models/test/linked/model.json", bytes: 4096)
        try sandbox.link(".lmstudio/models/test/linked/q4.gguf", to: outside.path)
        try sandbox.file(".lmstudio/models/test/idle/q4.gguf", bytes: 2 * mb)
        let open = [FileIdentity.of(copy)!: Set(["llmster"]), FileIdentity.of(outside)!: Set(["llmster"])]

        let loaded = try await scanner(sandbox, open: open).scan(context: ScanContext())

        for name in ["test/copy", "test/linked"] {
            let row = try modelRow(loaded, name)
            #expect(row.protectionReason == .running)
            #expect(row.protectionExplanation?.contains("llmster") == true)
        }
        #expect(try modelRow(loaded, "test/idle").protectionReason == nil)

        let unchecked = try await scanner(sandbox, issue: "Incomplete process information.").scan(context: ScanContext())
        let row = try modelRow(unchecked, "test/idle")
        #expect(row.protectionReason == .inventory)
        #expect(row.protectionExplanation == "Open files could not be checked. Scan again before removal.")
    }

    @Test("Hard-linked imports are protected and counted once")
    func hardLinkedImportsCountOnce() async throws {
        let sandbox = try Sandbox()
        let blob = try sandbox.file(".cache/huggingface/hub/models--Qwen--model/blobs/9217", bytes: 4 * mb)
        let imported = sandbox.home.appendingPathComponent(".lmstudio/models/test/model/q4.gguf")
        try FileManager.default.createDirectory(at: imported.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: blob, to: imported)

        let result = try await scanner(sandbox).scan(context: ScanContext())

        let hub = try modelRow(result, "Qwen/model")
        let lmStudio = try modelRow(result, "test/model")
        for row in [hub, lmStudio] {
            #expect(row.protectionReason == .inventory)
            #expect(row.protectionExplanation?.contains("hard links") == true)
        }
        let blobBytes = try await ScanContext().measurer.measure(blob).allocatedBytes
        #expect(hub.displayBytes == blobBytes)
        #expect(lmStudio.displayBytes == 0)
        #expect(result.totalBytes < 2 * blobBytes)
    }
}
