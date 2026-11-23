import Foundation

/// Recognizes the native Cursor CLI installer layout and checks older versions for cleanup.
struct CursorCLIVersions: Sendable {
    static let storePath = ".local/share/cursor-agent"

    struct Version: Sendable, Equatable {
        let url: URL
        let releaseDay: String
        let identity: String
        let launcherIdentity: String
    }

    struct Inventory: Equatable {
        let storeIdentity: String
        let versionsIdentity: String
        let active: Version
        let rollbackDay: String?
        let versions: [Version]

        func isOlderThanRollback(_ version: Version) -> Bool {
            rollbackDay.map { version.releaseDay < $0 } ?? false
        }
    }

    struct Review: Sendable, Equatable {
        let home: URL
        let version: Version
        let active: Version
        let storeIdentity: String
        let versionsIdentity: String
        let excludedPatterns: [String]

        func failureBeforeRemoval(
            of url: URL, capture: @Sendable ([URL]) async throws -> WorktreeActivity
        ) async throws -> String? {
            let store = CursorCLIVersions(home: home)
            let changed = "The Cursor CLI installation changed. Scan again before removal."
            guard url.standardizedFileURL == version.url, let before = store.inventory(),
                  before.storeIdentity == storeIdentity, before.versionsIdentity == versionsIdentity,
                  before.active == active, before.versions.contains(version), before.isOlderThanRollback(version)
            else { return changed }
            let measurer = AllocatedSizeMeasurer(followSymlinks: false, protectedPatterns: excludedPatterns,
                                                detectCloudOnlyItems: true)
            let activity = try await capture([version.url])
            let reason = try await CursorCLIVersions.failure(for: version, activity: activity, measurer: measurer)
            guard store.inventory() == before else { return changed }
            return reason
        }
    }

    let home: URL

    func inventory() -> Inventory? {
        let home = home.resolvingSymlinksInPath()
        let store = home.appendingPathComponent(Self.storePath)
        let versions = store.appendingPathComponent("versions")
        let bin = home.appendingPathComponent(".local/bin")
        let files = FileManager.default
        guard FileIdentity.physicalPath(versions.resolvingSymlinksInPath().path) == FileIdentity.physicalPath(versions.path),
              FileIdentity.physicalPath(bin.resolvingSymlinksInPath().path) == FileIdentity.physicalPath(bin.path),
              let storeIdentity = Self.ownedIdentity(store, type: S_IFDIR),
              let versionsIdentity = Self.ownedIdentity(versions, type: S_IFDIR),
              Self.ownedIdentity(bin, type: S_IFDIR) != nil,
              (try? files.contentsOfDirectory(atPath: store.path)) == ["versions"],
              let names = try? files.contentsOfDirectory(atPath: versions.path), !names.isEmpty
        else { return nil }

        var installed: [Version] = []
        for name in names.sorted() {
            let directory = versions.appendingPathComponent(name).standardizedFileURL
            let launcher = directory.appendingPathComponent("cursor-agent")
            guard name.wholeMatch(of: /20[0-9]{2}\.(0[1-9]|1[0-2])\.(0[1-9]|[12][0-9]|3[01])(-([01][0-9]|2[0-3])-[0-5][0-9]-[0-5][0-9])?-[0-9a-f]{7,40}/) != nil,
                  let identity = Self.ownedIdentity(directory, type: S_IFDIR),
                  let launcherIdentity = Self.ownedIdentity(launcher, type: S_IFREG, executable: true),
                  Self.ownedIdentity(directory.appendingPathComponent("node"), type: S_IFREG, executable: true) != nil,
                  Self.ownedIdentity(directory.appendingPathComponent("index.js"), type: S_IFREG) != nil,
                  Self.isCursorRuntime(directory.appendingPathComponent("package.json"))
            else { return nil }
            installed.append(Version(url: directory, releaseDay: String(name.prefix(10)),
                                     identity: identity, launcherIdentity: launcherIdentity))
        }
        // The installer creates two direct links. Keep the store protected during a link change.
        let launchers = ["agent", "cursor-agent"].compactMap { name in
            try? files.destinationOfSymbolicLink(atPath: bin.appendingPathComponent(name).path)
        }.map(FileIdentity.physicalPath)
        guard launchers.count == 2, launchers[0] == launchers[1],
              let active = installed.first(where: {
                  FileIdentity.physicalPath($0.url.appendingPathComponent("cursor-agent").path) == launchers[0]
              }),
              installed.allSatisfy({ $0.releaseDay <= active.releaseDay })
        else { return nil }

        let rollbackDay = installed.lazy.map(\.releaseDay).filter { $0 < active.releaseDay }.max()
        return Inventory(storeIdentity: storeIdentity, versionsIdentity: versionsIdentity, active: active,
                         rollbackDay: rollbackDay, versions: installed)
    }

    static func failure(for version: Version, activity: WorktreeActivity, measurer: AllocatedSizeMeasurer) async throws -> String? {
        let files = ModelFiles(owner: version.url, activity: activity)
        var measurer = measurer
        measurer.followSymlinks = false
        let measurement = try await files.measure(version.url, with: measurer)
        guard measurement.allocatedBytes > 0, !measurement.containsProtectedPattern, !measurement.containsCloudOnlyItem,
              files.hardLinks.isEmpty, !files.hasSymbolicLinks
        else { return "Moppo could not verify the files in this Cursor CLI version." }
        switch activity.check(version.url, measurement: measurement) {
        case .found: return "A running process uses this Cursor CLI version."
        case .unknown: return "Moppo could not check all processes for this Cursor CLI version."
        case .clear: break
        }
        let markers = version.url.appendingPathComponent(".running")
        if FileIdentity.isAbsent(markers) { return nil }
        guard Self.ownedIdentity(markers, type: S_IFDIR) != nil,
              let names = try? FileManager.default.contentsOfDirectory(atPath: markers.path), names.isEmpty
        else { return "Cursor reports possible activity for this version. Close Cursor CLI sessions and scan again." }
        return nil
    }

    private static func ownedIdentity(_ url: URL, type: mode_t, executable: Bool = false) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == type,
              !executable || info.st_mode & S_IXUSR != 0 else { return nil }
        return FileIdentity.of(url)
    }

    private static func isCursorRuntime(_ manifest: URL) -> Bool {
        struct Package: Decodable { let name: String }
        guard ownedIdentity(manifest, type: S_IFREG) != nil,
              let handle = try? FileHandle(forReadingFrom: manifest)
        else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1024), data.count < 16 * 1024,
              let package = try? JSONDecoder().decode(Package.self, from: data)
        else { return false }
        return package.name == "@anysphere/agent-cli-runtime"
    }
}
