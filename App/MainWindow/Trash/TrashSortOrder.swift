import Foundation
import MoppoCore

enum TrashSortOrder: String, CaseIterable {
    case name = "Item"
    case date = "Date"
    case size = "Size"

    func sorted(_ items: [TrashItem], ascending: Bool = false) -> [TrashItem] {
        items.sorted { left, right in
            let nameOrder = left.name.localizedStandardCompare(right.name)
            if self == .name, nameOrder != .orderedSame {
                return (nameOrder == .orderedAscending) == ascending
            }
            if self == .size, left.bytes != right.bytes {
                return ascending ? left.bytes < right.bytes : left.bytes > right.bytes
            }
            switch (left.deletedAt, right.deletedAt) {
            case let (leftDate?, rightDate?) where leftDate != rightDate:
                return self == .date && ascending ? leftDate < rightDate : leftDate > rightDate
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            // Equal dates and names keep the same order after a refresh.
            return left.id < right.id
        }
    }
}
