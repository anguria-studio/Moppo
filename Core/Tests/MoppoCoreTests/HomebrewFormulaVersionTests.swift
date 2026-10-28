import Foundation
import Testing
@testable import MoppoCore

@Suite("Old Homebrew formula versions", .serialized)
struct HomebrewFormulaVersionTests {
    private final class Fixture: Sendable {
        let root: URL
        let version: HomebrewFormulaVersion

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-brew-\(UUID())")
            let target = root.appendingPathComponent("Cellar/example/1.0")
            version = .init(name: "example", version: "1.0", path: target.path, token: String(repeating: "a", count: 64))
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try Data(repeating: 0x61, count: 65_536).write(to: target.appendingPathComponent("tool"))
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var catalog: Data {
            get throws {
                try JSONSerialization.data(withJSONObject: ["unreadableCount": 0, "versions": [[
                    "name": version.name, "version": version.version, "path": version.path, "token": version.token,
                ]]])
            }
        }

        func service(_ data: Data) -> HomebrewFormulaVersions {
            HomebrewFormulaVersions(executables: { ["/usr/bin/true", "/usr/bin/true"] }) { _, arguments in
                #expect(arguments == ["ruby", HomebrewFormulaVersions.scriptURL.path, "inventory"])
                return data
            }
        }
    }

    @Test("Old versions appear separately from downloads and require review")
    func scannerIntegration() async throws {
        let fixture = try Fixture()
        let cache = fixture.root.appendingPathComponent("Library/Caches/Homebrew")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 0x62, count: 32_768).write(to: cache.appendingPathComponent("bottle"))
        let scanner = PackageManagerScanner(home: fixture.root, homebrewVersions: fixture.service(try fixture.catalog))
        let result = try await scanner.scan(context: ScanContext())
        #expect(result.entries.map(\.displayName) == ["example 1.0", "Homebrew cache"])
        #expect(result.totalBytes == result.entries.reduce(0) { $0 + $1.allocatedBytes })
        let row = try #require(result.entries.first)
        let command = try #require(row.toolCommand)
        #expect(!row.isRegenerable)
        #expect(!row.isRemovalLocked)
        #expect(result.tileRows(safeToRemove: false).map(\.id) == [row.id])
        #expect(result.tileRows(safeToRemove: true).map(\.displayName) == ["Homebrew cache"])
        #expect(command.arguments == ["ruby", HomebrewFormulaVersions.scriptURL.path, "remove", fixture.version.path, fixture.version.token])
        #expect(command.environment["HOMEBREW_NO_AUTOREMOVE"] == "1")
    }

    @Test("Folder and pattern exclusions withhold old versions", arguments: [true, false])
    func exclusions(folder: Bool) async throws {
        let fixture = try Fixture()
        let context = folder
            ? ScanContext(excludedPaths: [fixture.version.path + "/tool"])
            : ScanContext(excludedPatterns: ["tool"])
        let result = try await fixture.service(try fixture.catalog).entries(context: context)
        #expect(result.entries.isEmpty)
    }

    @Test("Missing tools and invalid inventories cannot create removal rows")
    func inventoryFailures() async throws {
        let missing = HomebrewFormulaVersions(executables: { [] }) { _, _ in
            Issue.record("A missing tool must not run.")
            return Data()
        }
        let absent = try await missing.entries(context: ScanContext())
        #expect(absent.entries.isEmpty)
        #expect(absent.unreadableCount == 0)
        let fixture = try Fixture()
        let invalid = try await fixture.service(Data("invalid JSON".utf8)).entries(context: ScanContext())
        #expect(invalid.entries.isEmpty)
        #expect(invalid.unreadableCount == 2)
        let malformed = try JSONSerialization.data(withJSONObject: ["unreadableCount": 1, "versions": [[
            "name": "other", "version": "1.0", "path": fixture.version.path, "token": fixture.version.token,
        ]]])
        let result = try await fixture.service(malformed).entries(context: ScanContext())
        #expect(result.entries.isEmpty)
        #expect(result.unreadableCount == 4)
    }

    @Test("Cancellation during Homebrew inventory stops the scan")
    func cancellation() async throws {
        let service = HomebrewFormulaVersions(executables: { ["/usr/bin/true"] }) { _, _ in
            throw CancellationError()
        }
        await #expect(throws: CancellationError.self) { try await service.entries(context: ScanContext()) }
    }

    @Test("A changed removal script cannot use an earlier confirmation")
    func changedScript() async throws {
        let fixture = try Fixture()
        let script = fixture.root.appendingPathComponent("adapter.rb")
        try Data("original".utf8).write(to: script)
        let review = ToolCommandRemoval(targetURL: URL(fileURLWithPath: fixture.version.path), executable: "/usr/bin/true",
            arguments: [], environment: [:], expectedResult: .targetAbsent, scriptURL: script)
        let entry = FileEntry(url: review.targetURL, kind: .cache, allocatedBytes: 65_536, removalMethod: .toolCommand(review))
        try Data("changed script".utf8).write(to: script)
        let service = ToolCommandRemovalService { _ in
            Issue.record("A changed script must not run.")
            throw CancellationError()
        }
        let result = await service.remove(entry, review: review, confirmed: review)
        #expect(result.status == .notStarted)
        #expect(result.exitStatus == nil)
        #expect(FileManager.default.fileExists(atPath: fixture.version.path))
    }

    @Test("Native Homebrew protects current versions and removes only a reviewed disposable version",
          .enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/brew")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/brew")))
    func nativeHomebrew() async throws {
        let executable = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        }!
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/homebrew-versions.rb")
        let data = try await ProcessRunner().run(executable,
            ["ruby", fixture.path, HomebrewFormulaVersions.scriptURL.path], timeout: .seconds(30),
            environment: HomebrewFormulaVersions.environment, allowsInput: false)
        #expect(String(decoding: data, as: UTF8.self).contains("Native Homebrew checks passed."))
    }
}
