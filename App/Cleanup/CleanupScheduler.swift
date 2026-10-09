import Foundation
import CoreGraphics
import IOKit.ps
import MoppoCore

/// Checks automatic scan settings and volume information every five minutes.
@MainActor
final class CleanupScheduler {
    var canCheck: () -> Bool = { false }
    var refreshVolume: () async -> Void = {}
    var conditions: () -> AutomaticScanPolicy.Conditions? = { nil }
    var startScan: () -> Void = {}
    private var task: Task<Void, Never>?
    private var isChecking = false
    private let interval: Duration

    init(interval: Duration = .seconds(300)) {
        self.interval = interval
    }

    deinit { task?.cancel() }

    func start() {
        guard task == nil else { return }
        let interval = interval
        task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard !Task.isCancelled else { return }
                await self?.checkNow()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func checkNow() async {
        guard !Task.isCancelled, !isChecking, canCheck() else { return }
        isChecking = true
        defer { isChecking = false }
        await refreshVolume()
        guard !Task.isCancelled, canCheck(), let conditions = conditions(),
              AutomaticScanPolicy.isDue(conditions) else { return }
        startScan()
    }

    static var isOnACPower: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let source = IOPSGetProvidingPowerSourceType(snapshot)?.takeUnretainedValue()
        else { return true }
        return (source as String) == "AC Power"
    }

    static var secondsSinceUserInput: TimeInterval {
        guard let anyInput = CGEventType(rawValue: ~0) else { return 0 }
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}
