import Foundation

/// Finds the date for the **Last opened** column, with a time limit on Spotlight.
///
/// `MDItemCreate` and `MDItemCopyAttribute` wait for the Spotlight server (`mds`)
/// with no time limit. When the server stopped replying, a scan stopped at its first
/// row and did not finish. Each Spotlight lookup now runs on a serial queue, and the
/// caller waits for `timeLimit` at most. A lookup that does not reply in time stays on
/// the queue, because the call cannot be stopped.
///
/// After one timeout, the instance does not ask Spotlight again and uses the file
/// dates. `ScanCoordinator` makes a new instance for each scan, so the next scan asks
/// Spotlight again. Code outside a coordinator scan shares one instance for the life
/// of the process.
final class LastOpenedDates: @unchecked Sendable {
    /// Reads Spotlight for one path. `nil` means that Spotlight has no date for it.
    typealias SpotlightLookup = @Sendable (URL) -> Date?

    /// The instance for the current scan. Tests replace it to remove Spotlight.
    @TaskLocal static var current = LastOpenedDates()

    /// A Spotlight reply usually takes less than 1 ms. This limit is much longer, so
    /// a slow reply still gives the same date.
    static let defaultTimeLimit: Duration = .seconds(2)

    private let spotlight: SpotlightLookup
    private let timeLimit: Duration
    private let queue = DispatchQueue(label: "studio.anguria.moppo.last-opened-dates", qos: .utility)
    private let lock = NSLock()
    private var spotlightStopped = false

    init(timeLimit: Duration = defaultTimeLimit,
         spotlight: @escaping SpotlightLookup = { LastOpenedDates.spotlightDate(for: $0) }) {
        self.timeLimit = timeLimit
        self.spotlight = spotlight
    }

    /// An instance with the same lookup and time limit that has not had a timeout.
    func forNewScan() -> LastOpenedDates {
        LastOpenedDates(timeLimit: timeLimit, spotlight: spotlight)
    }

    /// The Spotlight date, else the file modification date, else the creation date.
    func date(for url: URL) -> Date? {
        if let date = spotlightDateInTime(for: url) { return date }
        // Spotlight did not reply in time, or it has not indexed the volume.
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        return values.contentModificationDate ?? values.creationDate
    }

    /// Last used date, else content modification date, in the order that `mdls` gives.
    static func spotlightDate(for url: URL) -> Date? {
        guard let item = MDItemCreate(nil, url.path as CFString) else { return nil }
        if let used = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date { return used }
        return MDItemCopyAttribute(item, kMDItemContentModificationDate) as? Date
    }

    private var hasStopped: Bool { lock.withLock { spotlightStopped } }

    private func spotlightDateInTime(for url: URL) -> Date? {
        guard !hasStopped else { return nil }
        let reply = Reply()
        queue.async { [self] in
            // A lookup that waited behind a lookup with no reply does not ask again.
            if !hasStopped { reply.date = spotlight(url) }
            reply.done.signal()
        }
        guard reply.done.wait(timeout: .now() + timeLimit.dispatchInterval) == .success else {
            lock.withLock { spotlightStopped = true }
            ScanDiagnostics.current?.record("spotlight_date_timeout",
                details: ["path": url.path, "time_limit_ms": "\(timeLimit.nanoseconds / 1_000_000)"])
            return nil
        }
        return reply.date
    }

    /// The queue writes `date` before `done.signal()`. The caller reads it only after a
    /// successful wait, so the semaphore orders the write before the read.
    private final class Reply: @unchecked Sendable {
        var date: Date?
        let done = DispatchSemaphore(value: 0)
    }
}

private extension Duration {
    var nanoseconds: Int {
        Int(components.seconds) * 1_000_000_000 + Int(components.attoseconds / 1_000_000_000)
    }

    var dispatchInterval: DispatchTimeInterval { .nanoseconds(nanoseconds) }
}
