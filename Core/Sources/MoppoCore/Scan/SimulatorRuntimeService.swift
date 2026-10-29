import Foundation
import CoreServices

/// The runtime and toolchains captured before command confirmation.
public struct SimulatorRuntimeReview: Sendable, Equatable {
    struct Runtime: Decodable, Sendable, Equatable {
        let identifier: String
        let runtimeIdentifier: String?
        let platformIdentifier: String?
        let version: String?
        let build: String?
        let state: String?
        let kind: String?
        let deletable: Bool?
        let signatureState: String?
        let path: String?
        let parentIdentifier: String?
        let parentImagePath: String?
        let mountPath: String?
        let runtimeBundlePath: String?

        var backingURL: URL? {
            if kind == "Cryptex Disk Image", parentImagePath == nil { return nil }
            guard let path = parentImagePath ?? path, path.hasPrefix("/"),
                  URL(fileURLWithPath: path).standardizedFileURL.path == path else { return nil }
            return URL(fileURLWithPath: path)
        }

        var storageKey: String? {
            backingURL.map { FileIdentity.of($0.resolvingSymlinksInPath()) ?? $0.resolvingSymlinksInPath().path }
        }

        var relatedURLs: [URL] {
            [path, parentImagePath, mountPath, runtimeBundlePath].compactMap { $0 }.map { URL(fileURLWithPath: $0) }
        }

        var platform: String {
            switch platformIdentifier {
            case "com.apple.platform.iphonesimulator": "iOS"
            case "com.apple.platform.appletvsimulator": "tvOS"
            case "com.apple.platform.watchsimulator": "watchOS"
            case "com.apple.platform.xrsimulator": "visionOS"
            default: "Unknown platform"
            }
        }

        var name: String { "\(platform) \(version ?? "Unknown version") Simulator Runtime (\(build ?? "Unknown build"))" }
        var matchKey: String { "\(platform):\(build ?? "")" }
    }

    struct Toolchain: Sendable, Equatable {
        let developerDirectory: String
        let simctl: String
        let identity: String
    }

    let runtime: Runtime
    let developerDirectory: String
    let toolchains: [Toolchain]
    let protectionExplanation: String?

    var toolsAreUnchanged: Bool {
        toolchains.allSatisfy { ToolCommandRemoval.fileVersion($0.simctl) == $0.identity }
    }
}

/// Reads runtime ownership and activity through each installed Xcode toolchain.
struct SimulatorRuntimeService: Sendable {
    typealias Run = @Sendable (String, [String], [String: String], Duration) async throws -> Data
    typealias Discover = @Sendable () async throws -> [URL]
    private let run: Run
    private let discover: Discover
    private let verificationTimeout: Duration

    enum RemovalVerification: Sendable {
        case removed, stillPresent, unavailable(String)

        var failureReason: String? {
            switch self {
            case .removed: nil
            case .stillPresent: "The runtime is still listed after removal. Scan again."
            case .unavailable: "Runtime removal could not be verified. Scan again."
            }
        }
    }

    struct Snapshot: Sendable {
        let runtimes: [SimulatorRuntimeReview.Runtime]
        let developerDirectory: String
        let toolchains: [SimulatorRuntimeReview.Toolchain]
        let requiredBuilds: Set<String>
        let activeRuntimes: Set<String>
        let failureReason: String?

        func review(_ runtime: SimulatorRuntimeReview.Runtime) -> SimulatorRuntimeReview {
            let reason: String?
            if let failureReason { reason = failureReason }
            else if UUID(uuidString: runtime.identifier) == nil || runtime.runtimeIdentifier?.isEmpty != false
                || runtime.version?.isEmpty != false || runtime.build?.isEmpty != false || runtime.platform == "Unknown platform" {
                reason = "Runtime details are incomplete. Scan again before removal."
            } else if runtime.deletable != true || runtime.state != "Ready" || runtime.signatureState != "Verified"
                || !["Cryptex Disk Image", "Disk Image"].contains(runtime.kind ?? "") {
                reason = "This runtime cannot be removed safely through simctl. Manage it in Xcode Components."
            } else if requiredBuilds.contains(runtime.matchKey) {
                reason = "An installed Xcode version uses this runtime. Moppo keeps it protected."
            } else if activeRuntimes.contains(runtime.runtimeIdentifier ?? "") {
                reason = "A simulator uses this runtime. Shut down the simulator, then scan again."
            } else if runtime.backingURL == nil {
                reason = "The runtime backing image could not be verified. Scan again before removal."
            } else if runtimes.contains(where: { $0.identifier != runtime.identifier && $0.storageKey == runtime.storageKey }) {
                reason = "Other runtimes share this backing image. Manage these runtimes in Xcode Components."
            } else { reason = nil }
            return SimulatorRuntimeReview(runtime: runtime, developerDirectory: developerDirectory,
                toolchains: toolchains, protectionExplanation: reason)
        }
    }

