import Foundation
import Testing
@testable import MoppoCore

/// `HiddenDataScanner.scan` against a fixture home.
///
/// The scanner had no test of its own until 20 Sep 2026. It took a home from the
/// day it was written, so nothing stood in the way.
@Suite("Hidden & System Data")
struct HiddenDataScanTests {
    @Test("Archives finish during a cloud wait, and cancellation prevents partial results", arguments: [false, true])
    func archivesOverlapCloud(cancel: Bool) async throws {
        let sandbox = try Sandbox()
        let cloud = sandbox.home.appendingPathComponent("Library/Mobile Documents")
        try sandbox.file("Library/Mobile Documents/claimed.zip", bytes: 260 * 1024 * 1024)
        let archive = try sandbox.file("Downloads/separate.zip", bytes: 260 * 1024 * 1024)
        let log = try ScanDiagnostics(directory: sandbox.home.appendingPathComponent("logs"))
        let cloudStarted = DispatchSemaphore(value: 0)
        let localFinished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        var context = ScanContext(measurer: AllocatedSizeMeasurer(onMeasurement: { url, _, _ in
            if url.path == cloud.path {
                cloudStarted.signal()
                #expect(release.wait(timeout: .now() + 5) == .success)
            }
        }))
        context.onPhase = { phase in
            if phase == "Measuring local iCloud files" { localFinished.signal() }
        }
        let scanContext = context
        let scanner = HiddenDataScanner(home: sandbox.home)
        let task = Task {
            try await ScanDiagnostics.$current.withValue(log.context) { try await scanner.scan(context: scanContext) }
        }
        let overlapped = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let cloudReady = cloudStarted.wait(timeout: .now() + 5) == .success
                let localReady = localFinished.wait(timeout: .now() + 5) == .success
                continuation.resume(returning: cloudReady && localReady)
            }
        }
        #expect(overlapped)
        log.flush()
        let records = try Data(contentsOf: log.fileURL).split(separator: 10).map {
            try #require(try JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        let completed = records.filter { $0["event"] as? String == "span_end" }
            .compactMap { $0["details"] as? [String: String] }
        #expect(completed.contains { $0["operation"] == "archive_discovery" && $0["candidates"] == "1" })
        #expect(!completed.contains { $0["operation"] == "cloud_measurement" })
        if cancel { task.cancel() }
        release.signal()
        if cancel {
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            let result = try await task.value
            #expect(Set(result.entries.map { $0.url.resolvingSymlinksInPath().path })
                == Set([cloud, archive].map { $0.resolvingSymlinksInPath().path }))
            #expect(result.totalBytes == result.entries.reduce(0) { $0 + $1.displayBytes })
        }
        log.finish(outcome: cancel ? "cancelled" : "completed")
        log.flush()
        let final = try String(contentsOf: log.fileURL, encoding: .utf8)
        #expect(final.contains("\"active_operations\":\"0\""))
    }


    @Test("Archive discovery cancels before startup and during a small walk", arguments: [1, 8])
    func archiveDiscoveryCancellation(cancelAt: Int) throws {
        let sandbox = try Sandbox()
        for index in 0..<20 {
            try sandbox.file("folder/file-\(index).txt", bytes: 1)
        }
        var checkpoints = 0

        #expect(throws: CancellationError.self) {
            try HiddenDataScanner.discoverLargeArchives(below: sandbox.home, skipping: []) {
                checkpoints += 1
                if checkpoints == cancelAt { throw CancellationError() }
            }
        }
        #expect(checkpoints == cancelAt)
    }

    private final class Sandbox {
        let home: URL
        init() throws {
            home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("moppo-hidden-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        }
        deinit { try? FileManager.default.removeItem(at: home) }

        @discardableResult
        func file(_ relative: String, bytes: Int = 2 * 1024 * 1024) throws -> URL {
            let url = home.appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(count: bytes).write(to: url)
            return url
        }
    }

    /// `~/.cache` was this scanner's until 20 Sep 2026. System Caches lists it now —
    /// see `SystemCachesScanTests` — and this one only keeps its archive sweep out.
    @Test("~/.cache is not listed here, and a disk image inside it is not swept up")
    func dotCacheBelongsToSystemCaches() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".cache/sometool/index.bin", bytes: 6 * 1024 * 1024)
        try sandbox.file(".cache/vm/disk.qcow2", bytes: 260 * 1024 * 1024)
        try sandbox.file(".somebody/data.bin", bytes: 6 * 1024 * 1024)

        let result = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())

        #expect(result.entries.map(\.url.lastPathComponent) == [".somebody"])
    }

    /// The Trash was a row here. Ticking it and cleaning up asked macOS to move the
    /// Trash into the Trash, or, with that setting off, deleted `~/.Trash` outright
    /// past Empty Trash, its confirmation, its receipts and Put Back.
    @Test("the Trash is never a removable row; the Trash view owns it")
    func trashIsNotOffered() async throws {
        let sandbox = try Sandbox()
        try sandbox.file(".Trash/old-report.pdf", bytes: 4 * 1024 * 1024)
        // Large enough for the archive sweep, which must not walk back into the Trash.
        try sandbox.file(".Trash/backup.dmg", bytes: 260 * 1024 * 1024)
        try sandbox.file(".somebody/data.bin", bytes: 6 * 1024 * 1024)

        let result = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())

        #expect(result.entries.map(\.url.lastPathComponent) == [".somebody"])
        #expect(!result.entries.contains { $0.url.path.contains("/.Trash") })
    }

}
