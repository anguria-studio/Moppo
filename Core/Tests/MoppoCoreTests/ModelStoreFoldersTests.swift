import Foundation
import Testing
@testable import MoppoCore

/// Checks the model store folders that variables such as `OLLAMA_MODELS` and `HF_HOME` set.
@Suite("Model store folders")
struct ModelStoreFoldersTests {
    /// A home folder and a folder outside it. Both have link-free paths, so the link check applies to the fixtures only.
    private final class Sandbox {
        let root: URL
        let home: URL
        let outside: URL

        init() throws {
            // `resolvingSymlinksInPath` keeps `/var`, which is a link to `/private/var`.
            let temporary = FileManager.default.temporaryDirectory.path
            let real = realpath(temporary, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? temporary
            root = URL(fileURLWithPath: real, isDirectory: true)
                .appendingPathComponent("moppo-stores-\(UUID().uuidString)", isDirectory: true)
            home = root.appendingPathComponent("home", isDirectory: true)
            outside = root.appendingPathComponent("disk", isDirectory: true)
            for folder in [home, outside] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }
        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func file(_ path: String, in base: URL? = nil, bytes: Int = 1024 * 1024) throws -> URL {
            let url = (base ?? home).appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0x41, count: bytes).write(to: url)
            return url
        }

        func path(_ relative: String) -> String { home.appendingPathComponent(relative).path }

        /// A Hugging Face model repository in the classic layout.
        func hubModel(_ hub: String, repository: String = "models--org--model") throws {
            try file("\(hub)/\(repository)/blobs/weights")
        }

        func folders(_ environment: [String: String]) -> ModelStoreFolders {
            ModelStoreFolders(home: home, environment: environment)
        }
    }

