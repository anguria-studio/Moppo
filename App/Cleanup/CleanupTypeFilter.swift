import MoppoCore

extension CleanupModel {
    struct TypeOption: Identifiable {
        let type: CleanupDataType
        let count: Int
        let bytes: Int64
        var id: CleanupDataType { type }
    }

    var dataTypeOptions: [TypeOption] {
        let categories = safetyFilteredCategories
        let entries = categories.flatMap(\.entries)
        return CleanupDataType.allCases.compactMap { type in
            if type == .all {
                return TypeOption(type: type, count: Set(entries.map(\.id)).count,
                    bytes: categories.reduce(0) { $0 + $1.totalBytes })
            }
            let rows = type.rows(in: entries)
            guard !rows.isEmpty else { return nil }
            return TypeOption(type: type, count: rows.count, bytes: rows.reduce(0) { $0 + $1.displayBytes })
        }
    }

    var visibleCategories: [ScanCategoryResult] {
        let categories = safetyFilteredCategories
        guard dataTypeFilter != .all else { return categories }
        return categories.compactMap { category in
            var copy = category
            copy.entries = dataTypeFilter.rows(in: category.entries)
            guard !copy.entries.isEmpty else { return nil }
            copy.totalBytes = copy.entries.reduce(0) { $0 + $1.displayBytes }
            return copy
        }
    }

    func resetUnavailableDataType() {
        if dataTypeFilter != .all, !dataTypeOptions.contains(where: { $0.type == dataTypeFilter }) {
            dataTypeFilter = .all
        }
    }

    func viewIDs(in rows: [FileEntry]) -> Set<FileEntry.ID> {
        Set((rows + rows.flatMap(\.children)).filter(dataTypeFilter.matches).map(\.id))
    }

    var idsInCurrentView: Set<FileEntry.ID> {
        viewIDs(in: visibleCategories.flatMap(\.entries))
    }

    var hiddenSelectionCount: Int {
        CleanupSelection.ids(in: scanResults?.categories ?? [], selected: scannerSelection, scope: .all)
            .subtracting(idsInCurrentView).count
    }

    /// Selecting a filtered child replaces selection of its whole parent.
    func setScannerSelection(_ selection: Set<FileEntry.ID>) {
        var selection = selection
        if dataTypeFilter != .all {
            let added = selection.subtracting(scannerSelection)
            for parent in scanResults?.categories.flatMap(\.entries) ?? []
                where parent.children.contains(where: { added.contains($0.id) }) {
                selection.remove(parent.id)
                userDataRemovalOverrides.remove(parent.id)
            }
        }
        scannerSelection = selection
    }
}
