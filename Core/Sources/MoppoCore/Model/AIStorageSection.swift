import Foundation

/// Describes a storage section without adding a removal target.
public struct AIStorageSection: Sendable, Equatable {
    // `Owner` is in `Generated/ToolRules.swift`. Each case comes from a tool file in `rules/`.

    public let owner: Owner
    let titleText: EngineText
    let summaryText: EngineText
    public var title: String { titleText.english }
    public var summary: String { summaryText.english }
    public var localizedTitle: String { titleText.localized }
    public var localizedSummary: String { summaryText.localized }

    public init(owner: Owner, title: String, summary: String) {
        self.init(owner: owner, titleText: .verbatim(title), summaryText: .verbatim(summary))
    }

    init(owner: Owner, titleText: EngineText, summaryText: EngineText) {
        self.owner = owner
        self.titleText = titleText
        self.summaryText = summaryText
    }
}
