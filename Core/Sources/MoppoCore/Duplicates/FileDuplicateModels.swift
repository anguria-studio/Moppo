import Foundation

/// One file in a content-verified duplicate set.
public struct DuplicateFile: Sendable, Equatable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let logicalBytes: Int64
    public let allocatedBytes: Int64
    public let creationDate: Date?
    public let modificationDate: Date?
    let plannedIdentity: String?

    public init(
        url: URL,
        logicalBytes: Int64,
        allocatedBytes: Int64,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.url = url.standardizedFileURL
        self.logicalBytes = logicalBytes
        self.allocatedBytes = allocatedBytes
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.plannedIdentity = FileIdentity.of(url)
    }
}

/// Selects the copy that stays in each verified file group.
public enum DuplicateKeeperRule: Sendable, Equatable, Codable {
    case oldest
    case newest
    case shortestPath
    case inFolder(URL)
}

/// Files that matched by size, sampled hash, full hash, and byte comparison.
public struct FileDuplicateGroup: Sendable, Equatable, Identifiable {
    /// Why this copy is the one that stays. Said only when it is true: Finder's
    /// Duplicate and `cp` preserve creation dates, so ties are ordinary, and a
    /// copy that merely sorted first by path is not "the oldest".
    public enum KeeperReason: String, Sendable, Equatable {
        case oldestCopy
        case newestCopy
        case shortestPath
        case inSelectedFolder
        case firstByName
        case chosenByUser

        public var label: String {
            switch self {
            case .oldestCopy:   "oldest copy"
            case .newestCopy:   "newest copy"
            case .shortestPath: "shortest path"
            case .inSelectedFolder: "in selected folder"
            case .firstByName:  "first by name"
            case .chosenByUser: "you chose this"
            }
        }
    }

    public let id: String
    public let keeper: DuplicateFile
    public let keeperReason: KeeperReason
    public let removable: [DuplicateFile]
    let contentDigest: String

    init(
        id: String,
        keeper: DuplicateFile,
        keeperReason: KeeperReason = .oldestCopy,
        removable: [DuplicateFile],
        contentDigest: String
    ) {
        self.id = id
        self.keeper = keeper
        self.keeperReason = keeperReason
        self.removable = removable
        self.contentDigest = contentDigest
    }

    public var files: [DuplicateFile] { [keeper] + removable }
    public var count: Int { removable.count + 1 }

    /// Applies a shared rule. Keeps the user's choice.
    public func applying(_ rule: DuplicateKeeperRule) -> FileDuplicateGroup {
        guard keeperReason != .chosenByUser else { return self }
        let (ordered, reason) = DuplicateKeeperOrder.order(files, by: rule)
        return FileDuplicateGroup(
            id: id, keeper: ordered[0], keeperReason: reason,
            removable: Array(ordered.dropFirst()), contentDigest: contentDigest
        )
    }

    /// The best available upper bound on space recovered by removing every copy.
    public var reclaimableBytes: Int64 {
        removable.reduce(0) { $0 + $1.allocatedBytes }
    }

    /// Keeps another member and makes the former keeper removable.
    public func promoting(_ fileID: DuplicateFile.ID) -> FileDuplicateGroup? {
        guard fileID != keeper.id,
              let promoted = removable.first(where: { $0.id == fileID })
        else { return nil }

        let demoted = removable.map { $0.id == fileID ? keeper : $0 }
        return FileDuplicateGroup(
            id: id,
            keeper: promoted,
            keeperReason: .chosenByUser,
            removable: demoted,
            contentDigest: contentDigest
        )
    }

    /// Removes copies that left the disk. A group with no removable copy disappears.
    public func removingFiles(withIDs fileIDs: Set<DuplicateFile.ID>) -> FileDuplicateGroup? {
        let remaining = removable.filter { !fileIDs.contains($0.id) }
        guard !remaining.isEmpty else { return nil }
        return FileDuplicateGroup(
            id: id,
            keeper: keeper,
            keeperReason: keeperReason,
            removable: remaining,
            contentDigest: contentDigest
        )
    }
}

enum DuplicateKeeperOrder {
    static func order(
        _ files: [DuplicateFile], by rule: DuplicateKeeperRule
    ) -> ([DuplicateFile], FileDuplicateGroup.KeeperReason) {
        if case let .inFolder(folder) = rule {
            let path = folder.standardizedFileURL.path
            let prefix = path == "/" ? path : path + "/"
            let matching = files.filter { $0.url.standardizedFileURL.path.hasPrefix(prefix) }
            guard !matching.isEmpty, matching.count < files.count else { return order(files, by: .oldest) }
            let other = files.filter { !$0.url.standardizedFileURL.path.hasPrefix(prefix) }
            return (order(matching, by: .oldest).0 + order(other, by: .oldest).0, .inSelectedFolder)
        }

        let ordered = files.sorted { left, right in
            if rule == .shortestPath {
                let leftCount = left.url.pathComponents.count
                let rightCount = right.url.pathComponents.count
                if leftCount != rightCount { return leftCount < rightCount }
            } else {
                switch (left.creationDate, right.creationDate) {
                case let (left?, right?) where left != right:
                    return rule == .newest ? left > right : left < right
                case (nil, _?): return false
                case (_?, nil): return true
                default: break
                }
            }
            return left.url.path.localizedStandardCompare(right.url.path) == .orderedAscending
        }
        guard ordered.count > 1 else { return (ordered, .firstByName) }
        if rule == .shortestPath {
            return (ordered, ordered[0].url.pathComponents.count < ordered[1].url.pathComponents.count
                ? .shortestPath : .firstByName)
        }
        guard let first = ordered[0].creationDate, let second = ordered[1].creationDate,
              first != second else { return (ordered, .firstByName) }
        return (ordered, rule == .newest ? .newestCopy : .oldestCopy)
    }
}

/// The result of one selected-folder duplicate scan.
public struct FileDuplicateResults: Sendable, Equatable {
    public var groups: [FileDuplicateGroup]
    public let roots: [URL]
    public let examinedCount: Int
    public let eligibleCount: Int
    public let skippedCount: Int
    public let startedAt: Date
    public let finishedAt: Date

    public init(
        groups: [FileDuplicateGroup] = [],
        roots: [URL] = [],
        examinedCount: Int = 0,
        eligibleCount: Int = 0,
        skippedCount: Int = 0,
        startedAt: Date = Date(),
        finishedAt: Date = Date()
    ) {
        self.groups = groups
        self.roots = roots
        self.examinedCount = examinedCount
        self.eligibleCount = eligibleCount
        self.skippedCount = skippedCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    public var removableCount: Int {
        groups.reduce(0) { $0 + $1.removable.count }
    }

    public var reclaimableBytes: Int64 {
        groups.reduce(0) { $0 + $1.reclaimableBytes }
    }
}

/// The removal result and any scan data that became stale before removal.
public struct FileDuplicateRemovalOutcome: Sendable, Equatable {
    public let cleanup: CleanupOutcome
    public let staleFileIDs: Set<DuplicateFile.ID>
    public let staleGroupIDs: Set<FileDuplicateGroup.ID>

    init(
        cleanup: CleanupOutcome,
        staleFileIDs: Set<DuplicateFile.ID> = [],
        staleGroupIDs: Set<FileDuplicateGroup.ID> = []
    ) {
        self.cleanup = cleanup
        self.staleFileIDs = staleFileIDs
        self.staleGroupIDs = staleGroupIDs
    }
}
