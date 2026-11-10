import Foundation

/// Saves the last measured storage breakdown between launches.
public struct BreakdownCache: Codable, Sendable {
    public var breakdown: StorageBreakdown
    public var measuredAt: Date

    public init(breakdown: StorageBreakdown, measuredAt: Date) {
        self.breakdown = breakdown
        self.measuredAt = measuredAt
    }

    /// Figures older than this are shown but marked stale.
    public static let freshnessWindow: TimeInterval = 24 * 60 * 60

    public var isStale: Bool {
        Date().timeIntervalSince(measuredAt) > Self.freshnessWindow
    }

    // MARK: - Storage

    public static var fileURL: URL {
        AppStorage.supportDirectory
            .appendingPathComponent("breakdown-cache.json")
    }

    public static func load() -> BreakdownCache? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(BreakdownCache.self, from: data)
    }

    public func save() {
        let url = Self.fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
