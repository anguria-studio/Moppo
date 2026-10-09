import Foundation
import MoppoCore
import Testing

@Suite("Trash sorting")
struct TrashSortOrderTests {
    @Test("Date sorting puts recent small items before older large items")
    func newestFirst() {
        let items = [
            item("large", bytes: 1_000, date: 10),
            item("unknown", bytes: 2_000, date: nil),
            item("recent", bytes: 1, date: 20)
        ]
        #expect(TrashSortOrder.date.sorted(items).map(\.name) == ["recent", "large", "unknown"])
        #expect(TrashSortOrder.date.sorted(items, ascending: true).map(\.name) == ["large", "recent", "unknown"])
    }

    @Test("Size sorting uses dates to order items with equal sizes")
    func largestFirst() {
        let items = [
            item("small", bytes: 1, date: 30),
            item("older", bytes: 100, date: 10),
            item("unknown", bytes: 100, date: nil),
            item("recent", bytes: 100, date: 20)
        ]
        #expect(TrashSortOrder.size.sorted(items).map(\.name) == ["recent", "older", "unknown", "small"])
        #expect(TrashSortOrder.size.sorted(items, ascending: true).map(\.name) == ["small", "recent", "older", "unknown"])
    }

    @Test("Item sorting uses natural name order in both directions")
    func names() {
        let items = [
            item("copy 10", bytes: 1, date: 30),
            item("copy 2", bytes: 100, date: 10),
            item("copy 1", bytes: 10, date: nil)
        ]
        #expect(TrashSortOrder.name.sorted(items, ascending: true).map(\.name) == ["copy 1", "copy 2", "copy 10"])
        #expect(TrashSortOrder.name.sorted(items).map(\.name) == ["copy 10", "copy 2", "copy 1"])
    }

    @Test("Equal dates and unknown dates retain a stable order", arguments: [TrashSortOrder.date, .size])
    func stableTies(order: TrashSortOrder) {
        let first = item("copy 2", bytes: 1, date: nil)
        let second = item("copy 10", bytes: 1, date: nil)
        var sameName = first
        sameName.id = "/another-trash/copy 2"
        sameName.url = URL(fileURLWithPath: sameName.id)
        let items = [second, first, sameName]
        let expected = [sameName.id, first.id, second.id]
        #expect(order.sorted(items).map(\.id) == expected)
        #expect(order.sorted(items.reversed()).map(\.id) == expected)
    }

    private func item(_ name: String, bytes: Int64, date: TimeInterval?) -> TrashItem {
        TrashItem(
            url: URL(fileURLWithPath: "/trash/\(name)"), bytes: bytes,
            deletedAt: date.map { Date(timeIntervalSince1970: $0) }
        )
    }
}
