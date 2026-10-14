import Darwin
import Foundation
import MoppoCore

/// Keeps completed reviews in memory for three minutes.
@MainActor
struct AppUninstallDetailCache {
    struct Settings: Equatable {
        let excludedPaths: [String]
        let excludedPatterns: [String]
        let hasFullDiskAccess: Bool
    }

    struct BundleStamp: Equatable {
        private let info: Data
        private let files: [FileStamp?]

        init?(_ url: URL) {
            let url = url.standardizedFileURL
            guard url.resolvingSymlinksInPath() == url,
                  let bundle = FileStamp(url), bundle.isDirectory,
                  FileManager.default.isReadableFile(atPath: url.path),
                  let info = try? Data(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
                  let properties = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any]
            else { return nil }
            self.info = info
            let executable = (properties["CFBundleExecutable"] as? String).flatMap { name -> URL? in
                guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return nil }
                return url.appendingPathComponent("Contents/MacOS/\(name)")
            }
            files = [
                bundle,
                FileStamp(url.appendingPathComponent("Contents")),
                FileStamp(url.appendingPathComponent("Contents/Info.plist")),
                executable.flatMap(FileStamp.init),
                FileStamp(url.appendingPathComponent("Contents/_CodeSignature/CodeResources")),
                FileStamp(url.appendingPathComponent("Contents/_MASReceipt/receipt"))
            ]
        }
    }

    private struct FileStamp: Equatable {
        let identity: String
        let mode: mode_t
        let size: off_t
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int
        var isDirectory: Bool { mode & S_IFMT == S_IFDIR }

        init?(_ url: URL) {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFLNK,
                  let identity = FileIdentity.of(url) else { return nil }
            self.identity = identity
            mode = info.st_mode
            size = info.st_size
            modifiedSeconds = info.st_mtimespec.tv_sec
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
            changedSeconds = info.st_ctimespec.tv_sec
            changedNanoseconds = info.st_ctimespec.tv_nsec
        }
    }

    private struct Entry {
        let plan: AppUninstallPlan
        let stamp: BundleStamp
        let settings: Settings
        let expires: ContinuousClock.Instant
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let now: () -> ContinuousClock.Instant
    private let limit = 32
    private(set) var generation = UUID()

    init(now: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.now = now
    }

    mutating func plan(for url: URL, settings: Settings) -> AppUninstallPlan? {
        let key = url.standardizedFileURL.path
        guard let entry = entries[key] else { return nil }
        guard now() < entry.expires, entry.settings == settings,
              BundleStamp(url) == entry.stamp else {
            entries.removeValue(forKey: key)
            order.removeAll { $0 == key }
            return nil
        }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.plan
    }

    mutating func store(_ plan: AppUninstallPlan, stamp: BundleStamp, settings: Settings, generation: UUID) {
        guard self.generation == generation, BundleStamp(plan.applicationURL) == stamp else { return }
        let key = plan.applicationURL.standardizedFileURL.path
        entries[key] = Entry(plan: plan, stamp: stamp, settings: settings, expires: now() + .seconds(180))
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > limit {
            entries.removeValue(forKey: order.removeFirst())
        }
    }

    mutating func invalidate() {
        generation = UUID()
        entries.removeAll()
        order.removeAll()
    }
}