    @Test("The first Hugging Face variable with a value sets the hub",
          arguments: ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "HF_HOME", "XDG_CACHE_HOME"])
    func hubVariablePrecedence(winner: String) throws {
        let sandbox = try Sandbox()
        let hubs = ["HF_HUB_CACHE": "a", "HUGGINGFACE_HUB_CACHE": "b", "HF_HOME": "c/hub", "XDG_CACHE_HOME": "d/huggingface/hub"]
        for hub in hubs.values { try sandbox.hubModel("stores/" + hub) }
        let order = ["HF_HUB_CACHE", "HUGGINGFACE_HUB_CACHE", "HF_HOME", "XDG_CACHE_HOME"]
        // The winner and each variable after it have a value.
        let set = order.drop { $0 != winner }
        var environment: [String: String] = [:]
        for name in set { environment[name] = sandbox.path("stores/" + String(hubs[name]!.prefix(1))) }

        let found = sandbox.folders(environment).custom["huggingFaceHub"] ?? []
        #expect(found.map(\.url.path) == [sandbox.path("stores/" + hubs[winner]!)])
        #expect(found.first?.variable == winner)
        #expect(found.first?.isOutsideHome == false)
    }

    @Test("A tool that expands ~ gets the home folder, and Ollama values lose spaces and quotes")
    func valueSpelling() throws {
        let sandbox = try Sandbox()
        try sandbox.hubModel("models/hf/hub")
        try sandbox.file("models/ollama/manifests/registry.ollama.ai/library/qwen3/0.6b")
        let found = sandbox.folders([
            "HF_HOME": "~/models/hf",
            "OLLAMA_MODELS": "  \"\(sandbox.path("models/ollama"))\" "
        ])
        #expect(found.custom["huggingFaceHub"]?.map(\.url.path) == [sandbox.path("models/hf/hub")])
        #expect(found.custom["ollama"]?.map(\.url.path) == [sandbox.path("models/ollama")])
        // Ollama does not expand ~, so the value names a folder relative to where Ollama starts.
        #expect(sandbox.folders(["OLLAMA_MODELS": "~/models/ollama"]).custom.isEmpty)
    }

    @Test("A value that cannot identify a store gives no custom folder", arguments: [
        "relative", "home", "root", "above home", "documents", "dot cache", "system", "no layout",
        "link", "other tool", "inside an AI root", "default"
    ])
    func rejectedValues(_ value: String) throws {
        let sandbox = try Sandbox()
        // Each folder holds a hub layout, so only the check under test can refuse it.
        for folder in ["", "Documents", ".cache", ".lmstudio/hf", ".codex/hf", ".cache/huggingface/hub", "real"] {
            try sandbox.hubModel(folder)
        }
        try sandbox.file(".codex/config.toml")
        try sandbox.file("empty/readme.md")
        try FileManager.default.createSymbolicLink(
            at: sandbox.home.appendingPathComponent("linked"), withDestinationURL: sandbox.home.appendingPathComponent("real"))
        let values = [
            "relative": "hf", "home": sandbox.home.path, "root": "/", "above home": sandbox.root.path,
            "documents": sandbox.path("Documents"), "dot cache": sandbox.path(".cache"), "system": "/Library/hf",
            "no layout": sandbox.path("empty"), "link": sandbox.path("linked"), "other tool": sandbox.path(".lmstudio/hf"),
            "inside an AI root": sandbox.path(".codex/hf"), "default": sandbox.path(".cache/huggingface")
        ]
        let found = sandbox.folders(["HF_HUB_CACHE": values[value]!])
        #expect(found.custom.isEmpty, "\(value)")
        #expect(found.claimedPaths.isEmpty)
    }

    @Test("A store outside the home folder is marked, and two tools that overlap are not read")
    func outsideAndOverlap() throws {
        let sandbox = try Sandbox()
        try sandbox.file("ollama/manifests/model", in: sandbox.outside)
        try sandbox.file("hub/models--org--model/blobs/weights", in: sandbox.outside)

        let alone = sandbox.folders(["OLLAMA_MODELS": sandbox.outside.appendingPathComponent("ollama").path])
        let folder = try #require(alone.custom["ollama"]?.first)
        #expect(folder.isOutsideHome)
        #expect(alone.claimedPaths == [folder.url.path])

        let overlapping = sandbox.folders([
            "HF_HOME": sandbox.outside.path,
            "OLLAMA_MODELS": sandbox.outside.appendingPathComponent("ollama").path
        ])
        // The Hugging Face home contains the Ollama folder. Its hub overlaps no other tool.
        #expect(overlapping.custom["ollama"] == nil)
        #expect(overlapping.custom["huggingFace"] == nil)
        #expect(overlapping.custom["huggingFaceHub"]?.map(\.url.path) == [sandbox.outside.appendingPathComponent("hub").path])
    }

    @Test("A process variable wins over launchctl, and an empty launchctl value is not set")
    func environmentSources() async {
        let asked = Asked()
        let values = await LocalModelStores.environment(
            process: ["HF_HOME": "/process", "PATH": "/usr/bin"],
            launchd: { name in
                await asked.add(name)
                return ["OLLAMA_MODELS": "/launchd", "TORCH_HOME": ""][name]
            })
        #expect(values == ["HF_HOME": "/process", "OLLAMA_MODELS": "/launchd"])
        #expect(await !asked.names.contains("HF_HOME"))
        #expect(await asked.names.count == LocalModelStores.locationVariables.count - 1)
    }

    private actor Asked {
        var names: [String] = []
        func add(_ name: String) { names.append(name) }
    }

    @Test("AI Tools shows models in custom stores and claims the folders")
    func scannerRows() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("models/ollama/manifests/registry.ollama.ai/library/qwen3/0.6b")
        try sandbox.file("models/ollama/blobs/sha256-weights")
        try sandbox.file(".ollama/models/manifests/registry.ollama.ai/library/old/latest")
        try sandbox.hubModel("models/hf/hub")
        try sandbox.file("models/hf/xet/chunk")
        try sandbox.file("hub/checkpoints/resnet.pth", in: sandbox.outside)
        let environment = [
            "OLLAMA_MODELS": sandbox.path("models/ollama"),
            "HF_HOME": sandbox.path("models/hf"),
            "TORCH_HOME": sandbox.outside.path
        ]
        var scanner = AIToolsScanner(home: sandbox.home)
        scanner.captureModelActivity = { WorktreeActivity(roots: $0, processes: [:], issue: nil) }
        let result = try await scanner.scan(context: ScanContext(environment: environment))

        let ollama = result.entries.filter { $0.aiTool == .ollama }
        #expect(Set(ollama.map(\.url.path)) == [sandbox.path(".ollama/models"), sandbox.path("models/ollama")])
        #expect(ollama.allSatisfy { $0.protectionReason == .inventory })
        #expect(ollama.contains { $0.parentDisplay.hasPrefix("Set by OLLAMA_MODELS") })

        let model = try #require(result.entries.first { $0.url.path == sandbox.path("models/hf/hub/models--org--model") })
        #expect(model.protectionReason == nil)
        #expect(model.parentDisplay.hasSuffix("set by HF_HOME"))
        let xet = try #require(result.entries.first { $0.url.path == sandbox.path("models/hf/xet") },
                               "\(result.entries.map { $0.url.path })")
        #expect(xet.protectionReason == .inventory)

        // The torch home is outside the home folder, so its weights stay protected.
        let weights = try #require(result.entries.first { $0.displayName == "resnet.pth" })
        #expect(weights.protectionReason == .inventory)
        #expect(weights.protectionExplanation?.contains("outside your home folder") == true)

        let claimed = Set(result.claimedStoragePaths)
        #expect(claimed.isSuperset(of: [sandbox.path("models/ollama"), sandbox.path("models/hf"),
                                        sandbox.path("models/hf/hub"), sandbox.outside.appendingPathComponent("hub").path]))
    }

    @Test("An LM Studio link into a custom hub keeps the Hugging Face model protected")
    func lmStudioLinkIntoCustomHub() async throws {
        let sandbox = try Sandbox()
        try sandbox.hubModel("models/hf/hub")
        let weights = sandbox.home.appendingPathComponent("models/hf/hub/models--org--model/blobs/weights")
        let link = sandbox.home.appendingPathComponent(".lmstudio/models/org/model/weights.gguf")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: weights)
        var scanner = AIToolsScanner(home: sandbox.home)
        scanner.captureModelActivity = { WorktreeActivity(roots: $0, processes: [:], issue: nil) }
        let result = try await scanner.scan(context: ScanContext(environment: ["HF_HOME": sandbox.path("models/hf")]))
        let model = try #require(result.entries.first { $0.url.path == sandbox.path("models/hf/hub/models--org--model") })
        #expect(model.protectionReason == .inventory)
        #expect(model.protectionExplanation?.contains("LM Studio") == true)
    }

    @Test("The archive sweep in Hidden & System Data skips a custom store")
    func archiveSweepSkipsCustomStore() async throws {
        let sandbox = try Sandbox()
        try sandbox.file("models/ollama/manifests/registry.ollama.ai/library/qwen3/0.6b")
        try sandbox.file("models/ollama/blobs/export.zip", bytes: 260 * 1024 * 1024)
        let scanner = HiddenDataScanner(home: sandbox.home)
        let unclaimed = try await scanner.scan(context: ScanContext())
        #expect(unclaimed.entries.contains { $0.url.lastPathComponent == "export.zip" })
        let claimed = try await scanner.scan(context: ScanContext(environment: ["OLLAMA_MODELS": sandbox.path("models/ollama")]))
        #expect(!claimed.entries.contains { $0.url.lastPathComponent == "export.zip" })
    }

    @Test("A hub that a variable moves inside the default Hugging Face folder is not listed twice")
    func hubInsideDefaultHome() async throws {
        let sandbox = try Sandbox()
        try sandbox.hubModel(".cache/huggingface/hub2")
        try sandbox.file(".cache/huggingface/token", bytes: 64)
        var scanner = AIToolsScanner(home: sandbox.home)
        scanner.captureModelActivity = { WorktreeActivity(roots: $0, processes: [:], issue: nil) }
        let result = try await scanner.scan(context: ScanContext(
            environment: ["HF_HUB_CACHE": sandbox.path(".cache/huggingface/hub2")]))
        let paths = result.entries.filter { $0.aiTool == .huggingFace }.map(\.url.path)
        #expect(Set(paths) == [sandbox.path(".cache/huggingface/hub2/models--org--model"), sandbox.path(".cache/huggingface/token")],
                "\(paths)")
    }
}
