import CoreServices
import Foundation

/// Identifies downloaded sound content from Apple installer receipts.
public struct AppleSoundLibrary: Sendable {
    public static let garageBandIdentifier = "com.apple.garageband10"
    public static let ownerNames = [
        garageBandIdentifier: "GarageBand",
        "com.apple.logic10": "Logic Pro",
        "com.apple.MainStage3": "MainStage",
    ]
    public static var ownerIdentifiers: Set<String> { Set(ownerNames.keys) }

    /// Records the reviewed content and the application allowed to retain ownership.
    public struct Inventory: Sendable, Equatable, Codable {
        public let url: URL
        public let ownerIdentifiers: Set<String>
        let permittedOwner: String?
        let applicationRoots: [URL]
        let libraryRoot: URL
        let identities: [String: String]

        public func isExcluded(in context: ScanContext) -> Bool {
            context.isExcluded(url) || identities.keys.contains { context.isExcluded(URL(fileURLWithPath: $0)) }
        }

        func isStillSafe(registeredOwners: Set<String>) -> Bool {
            var installed = AppUninstallPlanner.installedBundleIdentifiers(in: applicationRoots)
            installed.formUnion(registeredOwners)
            let otherOwners = ownerIdentifiers.subtracting([permittedOwner].compactMap { $0 })
            guard !otherOwners.contains(where: {
                AppUninstallPlanner.ownerIsInstalled($0, installedBundleIdentifiers: installed)
            }), AppUninstallPlanner.isInside(url, root: libraryRoot),
                !AppUninstallPlanner.hasSymbolicLinkInParents(of: url, through: libraryRoot),
                let current = try? AppleSoundLibrary.identities(in: url)
            else { return false }
            return current == identities
        }
    }

    struct Result: Sendable {
        var items: [AppUninstallPlan.Item] = []
        var preservedPaths: [URL] = []
        var unreadableCount = 0
    }

    private struct Root {
        let relativePath: String
        let name: String
        let owners: Set<String>
    }

    private static var roots: [Root] { [
        Root(relativePath: "Application Support/GarageBand/Instrument Library",
             name: "Sound Library: Instruments", owners: ownerIdentifiers),
        Root(relativePath: "Application Support/GarageBand/Learn to Play",
             name: "Sound Library: Lessons", owners: [garageBandIdentifier]),
        Root(relativePath: "Application Support/Logic",
             name: "Sound Library: Shared Instruments", owners: ownerIdentifiers),
        Root(relativePath: "Audio/Apple Loops/Apple",
             name: "Sound Library: Apple Loops", owners: ownerIdentifiers),
    ] }

    static var systemContentPaths: Set<String> {
        Set(roots.map { "/Library/" + $0.relativePath })
    }

    private let systemLibrary: URL
    private let applicationRoots: [URL]
    private let receiptPaths: @Sendable () async throws -> Set<String>
    private let registeredApplications: @Sendable (Set<String>) -> Set<String>

    public init() { self.init(home: FileManager.default.homeDirectoryForCurrentUser) }

    init(home: URL) {
        self.init(
            systemLibrary: URL(fileURLWithPath: "/Library", isDirectory: true),
            applicationRoots: [URL(fileURLWithPath: "/Applications", isDirectory: true),
                               home.appendingPathComponent("Applications", isDirectory: true)],
            receiptPaths: Self.installedContentPaths,
            registeredApplications: Self.registeredOwners
        )
    }

    init(systemLibrary: URL, applicationRoots: [URL],
         receiptPaths: @escaping @Sendable () async throws -> Set<String>,
         registeredApplications: @escaping @Sendable (Set<String>) -> Set<String> = { _ in [] }) {
        self.systemLibrary = systemLibrary.standardizedFileURL
        self.applicationRoots = applicationRoots
        self.receiptPaths = receiptPaths
        self.registeredApplications = registeredApplications
    }

    /// Includes all possible owners so Launch Services can find applications outside the scan roots.
    func candidateIdentifiers() -> Set<String> {
        Self.roots.reduce(into: Set<String>()) { result, root in
            if FileManager.default.fileExists(atPath: systemLibrary.appendingPathComponent(root.relativePath).path) {
                result.formUnion(root.owners)
            }
        }
    }

