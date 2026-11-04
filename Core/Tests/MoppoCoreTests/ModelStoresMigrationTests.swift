import Testing
@testable import MoppoCore

/// The generated model store claims and editor table equal the sets that the Swift files held before #352.
/// This test leaves with the old sets, after the pull request records that it passed.
@Suite("Model stores migration")
struct ModelStoresMigrationTests {
    private typealias Editor = EditorExtensionStores.Editor

    /// Home-relative folders these readers speak for. Whoever lists dot-folders or
    /// `~/.cache` whole must leave them alone, or the same bytes are offered twice —
    /// and `~/.ollama` whole would offer the user's `id_ed25519` with the models.
    private static let homeDotFolders: Set<String> = [".ollama", ".lmstudio"]
    private static let dotCacheFolders: Set<String> = ["huggingface", "lm-studio", "whisper"]

    /// Home-relative folders that these readers claim only in part, with the claimed child names.
    /// A category that lists such a folder lists its other children instead.
    /// `~/.cache/torch` also holds compiler caches, and `~/.keras` holds `keras.json` settings.
    private static let partlyClaimedFolders: [String: Set<String>] = [
        ".cache/torch": ["hub"],
        ".keras": ["models", "datasets"]
    ]


    private static let oldLMStudioStores = [".lmstudio/models", ".cache/lm-studio/models"]
    private static let oldGPT4AllStore = "Library/Application Support/nomic.ai/GPT4All"

    private     static let oldEditors: [Editor] = [
        Editor(name: "Visual Studio Code", dotFolder: ".vscode",
               bundleIdentifier: "com.microsoft.VSCode"),
        Editor(name: "VS Code Insiders", dotFolder: ".vscode-insiders",
               bundleIdentifier: "com.microsoft.VSCodeInsiders"),
        Editor(name: "VSCodium", dotFolder: ".vscode-oss", bundleIdentifier: "com.vscodium"),
        Editor(name: "Cursor", dotFolder: ".cursor",
               bundleIdentifier: "com.todesktop.230313mzl4w4u92"),
        Editor(name: "Windsurf", dotFolder: ".windsurf",
               bundleIdentifier: "com.exafunction.windsurf"),
    ]

    @Test("the generated claim sets equal the old sets")
    func generatedClaimsEqualOldSets() {
        #expect(LocalModelStores.homeDotFolders == Self.homeDotFolders)
        #expect(LocalModelStores.dotCacheFolders == Self.dotCacheFolders)
        #expect(LocalModelStores.partlyClaimedFolders == Self.partlyClaimedFolders)
    }

    @Test("the generated store paths equal the paths the readers used")
    func generatedStoresEqualOldPaths() {
        #expect(LocalModelStores.lmStudioStores.map { $0 + "/models" } == Self.oldLMStudioStores)
        #expect(LocalModelStores.gpt4AllStores == [Self.oldGPT4AllStore])
        #expect(LocalModelStores.huggingFaceStores == [".cache/huggingface"])
        #expect(LocalModelStores.pyTorchHubStores == [".cache/torch/hub"])
        #expect(LocalModelStores.whisperStores == [".cache/whisper"])
        #expect(LocalModelStores.kerasStores == [".keras/models", ".keras/datasets"])
    }

    @Test("the generated editors equal the old table")
    func generatedEditorsEqualOldTable() {
        #expect(EditorExtensionStores.editors == Self.oldEditors)
    }
}
