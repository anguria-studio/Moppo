import Foundation
import Testing
@testable import MoppoCore

@Suite("Dashboard diagnostic privacy")
struct DashboardDiagnosticsTests {
    @Test("Dashboard phase timing does not enable directory diagnostics")
    func aggregateWalk() async throws {
        let sandbox = try AllocatedSizeMeasurerTests.Sandbox()
        let tree = try sandbox.directory("PRIVATE_DIRECTORY_SENTINEL")
        try sandbox.writeFile("PRIVATE_DIRECTORY_SENTINEL/file.bin", bytes: 8192)
        let log = try ScanDiagnostics(directory: sandbox.root)
        let result = try await DashboardDiagnostics.$current.withValue(log.context) {
            try await DashboardDiagnostics.phase("home_walk") {
                try await AllocatedSizeMeasurer().measure(tree)
            }
        }
        #expect(result.fileCount == 1)
        log.finish(outcome: "completed")
        log.flush()
        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(text.contains("home_walk"))
        #expect(text.contains("duration_seconds"))
        #expect(!text.contains("PRIVATE_DIRECTORY_SENTINEL"))
        #expect(!text.contains("measure_tree"))
        #expect(!text.contains("\"operation\":\"directory\""))
    }

    @Test("Error fields omit private messages, paths, domains, and command output")
    func boundedErrors() throws {
        let secret = "PRIVATE_CONTENT_SENTINEL"
        let errors: [any Error] = [
            NSError(domain: secret, code: 42, userInfo: [NSLocalizedDescriptionKey: secret]),
            NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [NSFilePathErrorKey: secret]),
            ProcessError.failed(command: secret, status: 7, stderr: secret),
            ProcessError.timedOut(secret), ProcessError.executableMissing(secret),
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: secret)),
            CancellationError()
        ]
        let details = errors.map(DashboardDiagnostics.errorDetails)
        let encoded = String(decoding: try JSONEncoder().encode(details), as: UTF8.self)
        #expect(!encoded.contains(secret))
        #expect(details[0] == ["error_kind": "other"])
        #expect(details[1]["error_code"] == "257")
        #expect(details[2]["error_code"] == "7")
        #expect(details.last?["error_kind"] == "cancelled")
    }
}