    func scan(context: ScanContext, installedOwners: Set<String>,
              applicationIdentifier: String? = nil) async throws -> Result {
        guard !candidateIdentifiers().isEmpty else { return Result() }
        let paths: Set<String>
        do { paths = try await receiptPaths() }
        catch is CancellationError { throw CancellationError() }
        catch { return Result(unreadableCount: 1) }
        var result = Result()
        let installedOwners = installedOwners.union(registeredApplications(Self.ownerIdentifiers))
        for root in Self.roots {
            try Task.checkCancellation()
            let owners = root.owners.filter {
                AppUninstallPlanner.ownerIsInstalled($0, installedBundleIdentifiers: installedOwners)
            }
            let url = systemLibrary.appendingPathComponent(root.relativePath)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if let applicationIdentifier {
                guard root.owners.contains(applicationIdentifier) else { continue }
                guard owners.subtracting([applicationIdentifier]).isEmpty else {
                    result.preservedPaths.append(url)
                    continue
                }
            } else if !owners.isEmpty { continue }
            guard !context.isExcluded(url),
                  !AppUninstallPlanner.hasSymbolicLinkInParents(of: url, through: systemLibrary)
            else { result.preservedPaths.append(url); continue }
            let identities: [String: String]
            do { identities = try Self.identities(in: url) }
            catch is CancellationError { throw CancellationError() }
            catch { result.unreadableCount += 1; result.preservedPaths.append(url); continue }
            // A receipt does not authorize removal of added samples or other unknown files.
            let unknown = identities.keys.contains { !paths.contains($0) && $0 != url.path }
            guard !unknown else { result.preservedPaths.append(url); continue }
            guard identities.values.contains(where: { $0.hasPrefix("file:") }) else { continue }
            let measured = try await context.measurer.measure(url)
            result.unreadableCount += measured.unreadableCount
            guard measured.allocatedBytes > 0, measured.unreadableCount == 0,
                  !measured.containsProtectedPattern
            else { result.preservedPaths.append(url); continue }
            let inventory = Inventory(
                url: url, ownerIdentifiers: root.owners, permittedOwner: applicationIdentifier,
                applicationRoots: applicationRoots, libraryRoot: systemLibrary, identities: identities
            )
            result.items.append(AppUninstallPlan.Item(
                url: url, displayName: root.name, category: .support, content: .soundLibrary,
                allocatedBytes: measured.allocatedBytes,
                ownerBundleIdentifier: applicationIdentifier ?? Self.garageBandIdentifier,
                soundLibrary: inventory
            ))
        }
        return result
    }

    /// Rejects links and records every file and folder, including empty folders.
    private static func identities(in root: URL) throws -> [String: String] {
        var result: [String: String] = [:]
        func visit(_ url: URL) throws {
            try Task.checkCancellation()
            let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [
                .isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey,
            ])
            guard values.isSymbolicLink != true, let identity = FileIdentity.of(url),
                  values.isDirectory == true || values.isRegularFile == true
            else { throw CocoaError(.fileReadUnsupportedScheme) }
            result[url.standardizedFileURL.path] = (values.isDirectory == true ? "directory:" : "file:") + identity
                + ":\(values.fileSize ?? 0):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try visit(child)
                }
            }
        }
        try visit(root)
        return result
    }

    private static func installedContentPaths() async throws -> Set<String> {
        let runner = ProcessRunner()
        let catalog = try await runner.run("/usr/sbin/pkgutil", ["--pkgs"], timeout: .seconds(10))
        let identifiers = String(decoding: catalog, as: UTF8.self).split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("com.apple.pkg.MAContent10_AssetPack_") }
        var result = Set<String>()
        for identifier in identifiers {
            try Task.checkCancellation()
            let info = try await runner.run("/usr/sbin/pkgutil", ["--pkg-info-plist", String(identifier)], timeout: .seconds(10))
            guard let record = try PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
                  record["volume"] as? String == "/", record["install-location"] as? String == "/"
            else { continue }
            let files = try await runner.run("/usr/sbin/pkgutil", ["--files", String(identifier)], timeout: .seconds(10))
            for relative in String(decoding: files, as: UTF8.self).split(whereSeparator: \.isNewline) {
                guard !relative.hasPrefix("/"), !relative.split(separator: "/").contains("..") else { continue }
                result.insert(URL(fileURLWithPath: "/").appendingPathComponent(String(relative)).standardizedFileURL.path)
            }
        }
        return result
    }

    /// Resolves current owners without loading the applications.
    static func registeredOwners(_ identifiers: Set<String>) -> Set<String> {
        Set(identifiers.filter { identifier in
            guard let urls = LSCopyApplicationURLsForBundleIdentifier(identifier as CFString, nil)?.takeRetainedValue() as? [URL]
            else { return false }
            return urls.contains { FileManager.default.fileExists(atPath: $0.path) }
        })
    }
}
