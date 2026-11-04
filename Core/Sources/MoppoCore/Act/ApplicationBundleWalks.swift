import Foundation

/// Shares the bundle identifier walk of each application within one scan.
///
/// Applications and Application Leftovers both read the identifiers in each
/// installed application. A walk of a large bundle can take seconds, so a scan
/// walks each bundle one time. When a category finds a walk in progress, it walks
/// the next bundle and gets the result later.
///
/// A walk that fails or stops keeps no result. The next caller walks that bundle again.
final class ApplicationBundleWalks: @unchecked Sendable {
    private enum Walk {
        case running(waiters: [CheckedContinuation<Void, Never>])
        case finished(Set<String>)
    }

    private let lock = NSLock()
    private var walks: [String: Walk] = [:]

    /// The union of the identifiers in each application.
    func identifiers(
        in applications: [URL], walk: (URL) throws -> Set<String>
    ) async throws -> Set<String> {
        var result = Set<String>()
        var running: [URL] = []
        for application in applications {
            if let identifiers = try claimOrRead(application, walk: walk) {
                result.formUnion(identifiers)
            } else {
                running.append(application)
            }
        }
        for application in running {
            while true {
                if let identifiers = try claimOrRead(application, walk: walk) {
                    result.formUnion(identifiers)
                    break
                }
                await waitForWalk(of: application)
            }
        }
        return result
    }

    /// Returns the finished result, walks an unclaimed bundle, or returns nil
    /// while another caller walks it.
    private func claimOrRead(
        _ application: URL, walk: (URL) throws -> Set<String>
    ) throws -> Set<String>? {
        try Task.checkCancellation()
        let key = application.standardizedFileURL.path
        let current: Walk? = lock.withLock {
            let current = walks[key]
            if current == nil { walks[key] = .running(waiters: []) }
            return current
        }
        switch current {
        case .finished(let identifiers): return identifiers
        case .running: return nil
        case nil: break
        }
        let identifiers: Set<String>
        do {
            identifiers = try walk(application)
        } catch {
            finish(key, with: nil)
            throw error
        }
        finish(key, with: identifiers)
        return identifiers
    }

    private func finish(_ key: String, with identifiers: Set<String>?) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard case .running(let waiters) = walks[key] else { return [] }
            walks[key] = identifiers.map { .finished($0) }
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    private func waitForWalk(of application: URL) async {
        let key = application.standardizedFileURL.path
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let isRunning: Bool = lock.withLock {
                guard case .running(var waiters) = walks[key] else { return false }
                waiters.append(continuation)
                walks[key] = .running(waiters: waiters)
                return true
            }
            if !isRunning { continuation.resume() }
        }
    }
}
