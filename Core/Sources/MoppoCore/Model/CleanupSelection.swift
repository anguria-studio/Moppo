import Foundation

/// Limits a cleanup action to the items in its review group.
public enum CleanupSelection {
    public enum Scope: Sendable {
        case all, safe
    }

    public static func ids(
        in categories: [ScanCategoryResult],
        selected: Set<FileEntry.ID>,
        scope: Scope
    ) -> Set<FileEntry.ID> {
        let roots = categories.flatMap(\.entries)
        let entries = roots + roots.flatMap(\.children)
        let known = Set(entries.filter {
            $0.kind != .appBundle && $0.protectionReason != .inventory && $0.protectionReason != .folderRemainder
                && $0.unlockableChildren.isEmpty
        }.map(\.id))
        let safeRows = categories.flatMap { $0.tileRows(safeToRemove: true) }
        let safeEntries = safeRows + safeRows.flatMap(\.children).filter(\.regeneratesSafely)
        let safe = Set(safeEntries
            .filter { !$0.isRemovalLocked && $0.kind != .appBundle && $0.removalAction == nil }
            .map(\.id))
        let allowed: Set<FileEntry.ID>
        switch scope {
        case .all: allowed = known
        case .safe: allowed = safe
        }
        var result = selected.intersection(allowed).intersection(known)
        // A selected parent already includes its children.
        let covered = entries.filter { result.contains($0.id) }.flatMap(\.children).map(\.id)
        result.subtract(covered)
        return result
    }
}
