import Foundation
import Testing
@testable import MoppoCore

@Suite("Cleanup scan cancellation")
struct ScanCancellationTests {
    @Test("A stop request waits for the cancelled worker to finish", arguments: [false, true])
    func cancellationReachesWorker(cancelCaller: Bool) async throws {
        let gate = ScanGate()
        let timings = TimingRecorder()
        let coordinator = ScanCoordinator(scanners: [DelayedScanner(gate: gate)])
        let task = Task {
            try await coordinator.scan(onCategoryTiming: { timings.record($0, $1) })
        }
        await gate.waitForStart()

        if cancelCaller { task.cancel() }
        else { await coordinator.cancel() }
        #expect(await coordinator.isScanning)
        await gate.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.sawCancellation)
        #expect(!(await coordinator.isScanning))
        #expect(timings.result.map(\.0) == [.documentsAndFiles])
        #expect(timings.result.allSatisfy { $0.1 >= .zero })

        let next = try await coordinator.scan()
        #expect(next.categories.count == 1)
        #expect(!(await coordinator.isScanning))
    }

    @Test("Category timing includes failures and excludes disabled categories")
    func categoryTiming() async throws {
        let timings = TimingRecorder()
        let coordinator = ScanCoordinator(scanners: [
            FixedScanner(id: .documentsAndFiles, fails: false),
            FixedScanner(id: .applications, fails: true),
            FixedScanner(id: .docker, fails: false)
        ])
        let result = try await coordinator.scan(
            enabled: [.documentsAndFiles, .applications],
            onCategoryTiming: { timings.record($0, $1) }
        )
        #expect(result.categories.first { $0.categoryID == .applications }?.availability
                == .unavailable(reason: "Could not be measured."))
        #expect(Set(timings.result.map(\.0)) == [.documentsAndFiles, .applications])
        #expect(timings.result.count == 2)
        #expect(timings.result.allSatisfy { $0.1 >= .zero })
    }

    private struct FixedScanner: CategoryScanner {
        let id: CategoryID
        let fails: Bool

        func scan(context: ScanContext) async throws -> ScanCategoryResult {
            if fails { throw CocoaError(.fileReadUnknown) }
            return .empty(id)
        }
    }

    private final class TimingRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var timings: [(CategoryID, Duration)] = []

        func record(_ category: CategoryID, _ duration: Duration) {
            lock.lock()
            defer { lock.unlock() }
            timings.append((category, duration))
        }

        var result: [(CategoryID, Duration)] {
            lock.lock()
            defer { lock.unlock() }
            return timings
        }
    }

    @Test("A stop request before startup prevents a new scan")
    func cancelledBeforeStart() async {
        let gate = ScanGate()
        let coordinator = ScanCoordinator(scanners: [DelayedScanner(gate: gate)])
        let task = Task {
            await gate.waitForRelease()
            return try await coordinator.scan()
        }
        task.cancel()
        await gate.release()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await gate.starts == 0)
        #expect(!(await coordinator.isScanning))
    }

    private struct DelayedScanner: CategoryScanner {
        let id: CategoryID = .documentsAndFiles
        let gate: ScanGate

        func scan(context: ScanContext) async throws -> ScanCategoryResult {
            await gate.didStart()
            await gate.waitForRelease()
            await gate.recordCancellation(Task.isCancelled)
            try Task.checkCancellation()
            return .empty(id)
        }
    }

    private actor ScanGate {
        private var startWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?
        private var isReleased = false
        private(set) var starts = 0
        private(set) var sawCancellation = false

        func didStart() {
            starts += 1
            startWaiter?.resume()
            startWaiter = nil
        }

        func waitForStart() async {
            if starts > 0 { return }
            await withCheckedContinuation { startWaiter = $0 }
        }

        func waitForRelease() async {
            if isReleased { return }
            await withCheckedContinuation { releaseWaiter = $0 }
        }

        func release() {
            isReleased = true
            releaseWaiter?.resume()
            releaseWaiter = nil
        }

        func recordCancellation(_ cancelled: Bool) {
            sawCancellation = cancelled
        }
    }
}
