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
        #expect(records.contains { record in
            let details = record["details"] as? [String: String]
            return record["event"] as? String == "span_start" && details?["operation"] == "measure_tree"
                && details?["reader"] == "filesystem" && details?["path"] == cloud.path
        })
        #expect(completed.contains { $0["operation"] == "directory" && $0["reader"] == "filesystem"
            && $0["directory_path"] == cloud.path
            && Double($0["listing_seconds"] ?? "") != nil && Double($0["metadata_seconds"] ?? "") != nil })
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

    final class Sandbox {
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


    // MARK: - Toolchain, virtual machine, and credential folders (#321)

    /// A folder layout from the #257 and #216 manifests of 3 November 2026: names only, with test sizes.
    struct ToolFolderFixture: CustomTestStringConvertible, Sendable {
        let name: String
        /// The first file holds the installed data and is large enough for a row. The other files are small.
        let files: [String]
        var links: [String: String] = [:]
        /// The cache rows that Moppo offers, relative to the folder.
        var caches: Set<String> = []
        var testDescription: String { name }

        @discardableResult
        func make(in sandbox: Sandbox) throws -> URL {
            for (index, file) in files.enumerated() {
                try sandbox.file(name + "/" + file, bytes: index == 0 ? 6 * 1024 * 1024 : 64 * 1024)
            }
            let folder = sandbox.home.appendingPathComponent(name)
            for (link, target) in links {
                try FileManager.default.createSymbolicLink(
                    at: folder.appendingPathComponent(link), withDestinationURL: folder.appendingPathComponent(target))
            }
            return folder
        }
    }

    static let toolFolders: [ToolFolderFixture] = [
        .init(name: ".rustup", files: ["toolchains/stable-aarch64-apple-darwin/lib/librustc_driver.dylib", "settings.toml",
                                       "update-hashes/stable-aarch64-apple-darwin", "downloads/9f2c.partial", "tmp/rustup-tmp-1"],
              caches: ["downloads", "tmp"]),
        .init(name: ".goenv", files: ["versions/1.24.0/bin/go", "shims/go", "releases-cache.json",
                                      "shared/go-mod/cache/download/golang.org/x/tools/@v/v0.30.0.zip"],
              caches: ["releases-cache.json", "shared/go-mod"]),
        .init(name: ".pyenv", files: ["versions/3.12.16/lib/libpython3.12.dylib", "shims/python3"]),
        .init(name: ".rbenv", files: ["versions/3.3.13/lib/libruby.3.3.dylib", "shims/ruby"]),
        .init(name: ".rvm", files: ["rubies/ruby-3.3.13/bin/ruby", "archives/ruby-3.3.13.tar.bz2",
                                    "src/ruby-3.3.13/configure", "scripts/rvm", "VERSION"]),
        .init(name: ".rubies", files: ["ruby-3.3.13/bin/ruby"]),
        .init(name: ".plenv", files: ["versions/5.44.0/bin/perl", "build/1793700000.123/perl-5.44.0/Configure",
                                      "cache/perl-5.44.0.tar.gz", "shims/perl"],
              caches: ["build", "cache"]),
        .init(name: ".cpanm", files: ["work/1793635569.56559/Try-Tiny-0.32.tar.gz", "work/1793635569.56849/build.log"],
              links: ["latest-build": "work/1793635569.56849", "build.log": "work/1793635569.56849/build.log"],
              caches: ["work"]),
        .init(name: ".ghcup", files: ["ghc/9.10.3/lib/ghc-9.10.3/bin/ghc", "bin/ghcup", "cabal/3.16.1.0/bin/cabal",
                                      "cache/ghcup-0.1.0.yaml", "config.yaml", "env", "logs/ghcup.log"]),
        .init(name: ".stack", files: ["programs/aarch64-osx/ghc-9.10.3/bin/ghc", "config.yaml", "stack.sqlite3",
                                      "pantry/pantry.sqlite3", "snapshots/aarch64-osx/9.10.3/lib/package.conf",
                                      "setup-exe-cache/aarch64-osx/setup-Simple-Cabal", "setup-exe-src/setup-shim.hs"],
              caches: ["pantry", "setup-exe-cache", "snapshots"]),
        .init(name: ".sdkman", files: ["candidates/jbang/0.143.0/bin/jbang.jar", "bin/sdkman-init.sh", "etc/config",
                                       "tmp/jbang-0.143.0.zip", "var/version", "libexec/version"]),
        .init(name: ".sbt", files: ["1.0/java9-rt-ext-homebrew_21_0_13_0_3/rt.jar", "boot/sbt.boot.lock"],
              caches: ["boot"]),
        .init(name: ".m2", files: ["repository/commons-codec/commons-codec/1.19.0/commons-codec-1.19.0.jar",
                                   "repository/commons-codec/commons-codec/1.19.0/_remote.repositories",
                                   "repository/.meta/prefixes-central.txt", "settings.xml"],
              caches: ["repository"]),
        .init(name: ".composer", files: ["vendor/laravel/framework/src/Illuminate/Foundation/Application.php", "auth.json",
                                         "composer.json", "composer.lock", "config.json", ".htaccess"]),
        .init(name: ".asdf", files: ["installs/jq/1.8.1/bin/jq", "plugins/jq/bin/install", "plugin-index/README.md",
                                     "shims/jq", "downloads/jq/1.8.1/jq-macos-arm64"],
              caches: ["downloads"]),
        .init(name: ".mix", files: ["archives/hex-2.6.0/hex-2.6.0/ebin/hex.app", "elixir/1-20-otp-29/rebar3"]),
        .init(name: ".android", files: ["avd/moppo257.avd/userdata-qemu.img", "avd/moppo257.ini",
                                        "cache/sdkbin-1_b7518f9e-repository2-3_xml", "adbkey"],
              caches: ["cache"]),
        .init(name: ".config/composer", files: ["vendor/laravel/installer/bin/laravel", "auth.json", "composer.json"]),
        .init(name: ".config/gcloud", files: ["logs/2026.11.03/12.00.00.000000.log", "credentials.db", "active_config"]),
        .init(name: ".config/gh", files: ["extensions/gh-copilot/gh-copilot", "hosts.yml", "config.yml"]),
        .init(name: ".colima", files: ["_lima/_disks/colima/datadisk", "_lima/_config/user", "_store/colima.json", "ssh_config"]),
        .init(name: ".lima", files: ["moppo257/diffdisk", "_config/user", "_config/user.pub"]),
        .init(name: ".aws", files: ["sso/cache/token.json", "config"]),
        .init(name: ".azure", files: ["msal_token_cache.json", "azureProfile.json"]),
        .init(name: ".docker", files: ["contexts/meta/default/meta.json", "config.json"]),
        .init(name: ".gnupg", files: ["private-keys-v1.d/key.key", "pubring.kbx", "trustdb.gpg"]),
        .init(name: ".kube", files: ["cache/discovery/cluster/servergroups.json", "config"]),
        .init(name: ".ssh", files: ["id_ed25519", "known_hosts", "config"])
    ]

    @Test("each protected tool folder has a fixture")
    func toolFolderFixturesCoverTheRules() {
        #expect(Set(Self.toolFolders.map(\.name)) == ToolHomeFolders.names)
    }

    @Test("a toolchain, virtual machine, or credential folder is locked, keeps its size, and offers only verified caches",
          arguments: toolFolders)
    func toolFolderIsLocked(fixture: ToolFolderFixture) async throws {
        let sandbox = try Sandbox()
        let folder = try fixture.make(in: sandbox)
        let total = try await AllocatedSizeMeasurer().measure(folder).allocatedBytes

        let result = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())

        #expect(result.entries.count == 1)
        let entry = try #require(result.entries.first)
        #expect(entry.url.path.hasSuffix("/" + fixture.name))
        #expect(entry.protectionReason == .inventory)
        #expect(entry.protectionExplanation == ToolHomeFolders.folder(named: fixture.name)?.explanation)
        #expect(!CleanupService.removalAllowed(entry, userDataRemovalOverrides: [entry.id]))
        #expect(entry.displayBytes == total)
        #expect(result.totalBytes == total)
        let prefix = entry.url.path + "/"
        #expect(Set(entry.children.map { String($0.url.path.dropFirst(prefix.count)) }) == fixture.caches)
        #expect(entry.children.allSatisfy { !$0.isRemovalLocked && $0.protectionReason == nil })
    }

    enum CacheEvidence: CaseIterable, Sendable {
        case layoutMissing, markerMissing, linkedCache
    }

    @Test("a cache in a tool folder is not offered without the tool layout", arguments: CacheEvidence.allCases)
    func toolFolderCacheNeedsLayout(evidence: CacheEvidence) async throws {
        let sandbox = try Sandbox()
        let fixture = Self.toolFolders.first { $0.name == (evidence == .markerMissing ? ".m2" : ".rustup") }!
        let folder = try fixture.make(in: sandbox)
        switch evidence {
        case .layoutMissing:
            try FileManager.default.removeItem(at: folder.appendingPathComponent("settings.toml"))
        case .markerMissing:
            try FileManager.default.removeItem(at: folder.appendingPathComponent("repository/.meta"))
        case .linkedCache:
            let elsewhere = try sandbox.file("Documents/keep/report.pdf").deletingLastPathComponent()
            for cache in fixture.caches {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(cache))
                try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(cache), withDestinationURL: elsewhere)
            }
        }

        let result = try await HiddenDataScanner(home: sandbox.home).scan(context: ScanContext())

        let entry = try #require(result.entries.first { $0.url.lastPathComponent == fixture.name })
        #expect(entry.protectionReason == .inventory)
        #expect(entry.children.isEmpty)
    }

}