    enum InventoryError: Error { case invalidInventory, invalidToolchain }

    init() {
        self.init(run: { executable, arguments, environment, timeout in
            try await ProcessRunner().run(executable, arguments, timeout: timeout,
                environment: environment, allowsInput: false)
        }, discover: Self.developerDirectories)
    }

    init(run: @escaping Run, discover: @escaping Discover, verificationTimeout: Duration = .seconds(30)) {
        self.run = run
        self.discover = discover
        self.verificationTimeout = verificationTimeout
    }

    func snapshot() async throws -> Snapshot {
        // The selected toolchain supplies the inventory even when discovery is incomplete.
        let directories: [URL]
        var failureReason: String?
        do {
            directories = try await discover()
            if directories.isEmpty { failureReason = "Installed Xcode versions could not be verified. Scan again before removal." }
        } catch is CancellationError { throw CancellationError() }
        catch {
            directories = []
            failureReason = "Installed Xcode versions could not be verified. Scan again before removal."
        }
        let selected = directories.first?.path ?? ""
        let environment = selected.isEmpty ? [:] : ["DEVELOPER_DIR": selected]
        var toolchains: [SimulatorRuntimeReview.Toolchain] = []
        var requiredBuilds: Set<String> = []
        var activeRuntimes: Set<String> = []
        for directory in directories {
            try Task.checkCancellation()
            do {
                let environment = ["DEVELOPER_DIR": directory.path]
                let executable = try await run("/usr/bin/xcrun", ["--find", "simctl"], environment, .seconds(10))
                let path = String(decoding: executable, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard path.hasPrefix("/"), let identity = ToolCommandRemoval.fileVersion(path) else {
                    throw InventoryError.invalidToolchain
                }
                toolchains.append(.init(developerDirectory: directory.path, simctl: path, identity: identity))
                let matches = try await run("/usr/bin/xcrun", ["simctl", "runtime", "match", "list", "--json"], environment, .seconds(10))
                requiredBuilds.formUnion(try Self.requiredBuilds(matches))
                let devices = try await run("/usr/bin/xcrun", ["simctl", "list", "devices", "--json"], environment, .seconds(10))
                activeRuntimes.formUnion(try Self.activeRuntimes(devices))
            } catch is CancellationError { throw CancellationError() }
            catch { failureReason = "Xcode runtime use could not be verified. Scan again before removal." }
        }
        // Read the runtime identity after the toolchain and activity checks.
        let runtimes = try await inventory(environment: environment)
        return Snapshot(runtimes: runtimes, developerDirectory: selected, toolchains: toolchains,
            requiredBuilds: requiredBuilds, activeRuntimes: activeRuntimes, failureReason: failureReason)
    }

    func inventory(environment: [String: String], timeout: Duration = .seconds(10)) async throws -> [SimulatorRuntimeReview.Runtime] {
        let data = try await run("/usr/bin/xcrun", ["simctl", "runtime", "list", "--json"], environment, timeout)
        let records = try JSONDecoder().decode([String: SimulatorRuntimeReview.Runtime].self, from: data)
        guard records.allSatisfy({ $0.key == $0.value.identifier }) else { throw InventoryError.invalidInventory }
        return records.values.sorted { $0.identifier < $1.identifier }
    }

    func verifyRemoval(_ review: SimulatorRuntimeReview) async -> RemovalVerification {
        let clock = ContinuousClock()
        let deadline = clock.now + verificationTimeout
        var result: RemovalVerification = .stillPresent
        var checked = false
        repeat {
            let remaining = clock.now.duration(to: deadline)
            // A final short process deadline can report a timeout instead of the last complete check.
            guard !checked || remaining >= .seconds(1) else { return result }
            checked = true
            do {
                let timeout = min(.seconds(10), max(.seconds(1), remaining))
                let records = try await inventory(environment: ["DEVELOPER_DIR": review.developerDirectory], timeout: timeout)
                if !records.contains(where: { $0.identifier == review.runtime.identifier }) { return .removed }
                result = .stillPresent
            } catch ProcessError.timedOut {
                result = .unavailable("The runtime inventory command reached its time limit.")
            } catch { result = .unavailable(String(describing: error)) }
            let remainingAfterCheck = clock.now.duration(to: deadline)
            guard remainingAfterCheck >= .seconds(1) else { return result }
            do { try await Task.sleep(for: .milliseconds(250)) }
            catch { return result }
        } while true
    }

    func isStillSafe(_ review: SimulatorRuntimeReview) async throws -> Bool {
        let current = try await snapshot()
        guard let runtime = current.runtimes.first(where: { $0.identifier == review.runtime.identifier }) else { return false }
        let fresh = current.review(runtime)
        return fresh.protectionExplanation == nil && fresh == review && fresh.toolsAreUnchanged
    }

    static func retainedImageGuidance(developerDirectory: String) -> String? {
        let fix = "Apple lists a fix in Xcode 27.2."
        let unknownVersion = "Older Xcode versions can have this simulator deletion issue. \(fix) "
            + "If you use an older version, update Xcode before you retry removal in Xcode Components."
        guard developerDirectory.hasPrefix("/") else { return unknownVersion }
        let infoURL = URL(fileURLWithPath: developerDirectory).deletingLastPathComponent().appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode",
              let version = info["CFBundleShortVersionString"] as? String else { return unknownVersion }
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.compactMap { Int($0) }
        guard !numbers.isEmpty, numbers.count == parts.count, numbers.allSatisfy({ $0 >= 0 }) else { return unknownVersion }
        guard version.compare("27.2", options: .numeric) == .orderedAscending else { return nil }
        return "This can result from an Xcode \(version) issue. \(fix) "
            + "After you update Xcode, retry removal in Xcode Components."
    }

    static func downloadEntries(in roots: [URL], registeredRuntimes: [SimulatorRuntimeReview.Runtime]?,
                                context: ScanContext, removalGuidance: String? = nil) async throws -> (entries: [FileEntry], unreadableCount: Int) {
        struct AssetInfo: Decodable {
            let CFBundleIdentifier: String
            let MobileAssetProperties: Properties?

            struct Properties: Decodable {
                let SimulatorVersion: String?
                let Build: String?
            }
        }
        let manager = FileManager.default
        var context = context
        context.excludedPaths = Array(Set(context.excludedPaths.flatMap { path in
            [path, FileIdentity.physicalPath(path), URL(fileURLWithPath: path).resolvingSymlinksInPath().path]
        }))
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var represented = Set((registeredRuntimes ?? []).compactMap(\.storageKey))
        var entries: [FileEntry] = []
        var unreadableCount = 0
        for root in roots {
            try Task.checkCancellation()
            guard !context.isWithinExclusion(root), !context.isWithinExclusion(root.resolvingSymlinksInPath()),
                  !FileIdentity.isAbsent(root) else { continue }
            let assets: [URL]
            do { assets = try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)).sorted { $0.path < $1.path } }
            catch { unreadableCount += 1; continue }
            for asset in assets where asset.pathExtension == "asset" {
                try Task.checkCancellation()
                guard !context.isWithinExclusion(asset), !context.isWithinExclusion(asset.resolvingSymlinksInPath()) else { continue }
                do {
                    let values = try asset.resourceValues(forKeys: keys)
                    guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
                    let infoURL = asset.appendingPathComponent("Info.plist")
                    guard !context.isExcluded(infoURL) else { continue }
                    let infoValues = try infoURL.resourceValues(forKeys: keys)
                    guard infoValues.isRegularFile == true, infoValues.isSymbolicLink != true,
                          let infoSize = infoValues.fileSize, infoSize <= 1_048_576 else { unreadableCount += 1; continue }
                    let info = try PropertyListDecoder().decode(AssetInfo.self, from: Data(contentsOf: infoURL))
                    guard info.CFBundleIdentifier == "com.apple.MobileAsset.iOSSimulatorRuntime" else { continue }
                    let dataURL = asset.appendingPathComponent("AssetData")
                    let dataValues = try dataURL.resourceValues(forKeys: keys)
                    guard dataValues.isDirectory == true, dataValues.isSymbolicLink != true else { continue }
                    let images = try manager.contentsOfDirectory(at: dataURL, includingPropertiesForKeys: Array(keys))
                    for image in images.sorted(by: { $0.path < $1.path }) where image.pathExtension.lowercased() == "dmg" {
                        try Task.checkCancellation()
                        guard !context.isExcluded(image), !context.isExcluded(image.resolvingSymlinksInPath()) else { continue }
                        let imageValues = try image.resourceValues(forKeys: keys)
                        guard imageValues.isRegularFile == true, imageValues.isSymbolicLink != true else { continue }
                        let key = FileIdentity.of(image) ?? image.resolvingSymlinksInPath().path
                        guard represented.insert(key).inserted else { continue }
                        let size = try await context.measurer.measure(image)
                        unreadableCount += size.unreadableCount
                        guard !size.containsProtectedPattern, !size.containsCloudOnlyItem else { continue }
                        entries.append(.simulatorRuntimeDownload(url: image,
                            version: info.MobileAssetProperties?.SimulatorVersion, build: info.MobileAssetProperties?.Build,
                            allocatedBytes: size.allocatedBytes, runtimeRegistrationKnown: registeredRuntimes != nil,
                            removalGuidance: removalGuidance))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { unreadableCount += 1 }
            }
        }
        return (entries, unreadableCount)
    }

    private static func requiredBuilds(_ data: Data) throws -> Set<String> {
        struct Match: Decodable {
            let chosenRuntimeBuild: String
            let platform: String
        }
        let matches = try JSONDecoder().decode([String: Match].self, from: data)
        guard !matches.isEmpty else { throw InventoryError.invalidInventory }
        return try Set(matches.values.map { match in
            let platform: String
            switch match.platform {
            case "com.apple.platform.iphoneos", "com.apple.platform.iphonesimulator": platform = "iOS"
            case "com.apple.platform.appletvos", "com.apple.platform.appletvsimulator": platform = "tvOS"
            case "com.apple.platform.watchos", "com.apple.platform.watchsimulator": platform = "watchOS"
            case "com.apple.platform.xros", "com.apple.platform.xrsimulator": platform = "visionOS"
            default: throw InventoryError.invalidInventory
            }
            guard !match.chosenRuntimeBuild.isEmpty else { throw InventoryError.invalidInventory }
            return "\(platform):\(match.chosenRuntimeBuild)"
        })
    }

    private static func activeRuntimes(_ data: Data) throws -> Set<String> {
        struct Device: Decodable { let state: String }
        struct Devices: Decodable { let devices: [String: [Device]] }
        let devices = try JSONDecoder().decode(Devices.self, from: data)
        // Transitional and unknown states can still use a runtime.
        return Set(devices.devices.filter { $0.value.contains { $0.state != "Shutdown" } }.keys)
    }

    private static func developerDirectories() async throws -> [URL] {
        let selected: String
        if let override = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !override.isEmpty {
            selected = override.hasSuffix(".app") ? override + "/Contents/Developer" : override
        } else {
            let data = try await ProcessRunner().run("/usr/bin/xcode-select", ["-p"], timeout: .seconds(5), allowsInput: false)
            selected = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard selected.hasPrefix("/"), FileManager.default.fileExists(atPath: selected) else {
            throw InventoryError.invalidToolchain
        }
        let registered = LSCopyApplicationURLsForBundleIdentifier("com.apple.dt.Xcode" as CFString, nil)?
            .takeRetainedValue() as? [URL] ?? []
        let roots = [URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let applications = try AppUninstallPlanner.installedApplications(in: roots, fileManager: .default,
            requireCompleteInventory: true,
            checkCancellation: { try Task.checkCancellation() })
        let xcodes = try (registered + applications).filter {
            guard FileManager.default.fileExists(atPath: $0.path) else { return false }
            let plist = $0.appendingPathComponent("Contents/Info.plist")
            if !FileManager.default.fileExists(atPath: plist.path) { return false }
            let data = try Data(contentsOf: plist)
            let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            return info?["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode"
        }
        let first = URL(fileURLWithPath: selected).resolvingSymlinksInPath()
        let others = Set(xcodes.map { $0.appendingPathComponent("Contents/Developer").resolvingSymlinksInPath() })
            .subtracting([first]).sorted { $0.path < $1.path }
        return [first] + others
    }
}
