import Foundation
import Testing
@testable import MoppoCore

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

enum RemovalConfirmationChoice: CaseIterable {
    case disabled, confirm, cancel
    var isEnabled: Bool { self != .disabled }
}

/// Keeps removal preferences separate from the user's settings.
@MainActor
final class RemovalSettingsFixture {
    let settings: SettingsStore
    private let suite = "RemovalSettingsTests.\(UUID().uuidString)"

    init(confirm: Bool) throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        settings.confirmBeforeCleanup = confirm
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
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

/// Supplies downloaded content for model tests without reading system libraries.
func soundLibraryItem() -> AppUninstallPlan.Item {
    let url = URL(fileURLWithPath: "/moppo-fixture/Library/Application Support/Logic")
    return .init(
        url: url, category: .support, content: .soundLibrary, allocatedBytes: 64,
        ownerBundleIdentifier: AppleSoundLibrary.garageBandIdentifier,
        soundLibrary: AppleSoundLibrary.Inventory(
            url: url, ownerIdentifiers: AppleSoundLibrary.ownerIdentifiers, permittedOwner: nil,
            applicationRoots: [], libraryRoot: url.deletingLastPathComponent(), identities: [:]
        )
    )
}

actor HeldCleanupScanner: CleanupScanning {
    private(set) var preferences: [CleanupModel.Preferences] = []
    private var scans: [Int: CheckedContinuation<ScanResults, any Error>] = [:]
    private var reports: [Int: @Sendable (ScanProgress) -> Void] = [:]
    var requestCount: Int { preferences.count }
    func scan(
        preferences: CleanupModel.Preferences,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResults {
        let index = requestCount
        self.preferences.append(preferences)
        reports[index] = onProgress
        return try await withCheckedThrowingContinuation { scans[index] = $0 }
    }
    func report(_ index: Int, percent: Int) {
        reports[index]?(ScanProgress(percent: percent, completedCategories: 1, totalCategories: 2))
    }
    func finish(_ index: Int, results: ScanResults) { scans.removeValue(forKey: index)?.resume(returning: results) }
    func fail(_ index: Int) { scans.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadUnknown)) }
}
