import Foundation
import Testing
@testable import MoppoCore

@Suite("Detailed scan diagnostics")
struct ScanDiagnosticsTests {
    @Test("Scan descriptors are excluded by PID while other process activity remains protected")
    func scanProcessDescriptors() throws {
        let sandbox = try AllocatedSizeMeasurerTests.Sandbox()
        let log = try ScanDiagnostics(directory: sandbox.root)
        let unavailable = "f29\0nvnode: FD unavailable\0\n"
        let output = Data(("p59089\0cMoppo\0\n"
            + "fcwd\0tDIR\0D0x1\0i1\0\nftxt\0tREG\0D0x1\0i2\0\nfmem\0tREG\0D0x1\0i3\0\n"
            + String(repeating: unavailable, count: 40)
            + "f30\0tREG\0D0x1\0i6\0\n"
            + "p59090\0cMoppo\0\nf31\0tREG\0D0x1\0i4\0\n"
            + "p59091\0cEditor\0\nf32\0tREG\0D0x1\0i5\0\n").utf8)
        let parsed = ScanDiagnostics.$current.withValue(log.context) {
            WorktreeActivity.parse(output, scanProcessID: 59089)
        }
        #expect(parsed.complete)
        #expect(parsed.incompleteFiles == 0)
        #expect(parsed.processes == ["1:1": ["Moppo"], "1:2": ["Moppo"], "1:3": ["Moppo"],
                                     "1:4": ["Moppo"], "1:5": ["Editor"]])
        #expect(!WorktreeActivity.parse(output).complete)
        for record in ["p59090\0cMoppo\0\n" + unavailable, "p59089\0cMoppo\0\nfcwd\0nvnode: FD unavailable\0\n"] {
            let result = WorktreeActivity.parse(output + Data(record.utf8), scanProcessID: 59089)
            #expect(!result.complete)
            #expect(result.incompleteFiles == 1)
        }
        #expect(!WorktreeActivity.parse(output.dropLast(), scanProcessID: 59089).complete)
        log.finish(outcome: "completed")
        log.flush()
        let events = try records(log)
        #expect(!events.contains { $0["event"] as? String == "worktree_activity_issue" })
        let excluded = events.filter { $0["event"] as? String == "worktree_activity_scan_handle" }.map(details)
        #expect(excluded.count == 32)
        #expect(excluded.allSatisfy { $0["pid"] == "59089" && $0["descriptor"] == "29" })
        #expect(excluded.first?["path"] == "vnode: FD unavailable")
        let inventory = details(try #require(events.first { $0["event"] as? String == "worktree_activity_inventory" }))
        #expect(inventory["complete"] == "true")
        #expect(inventory["scan_process_id"] == "59089")
        #expect(inventory["scan_descriptors_excluded"] == "41")
        #expect(inventory["scan_descriptor_records_logged"] == "32")
        #expect(inventory["scan_descriptor_records_omitted"] == "9")
        #expect(excluded.allSatisfy { $0["inventory_id"] == inventory["inventory_id"] })
    }

    @Test("Incomplete process records identify the cause within diagnostic limits")
    func incompleteProcessRecords() throws {
        let sandbox = try AllocatedSizeMeasurerTests.Sandbox()
        let log = try ScanDiagnostics(directory: sandbox.root)
        let missing = "p123\0cEditor\0\nf3\0tREG\0n/fixture/open.txt\0\n"
        let unknown = "fmem\0tUNKNOWN\0n/fixture/" + String(repeating: "x", count: 2000) + "\0\n"
        let output = Data((missing + "p456\0cOther process\0\n" + String(repeating: unknown, count: 40)
            + "f4\0n(revoked)\0\n").utf8)
        let parsed = ScanDiagnostics.$current.withValue(log.context) { WorktreeActivity.parse(output) }
        #expect(!parsed.complete)
        #expect(parsed.incompleteFiles == 41)
        #expect(parsed.revokedFiles == 1)
        log.finish(outcome: "completed")
        log.flush()
        let events = try records(log)
        let issues = events.filter { $0["event"] as? String == "worktree_activity_issue" }.map(details)
        #expect(issues.count == 32)
        let first = try #require(issues.first)
        #expect(first["pid"] == "123")
        #expect(first["process"] == "Editor")
        #expect(first["descriptor"] == "3")
        #expect(first["file_type"] == "REG")
        #expect(first["path"] == "/fixture/open.txt")
        #expect(first["reason"] == "invalid_file_identity")
        #expect(first["missing_fields"] == "device,inode")
        #expect(issues[1]["pid"] == "456")
        #expect(issues[1]["process"] == "Other process")
        #expect(issues[1]["reason"] == "unsupported_file_type")
        #expect(issues[1]["path"]?.count == 1024)
        #expect(issues[1]["truncated_fields"] == "path")
        let inventory = details(try #require(events.first { $0["event"] as? String == "worktree_activity_inventory" }))
        #expect(inventory["complete"] == "false")
        #expect(inventory["incomplete_files"] == "41")
        #expect(inventory["issue_records_omitted"] == "9")
        #expect(inventory["terminated_record"] == "true")
        #expect(issues.allSatisfy { $0["inventory_id"] == inventory["inventory_id"] })
    }

    @Test("Logs identify category work, detached measurements, and command failures without command output")
    func recordsActualScanWork() async throws {
        let sandbox = try AllocatedSizeMeasurerTests.Sandbox()
        let folder = try sandbox.directory("files")
        try sandbox.writeFile("files/fixture.bin", bytes: 8192)
        let log = try ScanDiagnostics(directory: sandbox.root.appendingPathComponent("logs"))
        let coordinator = ScanCoordinator(scanners: [FixtureScanner(folder: folder)])
        let result = try await ScanDiagnostics.$current.withValue(log.context) {
            try await coordinator.scan()
        }
        log.finish(outcome: "completed")
        log.flush()
        let events = try records(log)
        #expect(result.categories.count == 1)
        #expect(events.contains { $0["event"] as? String == "progress" })
        let spans = events.filter { $0["event"] as? String == "span_end" }
        #expect(spans.contains { details($0)["operation"] == "directory" && $0["category"] as? String == "documentsAndFiles" })
        let directory = details(try #require(spans.first { details($0)["operation"] == "directory" }))
        #expect(Double(directory["listing_seconds"] ?? "") ?? -1 >= 0)
        #expect(Double(directory["metadata_seconds"] ?? "") ?? -1 >= 0)
        #expect(directory["metadata_reads"] == "1")
        #expect(spans.contains { details($0)["operation"] == "measure_tree" && details($0)["file_count"] == "1" })
        let process = try #require(spans.first { details($0)["operation"] == "process" })
        #expect(details(process)["outcome"] == "failed")
        #expect(details(process)["exit_status"] == "7")
        #expect(details(process)["stderr"] == "fixture diagnostic")
        let raw = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(!raw.contains("fixture-private-output"))
        #expect(!raw.contains("fixture-private-environment"))
        let sequence = events.compactMap { $0["sequence"] as? Int }
        #expect(sequence == sequence.sorted())
        #expect(Set(sequence).count == sequence.count)
        let permissions = try FileManager.default.attributesOfItem(atPath: log.fileURL.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
        #expect(events.last?["event"] as? String == "scan_end")
    }

    @Test("A running operation appears in a readable heartbeat before the scan finishes")
    func liveHeartbeat() async throws {
        let sandbox = try AllocatedSizeMeasurerTests.Sandbox()
        let log = try ScanDiagnostics(directory: sandbox.root, heartbeatInterval: 0.05)
        let context = log.context.forCategory("documentsAndFiles")
        let span = context.begin("worktree_review", path: "/fixture/worktree")
        context.update(span, path: "/fixture/worktree/last-file", details: ["stage": "read_metadata"])
        var heartbeat: [String: Any]?
        let deadline = ContinuousClock.now + .seconds(5)
        while heartbeat == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(30))
            log.flush()
            heartbeat = try records(log).first { $0["event"] as? String == "heartbeat" }
        }
        let snapshot = details(try #require(heartbeat))
        #expect(snapshot["active_operations"]?.contains("last-file") == true)
        #expect(snapshot["active_operations"]?.contains("worktree_review") == true)
        #expect(snapshot["workers"]?.contains("limit") == true)
        #expect(snapshot["resources"]?.contains("residentBytes") == true)
        context.end(span, outcome: "cancelled")
        log.finish(outcome: "cancelled")
        log.flush()
        #expect(details(try #require(try records(log).last))["outcome"] == "cancelled")
    }

    @Test("The detail budget preserves command results and the final scan record", arguments: [0, 1024])
    func boundedDetails(maximumBytes: Int) throws {
        let sandbox = try AllocatedSizeMeasurerTests.Sandbox()
        let log = try ScanDiagnostics(directory: sandbox.root, maximumDetailBytes: maximumBytes)
        for _ in 0..<32 {
            let span = log.context.begin("directory", path: "/fixture/folder")
            log.context.end(span)
        }
        log.flush()
        let span = log.context.begin("directory", path: "/fixture/after-limit")
        log.context.end(span)
        log.context.record("process_timeout", details: ["pid": "123"])
        log.finish(outcome: "completed")
        log.flush()
        let events = try records(log)
        #expect(events.filter { $0["event"] as? String == "detail_limit_reached" }.count == 1)
        #expect(!events.contains { details($0)["path"] == "/fixture/after-limit" })
        #expect(events.contains { $0["event"] as? String == "process_timeout" })
        #expect(events.last?["event"] as? String == "scan_end")
    }

    @Test("Stopped and timed-out commands retain their diagnostic cause", arguments: [false, true])
    func commandInterruption(cancel: Bool) async throws {
        let sandbox = try AllocatedSizeMeasurerTests.Sandbox()
        let log = try ScanDiagnostics(directory: sandbox.root, heartbeatInterval: 0.05)
        let task = Task {
            try await ScanDiagnostics.$current.withValue(log.context) {
                try await ProcessRunner().run("/bin/sleep", ["10"], timeout: cancel ? .seconds(10) : .milliseconds(50))
            }
        }
        if cancel {
            let deadline = ContinuousClock.now + .seconds(5)
            while ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
                log.flush()
                if try records(log).contains(where: { details($0)["active_operations"]?.contains("pid") == true }) { break }
            }
            task.cancel()
        }
        await #expect(throws: (any Error).self) { try await task.value }
        log.finish(outcome: cancel ? "cancelled" : "failed")
        log.flush()
        let events = try records(log)
        #expect(events.contains { $0["event"] as? String == (cancel ? "process_cancel_requested" : "process_timeout") })
        #expect(events.contains { details($0)["operation"] == "process" && details($0)["outcome"] == (cancel ? "cancelled" : "timed_out") })
    }

    private struct FixtureScanner: CategoryScanner {
        let id: CategoryID = .documentsAndFiles
        let folder: URL

        func scan(context: ScanContext) async throws -> ScanCategoryResult {
            _ = try await context.measurer.measure(folder)
            do {
                _ = try await ProcessRunner().run("/bin/sh", ["-c", "printf fixture-private; printf '%s' \"$1\"; printf 'fixture diagnostic' >&2; exit 7", "fixture", "-output"],
                    environment: ["FIXTURE_PRIVATE": "fixture-private-environment"], allowsInput: false)
            } catch ProcessError.failed { }
            return .empty(id)
        }
    }

    private func records(_ log: ScanDiagnostics) throws -> [[String: Any]] {
        try Data(contentsOf: log.fileURL).split(separator: 10).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    private func details(_ event: [String: Any]) -> [String: String] {
        event["details"] as? [String: String] ?? [:]
    }
}
