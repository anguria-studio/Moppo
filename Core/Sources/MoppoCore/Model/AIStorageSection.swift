import Foundation

/// Describes a storage section without adding a removal target.
public struct AIStorageSection: Sendable, Equatable {
    public enum Owner: String, Sendable {
        case codex = "Codex"
        case chatGPT = "ChatGPT"
        case claudeCode = "Claude Code"
        case claude = "Claude"
        case cursor = "Cursor"
        case grokBot = "Grok Bot"
        case ollama = "Ollama"
        case huggingFace = "Hugging Face"
        case lmStudio = "LM Studio"

        public var tool: FileEntry.AITool {
            switch self {
            case .codex: .codex
            case .chatGPT: .chatGPT
            case .claudeCode, .claude: .claude
            case .cursor: .cursor
            case .grokBot: .grokBot
            case .ollama: .ollama
            case .huggingFace: .huggingFace
            case .lmStudio: .lmStudio
            }
        }
    }

    public let owner: Owner
    public let title: String
    public let summary: String

    public init(owner: Owner, title: String, summary: String) {
        self.owner = owner
        self.title = title
        self.summary = summary
    }
}
