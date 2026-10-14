import Foundation
import MoppoCore

/// Keeps related storage rows together without changing their identities or removal rules.
struct FileTableGroup: Identifiable {
    enum ID: Hashable {
        case application(AIStorageSection.Owner)
        case entry(FileEntry.ID)
    }

    let id: ID
    let owner: AIStorageSection.Owner?
    var entries: [FileEntry]
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.rowDisplayBytes } }

    func visibleEntries(expandedOwners: Set<AIStorageSection.Owner>) -> [FileEntry] {
        guard let owner else { return entries }
        return expandedOwners.contains(owner) ? entries : []
    }

    static func make(
        from entries: [FileEntry], sortKey: FileTable.SortKey, ascending: Bool
    ) -> [FileTableGroup] {
        var groups: [FileTableGroup] = []
        var positions: [AIStorageSection.Owner: Int] = [:]
        for entry in entries {
            if let owner = entry.aiStorageSection?.owner {
                if let index = positions[owner] {
                    groups[index].entries.append(entry)
                } else {
                    positions[owner] = groups.count
                    groups.append(.init(id: .application(owner), owner: owner, entries: [entry]))
                }
            } else {
                groups.append(.init(id: .entry(entry.id), owner: nil, entries: [entry]))
            }
        }
        guard !positions.isEmpty else { return groups }
        return groups.sorted { lhs, rhs in
            switch sortKey {
            case .name:
                let order = lhs.name.localizedStandardCompare(rhs.name)
                return ascending ? order == .orderedAscending : order == .orderedDescending
            case .size:
                if lhs.totalBytes != rhs.totalBytes {
                    return ascending ? lhs.totalBytes < rhs.totalBytes : lhs.totalBytes > rhs.totalBytes
                }
            case .lastOpened:
                let left = lhs.entries.compactMap(\.lastOpened).max() ?? .distantPast
                let right = rhs.entries.compactMap(\.lastOpened).max() ?? .distantPast
                if left != right { return ascending ? left < right : left > right }
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private var name: String { owner?.rawValue ?? entries[0].displayName }
}
