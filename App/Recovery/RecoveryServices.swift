import MoppoCore

protocol TrashServicing: Sendable {
    func summary(limit: Int) async throws -> TrashSummary
    func empty() async throws -> EmptyTrashOutcome
    func putBack(_ item: TrashItem) async throws
}

extension TrashService: TrashServicing {}

protocol CleanupHistoryReading: Sendable {
    func summary() async -> CleanupHistorySummary
}

struct CleanupHistoryReader: CleanupHistoryReading {
    var service = CleanupHistoryService()
    func summary() async -> CleanupHistorySummary {
        await Task.detached(priority: .utility) { service.summary() }.value
    }
}
