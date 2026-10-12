import Foundation

/// Records the session files covered by an explicit deletion review.
public struct CodexSessionReview: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public let threadID: String
        public let url: URL
        public let identity: String
        public let modifiedAt: Date
        public let fileSize: Int

        public init(threadID: String, url: URL, identity: String, modifiedAt: Date, fileSize: Int) {
            self.threadID = threadID
            self.url = url
            self.identity = identity
            self.modifiedAt = modifiedAt
            self.fileSize = fileSize
        }
    }

    public let codexHome: URL
    public let threadID: String
    public let members: [Member]

    public init(codexHome: URL, threadID: String, members: [Member]) {
        self.codexHome = codexHome
        self.threadID = threadID
        self.members = members
    }

    public var warning: String {
        let children = members.count - 1
        let scope = children > 0
            ? " This also deletes \(children) child \(children == 1 ? "session" : "sessions")." : ""
        return "Codex permanently deletes the selected conversation history and related session files."
            + scope + " This deletion does not use the Trash and cannot be undone."
    }
}
