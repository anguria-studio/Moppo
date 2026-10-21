import Foundation
import Testing
import MoppoCore

@Suite("Support reports")
struct SupportReportTests {
    @Test("Only diagnostic builds create detailed scan logs", arguments: [false, true])
    @MainActor
    func diagnosticBuild(enabled: Bool) async throws {
        let folder = try TemporaryFolder(prefix: "scan-log-configuration")
        let bundleURL = folder.url.appendingPathComponent("Diagnostic.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info = ["MoppoDetailedScanLogging": enabled ? "YES" : "NO", "CFBundleVersion": "17"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))
        let destination = folder.url.appendingPathComponent("logs")
        let log = try ScanLog.begin(.init(enabledCategories: [.documentsAndFiles]), bundle: bundle, directory: destination)
        let appLog = try ScanLog.recordApplicationEvent("application_started", bundle: bundle, directory: destination)
        let finalLog = try ScanLog.recordApplicationEvent("termination_requested",
            details: ["operation": "cleanupScan", "decision": "after_cancellation"], bundle: bundle, directory: destination)
        #expect((log != nil) == enabled)
        #expect((appLog != nil) == enabled)
        #expect(finalLog == appLog)
        #expect(FileManager.default.fileExists(atPath: destination.path) == enabled)
        if let appLog {
            let records = try Data(contentsOf: appLog).split(separator: 10).map {
                try #require(JSONSerialization.jsonObject(with: Data($0)) as? [String: String])
            }
            #expect(records.map { $0["event"] } == ["application_started", "termination_requested"])
            #expect(records.last?["operation"] == "cleanupScan")
            #expect(records.last?["decision"] == "after_cancellation")
            #expect(records.last?["pid"] == "\(ProcessInfo.processInfo.processIdentifier)")
            #expect(records.last?["app_build"] == "17")
            let mode = try FileManager.default.attributesOfItem(atPath: appLog.path)[.posixPermissions] as? Int
            #expect(mode == 0o600)
        }
        if let log {
            log.finish(outcome: "completed")
            log.flush()
            let content = try String(contentsOf: log.fileURL, encoding: .utf8)
            #expect(content.contains("documentsAndFiles"))
            #expect(content.contains("full_disk_access"))
            #expect(content.contains("17"))
        }
        let reviewDirectory = folder.url.appendingPathComponent("reviews")
        var expected = GitWorktreeReview()
        expected.activity = .unknown("The process check timed out.")
        let result = expected
        let url = folder.url
        for source in ["dialog", "removal"] {
            let actual = try await ScanLog.reviewWorktrees([url], source: source, bundle: bundle,
                directory: reviewDirectory, review: { urls in Dictionary(uniqueKeysWithValues: urls.map { ($0, result) }) })
            #expect(actual == [url: result])
        }
        #expect(FileManager.default.fileExists(atPath: reviewDirectory.path) == enabled)
        if enabled {
            let files = try FileManager.default.contentsOfDirectory(at: reviewDirectory, includingPropertiesForKeys: nil)
            // Review logs keep a separate prefix, so the newest scan-*.jsonl file is still a scan.
            #expect(files.count == 2)
            #expect(files.allSatisfy { $0.lastPathComponent.hasPrefix("worktree-review-") })
            let contents = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
            #expect(contents.contains("worktree_review_requested"))
            #expect(contents.contains("worktree_review_result"))
            #expect(contents.contains("dialog"))
            #expect(contents.contains("removal"))
            #expect(contents.contains("The process check timed out."))
            #expect(!contents.contains("enabled_categories"))
        }
    }
    @Test("Reports use an allowlist and email drafts preserve the reviewed text")
    func reportContents() throws {
        let folder = try TemporaryFolder(prefix: "support-report")
        let bundleURL = folder.url.appendingPathComponent("Report.bundle")
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info: [String: String] = [
            "CFBundleShortVersionString": "0.2.0", "CFBundleVersion": "2",
            "PrivatePath": "/Users/private/Photos", "RemovalLog": "private removal data"
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: bundleURL))
        let text = SupportReport.text(bundle: bundle, systemVersion: .init(majorVersion: 15, minorVersion: 2, patchVersion: 1))
        #expect(text.contains("0.2.0 (2)"))
        #expect(text.contains("15.2.1"))
        #expect(!text.contains(info["PrivatePath"]!))
        #expect(!text.contains(info["RemovalLog"]!))
        let url = try #require(SupportReport.emailURL(report: text))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == "hello@anguria.studio")
        #expect(components.queryItems?.first { $0.name == "body" }?.value == text)
    }
}
