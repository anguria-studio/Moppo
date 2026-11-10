import Foundation
import MoppoCore
import Testing

@Suite("Docker category checks")
@MainActor
struct DockerCheckTests {
    @Test("A Docker check refreshes only Docker and keeps valid selections")
    func refresh() async throws {
        let operations = OperationCoordinator()
        let scanner = HeldCleanupScanner()
        let gate = TestGate()
        let added = volume("added")
        let excluded = volume("excluded")
        let cache = FileEntry(url: URL(fileURLWithPath: "/fixture/cache"), kind: .cache,
            allocatedBytes: 50, isRegenerable: true)
        let caches = ScanCategoryResult(categoryID: .systemCaches, totalBytes: 50, entries: [cache])
        let initial = ScanResults(categories: [caches, unavailableDocker],
            startedAt: Date(timeIntervalSince1970: 10), finishedAt: Date(timeIntervalSince1970: 20))
        let suite = "DockerCheckTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(initial.finishedAt, forKey: "lastScanFinishedAt")
        var preferences = CleanupModel.Preferences(enabledCategories: [.systemCaches],
            excludedPaths: [excluded.url.absoluteString])
        let cleanup = CleanupModel(operations: operations, scanner: scanner, preferences: { preferences },
            defaults: defaults, scanDocker: { received in
                #expect(received == preferences)
                await gate.wait()
                return docker([added, excluded])
            })
        cleanup.scanResults = initial
        cleanup.scannerSelection = [cache.id]
        cleanup.scanFilter = .all
        cleanup.openCategories = [.systemCaches]
        cleanup.onEvent = { _ in Issue.record("A Docker check must not send full scan events.") }

        #expect(!cleanup.canCheckDocker)
        cleanup.startDockerScan()
        #expect(!operations.isBusy)
        preferences.enabledCategories?.insert(.docker)
        #expect(cleanup.canCheckDocker)
        cleanup.startDockerScan()
        try await waitUntil { await gate.isPending }
        #expect(cleanup.isCheckingDocker)
        #expect(!cleanup.isScanning)
        #expect(cleanup.showsDockerCheck)
        #expect(!cleanup.canCheckDocker)
        #expect(cleanup.scanResults == initial)
        #expect(operations.isBusy)
        cleanup.startDockerScan()
        cleanup.startScan()
        #expect(operations.begin(.cleanupRemoval) == nil)
        #expect(await gate.count == 1)
        #expect(await scanner.requestCount == 0)

        await gate.finish()
        try await waitUntil { !cleanup.isCheckingDocker }
        let refreshed = try #require(cleanup.scanResults)
        #expect(refreshed.categories == [caches, docker([added])])
        #expect(refreshed.totalBytes == 150)
        #expect(refreshed.startedAt == initial.startedAt)
        #expect(refreshed.finishedAt == initial.finishedAt)
        #expect(cleanup.lastScanFinishedAt == initial.finishedAt)
        #expect(defaults.object(forKey: "lastScanFinishedAt") as? Date == initial.finishedAt)
        #expect(cleanup.scannerSelection == [cache.id])
        #expect(cleanup.openCategories == [.systemCaches, .docker])
        #expect(!cleanup.canCheckDocker)
        #expect(!operations.isBusy)
    }

    @Test("A successful check hides Check Now", arguments: [false, true])
    func availability(endsEmpty: Bool) async throws {
        let result = endsEmpty ? ScanCategoryResult.empty(.docker) : docker([volume("data")])
        var requests = 0
        let cleanup = CleanupModel(operations: OperationCoordinator(), scanDocker: { _ in
            requests += 1
            return result
        })
        cleanup.scanFilter = .all
        cleanup.scanResults = ScanResults(categories: [unavailableDocker], startedAt: .now, finishedAt: .now)
        #expect(cleanup.visibleCategories == [unavailableDocker])
        #expect(cleanup.showsDockerCheck)
        #expect(cleanup.canCheckDocker)
        cleanup.startDockerScan()
        try await waitUntil { !cleanup.isCheckingDocker }
        #expect(cleanup.visibleCategories == [result])
        #expect(!cleanup.showsDockerCheck)
        #expect(!cleanup.canCheckDocker)
        cleanup.startDockerScan()
        #expect(!cleanup.isCheckingDocker)
        #expect(requests == 1)
        #expect(cleanup.scannerSelection.isEmpty)
    }

    @Test("A stopped Docker check keeps results and waits for its workers")
    func cancellation() async throws {
        let operations = OperationCoordinator()
        let gate = TestGate()
        let initial = ScanResults(categories: [unavailableDocker], startedAt: .now, finishedAt: .now)
        let cleanup = CleanupModel(operations: operations, scanDocker: { _ in
            await gate.wait()
            return docker([volume("late")])
        })
        cleanup.scanResults = initial
        cleanup.startDockerScan()
        try await waitUntil { await gate.isPending }
        cleanup.cancelScan()
        #expect(cleanup.isInterruptingScan)
        #expect(cleanup.isCheckingDocker)
        #expect(operations.isBusy)
        #expect(cleanup.scanResults == initial)
        await gate.finish()
        try await waitUntil { !cleanup.isCheckingDocker }
        #expect(!cleanup.isInterruptingScan)
        #expect(!operations.isBusy)
        #expect(cleanup.scanResults == initial)
    }

    @Test("A failed check permits a new check")
    func failure() async throws {
        let cleanup = CleanupModel(operations: OperationCoordinator(), scanDocker: { _ in
            throw CocoaError(.fileReadUnknown)
        })
        cleanup.scanResults = ScanResults(categories: [unavailableDocker], startedAt: .now, finishedAt: .now)
        cleanup.startDockerScan()
        try await waitUntil { !cleanup.isCheckingDocker }
        let result = try #require(cleanup.scanResults?.categories.first)
        guard case .unavailable = result.availability else {
            Issue.record("A failed Docker check must report unavailable storage.")
            return
        }
        #expect(result.entries.isEmpty)
        #expect(result != unavailableDocker)
        #expect(cleanup.canCheckDocker)
    }

    private var unavailableDocker: ScanCategoryResult {
        .unavailable(.docker, reason: "Docker is unavailable.")
    }

    private func volume(_ name: String) -> FileEntry {
        FileEntry(url: URL(string: "docker://volumes/fixture/\(name)")!, kind: .diskImage, allocatedBytes: 100,
            docker: .volume(DockerVolume(name: name, context: "fixture", containerCount: 0)))
    }

    private func docker(_ entries: [FileEntry]) -> ScanCategoryResult {
        ScanCategoryResult(categoryID: .docker, totalBytes: entries.reduce(0) { $0 + $1.allocatedBytes }, entries: entries)
    }
}
