import Foundation
import Testing

/// Waits for asynchronous model work. The test stops when the deadline expires.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition(), "The operation did not finish before the deadline.", sourceLocation: sourceLocation)
}

/// Holds an asynchronous call until the test releases it.
actor TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    var isPending: Bool { continuation != nil }

    func wait() async {
        count += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

/// Creates a disposable folder and removes it when the test releases the folder.
final class TemporaryFolder {
    let url: URL

    init(prefix: String = "moppo-test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ name: String, contents: String = "Fixture") throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
