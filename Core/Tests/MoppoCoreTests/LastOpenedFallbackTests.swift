import Foundation
import Testing
@testable import MoppoCore

/// Guards the fallback chain behind the design's **Last opened** column.
///
/// The design renders `Never opened` in orange as "the strongest signal that a file
/// is safe to remove". On macOS 26 `kMDItemLastUsedDate` returns `null` for almost
/// everything — including applications in daily use — so reading it alone made every
/// row claim it had never been opened. A live scan flagged the user's active project
/// directory as safe to delete.
@Suite("Last-opened fallback")
struct LastOpenedFallbackTests {

    /// Minimal conformer: the behaviour under test lives in the protocol extension.
    private struct Probe: CategoryScanner {
        let id: CategoryID = .documentsAndFiles
        func scan(context: ScanContext) async throws -> ScanCategoryResult {
            .empty(id)
        }
    }

    private typealias Sandbox = AllocatedSizeMeasurerTests.Sandbox

    @Test("a freshly written file reports a date rather than never-opened")
    func fileHasADate() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.writeFile("recent.bin", bytes: 1024)

        let date = try #require(
            Probe().lastOpenedDate(for: file),
            "a file modified seconds ago must not render as 'Never opened'"
        )
        #expect(abs(date.timeIntervalSinceNow) < 300)
    }

    @Test("a directory reports a date — folders never carry kMDItemLastUsedDate")
    func directoryHasADate() throws {
        let sandbox = try Sandbox()
        try sandbox.writeFile("project/source.swift", bytes: 512)
        let project = sandbox.root.appendingPathComponent("project")

        // This is the case that mislabelled an active project as safe to delete.
        let date = try #require(
            Probe().lastOpenedDate(for: project),
            "a directory must not render as 'Never opened' just because Spotlight has no last-used date"
        )
        #expect(abs(date.timeIntervalSinceNow) < 300)
    }

    @Test("nil is reserved for paths that genuinely do not exist")
    func missingPathIsUnknown() {
        let missing = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
        #expect(Probe().lastOpenedDate(for: missing) == nil)
    }

    /// Makes a row for each item in one folder, as the category scanners do.
    private struct FolderProbe: CategoryScanner {
        let id: CategoryID = .documentsAndFiles
        let folder: URL
        func scan(context: ScanContext) async throws -> ScanCategoryResult {
            var result = ScanCategoryResult.empty(id)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if let entry = try await makeEntry(url: url, kind: .file, context: context) {
                    result.entries.append(entry)
                }
            }
            return result
        }
    }

    @Test("Spotlight's date is the answer when Spotlight replies in time")
    func spotlightReplyIsKept() throws {
        let sandbox = try Sandbox()
        let file = try sandbox.writeFile("used.bin", bytes: 1024)
        let used = Date(timeIntervalSince1970: 1_700_000_000)

        let dates = LastOpenedDates { _ in used }
        #expect(LastOpenedDates.$current.withValue(dates) { Probe().lastOpenedDate(for: file) } == used)
    }

    @Test("a scan finishes with file dates and waits for one timeout when Spotlight does not reply")
    func scanFinishesWithoutSpotlight() async throws {
        let sandbox = try Sandbox()
        let files = try (1...5).map { try sandbox.writeFile("rows/file\($0).bin", bytes: 2 * 1024 * 1024) }
        let log = try ScanDiagnostics(directory: sandbox.root.appendingPathComponent("logs"))
        let release = DispatchSemaphore(value: 0)
        // Lets the lookup with no reply finish after the test.
        defer { release.signal() }
        let dates = LastOpenedDates(timeLimit: .milliseconds(200)) { _ in
            release.wait()
            return nil
        }
        let coordinator = ScanCoordinator(scanners: [FolderProbe(folder: sandbox.root.appendingPathComponent("rows"))])

        let results = try await ScanDiagnostics.$current.withValue(log.context) {
            try await LastOpenedDates.$current.withValue(dates) { try await coordinator.scan() }
        }

        log.flush()
        let timeouts = try Data(contentsOf: log.fileURL).split(separator: 10).filter {
            let record = try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
            return record?["event"] as? String == "spotlight_date_timeout"
        }
        #expect(timeouts.count == 1, "after one timeout, the scan does not ask Spotlight again")
        let entries = try #require(results.categories.first?.entries)
        #expect(entries.count == files.count)
        for entry in entries {
            let modified = try entry.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            #expect(entry.lastOpened == modified, "\(entry.url.lastPathComponent) shows its modification date")
        }
    }
}
