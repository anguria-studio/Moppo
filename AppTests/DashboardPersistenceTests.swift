import Foundation
import Testing
@testable import MoppoCore

@Suite("Dashboard persistence diagnostics")
struct DashboardPersistenceTests {
    enum Failure: CaseIterable { case write, readback }

    @Test("History failures name the failed stage", arguments: Failure.allCases)
    func failureStage(_ failure: Failure) async throws {
        let folder = try TemporaryFolder()
        let log = try ScanDiagnostics(directory: folder.url)
        let directory = folder.url.appendingPathComponent("history")
        if failure == .write { try Data().write(to: directory) }
        let store = StorageSnapshotStore(directory: directory, now: {
            Date().addingTimeInterval(failure == .readback ? 31 * 24 * 60 * 60 : 0)
        })
        let measurement = dashboardMeasurement()
        let persistence = DashboardPersistence(snapshots: store)
        await DashboardDiagnostics.$current.withValue(log.context) {
            do {
                _ = try await persistence.record(measurement, trigger: .removal)
                Issue.record("The history operation must fail.")
            } catch {}
        }
        log.finish(outcome: "failed")
        let records = try diagnosticRecords(log)
        let failed = records.filter { $0.event == "span_end" && $0.details["outcome"] == "failed" }
        #expect(failed.count == 1)
        #expect(failed.first?.details["operation"] == (failure == .write ? "history_write" : "history_readback"))
        #expect(failed.first?.details["error_kind"] == "cocoa")
        #expect(records.last?.details["active_operations"] == "0")
    }
}
