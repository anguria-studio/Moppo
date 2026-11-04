import Foundation

/// Describes a storage section without adding a removal target.
public struct AIStorageSection: Sendable, Equatable {
    // `Owner` is in `Generated/ToolRules.swift`. Each case comes from a tool file in `rules/`.

    public let owner: Owner
    public let title: String
    public let summary: String

    public init(owner: Owner, title: String, summary: String) {
        self.owner = owner
        self.title = title
        self.summary = summary
    }
}
