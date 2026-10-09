import Foundation
import MoppoCore
import Testing

@Suite("Cleanup scheduler")
@MainActor
struct CleanupSchedulerTests {
    @Test("The scheduler refreshes volume information and reads current conditions before scanning")
    func currentConditions() async {
        let scheduler = CleanupScheduler()
        var conditions = AutomaticScanPolicy.Conditions(cadence: .daily)
        var starts = 0
        var refreshes = 0
        var access = true
        scheduler.canCheck = { access }
        scheduler.conditions = { conditions }
        scheduler.startScan = { starts += 1 }
        scheduler.refreshVolume = { refreshes += 1 }
        await scheduler.checkNow()
        #expect(starts == 1)
        #expect(refreshes == 1)
        conditions.lastFinished = conditions.now
        await scheduler.checkNow()
        #expect(starts == 1)
        #expect(refreshes == 2)
        conditions.lastFinished = nil
        scheduler.refreshVolume = {
            refreshes += 1
            conditions.isScanning = true
        }
        await scheduler.checkNow()
        #expect(starts == 1)
        conditions.isScanning = false
        scheduler.refreshVolume = { access = false }
        await scheduler.checkNow()
        #expect(starts == 1)
        access = false
        scheduler.refreshVolume = { refreshes += 1 }
        await scheduler.checkNow()
        #expect(refreshes == 3)
    }

    @Test("Concurrent checks share no duplicate refresh or scan")
    func overlappingChecks() async throws {
        let scheduler = CleanupScheduler()
        let gate = SchedulerGate()
        var starts = 0
        scheduler.canCheck = { true }
        scheduler.conditions = { AutomaticScanPolicy.Conditions(cadence: .daily) }
        scheduler.startScan = { starts += 1 }
        scheduler.refreshVolume = { await gate.wait() }
        let first = Task { await scheduler.checkNow() }
        try await waitUntil { await gate.isPending }
        await scheduler.checkNow()
        #expect(await gate.count == 1)
        first.cancel()
        await gate.finish()
        await first.value
        #expect(starts == 0)
        scheduler.refreshVolume = {}
        await scheduler.checkNow()
        #expect(starts == 1)
    }

    @Test("Stopping the timer during refresh prevents a scheduled scan")
    func stoppedTimer() async throws {
        let scheduler = CleanupScheduler(interval: .milliseconds(1))
        let gate = SchedulerGate()
        var starts = 0
        scheduler.canCheck = { true }
        scheduler.conditions = { AutomaticScanPolicy.Conditions(cadence: .daily) }
        scheduler.refreshVolume = { await gate.wait() }
        scheduler.startScan = { starts += 1 }
        scheduler.start()
        scheduler.start()
        try await waitUntil { await gate.isPending }
        scheduler.stop()
        #expect(await gate.count == 1)
        await gate.finish()
        await Task.yield()
        #expect(starts == 0)
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await condition(), "The scheduler did not reach the expected state.")
    }
}

private actor SchedulerGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    var isPending: Bool { continuation != nil }
    func wait() async {
        count += 1
        await withCheckedContinuation { continuation = $0 }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
