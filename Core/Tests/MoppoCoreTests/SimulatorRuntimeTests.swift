import Foundation
import Testing
@testable import MoppoCore

@Suite("Simulator runtime removal")
struct SimulatorRuntimeTests {
    private actor InventorySequence {
        private let responses: [Result<Data, ProcessError>]
        private(set) var count = 0
        private(set) var timeouts: [Duration] = []

        init(_ responses: [Data]) { self.responses = responses.map { .success($0) } }
        init(results: [Result<Data, ProcessError>]) { responses = results }

        func next(timeout: Duration) throws -> Data {
            timeouts.append(timeout)
            defer { count += 1 }
            return try responses[min(count, responses.count - 1)].get()
        }
    }

    private final class Fixture: Sendable {
        let root: URL
        let asset: URL
        let developer: URL
        let otherDeveloper: URL
        let executable: URL
        let downloadsRoot: URL
        let id = "62F84A00-333C-4895-B0A5-C19C5717C4EF"
        let otherID = "62F84A00-333C-4895-B0A5-C19C5717C4EE"
        let patchable: Bool

        /// A patchable runtime uses an `AssetData` folder as its backing storage instead of one image file.
        init(patchable: Bool = false) throws {
            self.patchable = patchable
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("moppo-runtime-\(UUID())")
            developer = root.appendingPathComponent("Xcode.app/Contents/Developer")
            otherDeveloper = root.appendingPathComponent("Xcode-beta.app/Contents/Developer")
            executable = root.appendingPathComponent("simctl")
            downloadsRoot = root.appendingPathComponent("AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime")
            try FileManager.default.createDirectory(at: developer, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: otherDeveloper, withIntermediateDirectories: true)
            try Data("stub executable".utf8).write(to: executable)
            if patchable {
                asset = try Self.writeDownload(in: downloadsRoot, name: "installed",
                    identifier: "com.apple.MobileAsset.iOSSimulatorRuntime", patchable: true)
            } else {
                asset = root.appendingPathComponent("runtime.dmg")
                try Data(repeating: 1, count: 65_536).write(to: asset)
            }
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func writeXcodeVersion(_ version: String) throws {
            let data = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": "com.apple.dt.Xcode", "CFBundleShortVersionString": version,
            ], format: .binary, options: 0)
            try data.write(to: developer.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        }

        /// Returns the image file, or the `AssetData` folder for a patchable download.
        func download(_ name: String, identifier: String = "com.apple.MobileAsset.iOSSimulatorRuntime",
                      patchable: Bool = false) throws -> URL {
            try Self.writeDownload(in: downloadsRoot, name: name, identifier: identifier, patchable: patchable)
        }

        private static func writeDownload(in downloadsRoot: URL, name: String, identifier: String,
                                          patchable: Bool) throws -> URL {
            let asset = downloadsRoot.appendingPathComponent(name + ".asset")
            let data = asset.appendingPathComponent("AssetData")
            let images = patchable ? data.appendingPathComponent("Restore") : data
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            let info = try PropertyListSerialization.data(fromPropertyList: [
                "CFBundleIdentifier": identifier,
                "MobileAssetProperties": ["Build": "22B81", "SimulatorVersion": "18.1"],
            ], format: .binary, options: 0)
            try info.write(to: asset.appendingPathComponent("Info.plist"))
            let image = images.appendingPathComponent("runtime.dmg")
            try Data(repeating: 1, count: 65_536).write(to: image)
            guard patchable else { return image }
            try Data("signing data".utf8).write(to: images.appendingPathComponent("BuildManifest.plist"))
            return data
        }

        func inventory(present: Bool = true, change: [String: Any] = [:], shared: Bool = false) throws -> Data {
            var record: [String: Any] = [
                "identifier": id, "runtimeIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-1",
                "platformIdentifier": "com.apple.platform.iphonesimulator", "version": "18.1", "build": "22B81",
                "state": "Ready", "kind": "Cryptex Disk Image", "deletable": true, "signatureState": "Verified",
                "path": root.appendingPathComponent("mounted/runtime.dmg").path, "parentImagePath": asset.path,
                "parentIdentifier": "324583E4-BDE1-4144-97F2-45312BF695B0",
                "mountPath": root.appendingPathComponent("Volumes/iOS_22B81").path,
                "sizeBytes": 999_999_999
            ]
            if patchable {
                record["kind"] = "Patchable Cryptex Disk Image"
                record["signatureState"] = "Unknown"
                record["path"] = asset.path
                record["parentImagePath"] = nil
                record["parentIdentifier"] = nil
            }
            record.merge(change) { _, value in value }
            var records = present ? [id: record] : [:]
            if shared {
                record["identifier"] = otherID
                records[otherID] = record
            }
            return try JSONSerialization.data(withJSONObject: records)
        }

        func service(change: [String: String] = [:], required: Bool = false, active: Bool = false,
                     failedMatch: Bool = false, shared: Bool = false, discoveryFails: Bool = false,
                     inventoryData: Data? = nil, inventorySequence: InventorySequence? = nil,
                     verificationTimeout: Duration = .zero) -> SimulatorRuntimeService {
            SimulatorRuntimeService(run: { [self] command, arguments, environment, timeout in
                #expect(command == "/usr/bin/xcrun")
                switch arguments {
                case ["--find", "simctl"]: return Data(executable.path.utf8)
                case ["simctl", "runtime", "list", "--json"]:
                    if let inventorySequence { return try await inventorySequence.next(timeout: timeout) }
                    if let inventoryData { return inventoryData }
                    return try inventory(present: FileManager.default.fileExists(atPath: asset.path), change: change, shared: shared)
                case ["simctl", "runtime", "match", "list", "--json"]:
                    if failedMatch { throw SimulatorRuntimeService.InventoryError.invalidInventory }
                    let build = required && environment["DEVELOPER_DIR"] == otherDeveloper.path ? "22B81" : "24A430"
                    return Data("{\"iphoneos27.0\":{\"platform\":\"com.apple.platform.iphoneos\",\"chosenRuntimeBuild\":\"\(build)\"}}".utf8)
                case ["simctl", "list", "devices", "--json"]:
                    let state = active ? "Booted" : "Shutdown"
                    return Data("{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-18-1\":[{\"state\":\"\(state)\"}]}}".utf8)
                default: throw SimulatorRuntimeService.InventoryError.invalidInventory
                }
            }, discover: { [self] in
                if discoveryFails { throw SimulatorRuntimeService.InventoryError.invalidToolchain }
                return [developer, otherDeveloper]
            }, verificationTimeout: verificationTimeout)
        }

        func scanner(_ service: SimulatorRuntimeService, assetRoots: [URL] = []) -> XcodeScanner {
            var scanner = XcodeScanner(developerRoot: root.appendingPathComponent("unused"), projectRoots: [],
                systemSimulatorRoot: root, temporaryRoots: [], simulatorAssetRoots: assetRoots)
            scanner.simulatorRuntimes = service
            return scanner
        }

        func entry(_ service: SimulatorRuntimeService) async throws -> FileEntry {
            try #require(try await scanner(service).scan(context: ScanContext()).entries.first)
        }

        func remover(_ service: SimulatorRuntimeService, status: Int32 = 0, removesAsset: Bool = true) -> ToolCommandRemovalService {
            ToolCommandRemovalService(run: { [self] review in
                #expect(review.executable == "/usr/bin/xcrun")
                #expect(review.arguments == ["simctl", "runtime", "delete", id])
                #expect(review.environment == ["DEVELOPER_DIR": developer.path])
                if removesAsset { try FileManager.default.removeItem(at: asset) }
                return ProcessResult(output: Data(), standardError: status == 0 ? "" : "runtime is busy",
                    exitStatus: status, completion: .exited, terminatedBySignal: false, outputReadError: nil)
            }, runtimes: service)
        }
    }

    @Test("Runtime rows measure backing storage and respect runtime path exclusions", arguments: [false, true])
    func inventoryAndSizes(patchable: Bool) async throws {
        let fixture = try Fixture(patchable: patchable)
        let scanner = fixture.scanner(fixture.service())
        let result = try await scanner.scan(context: ScanContext())
        let row = try #require(result.entries.first)
        #expect(row.displayName == "iOS 18.1 Simulator Runtime (22B81)")
        #expect(row.id == "simulator-runtime:\(fixture.id)")
        #expect(row.allocatedBytes > 0 && row.allocatedBytes < 999_999_999)
        #expect(row.displayBytes == row.allocatedBytes)
        #expect(!row.isRemovalLocked)
        #expect(!row.regeneratesSafely)
        #expect(row.toolCommand?.arguments.last == fixture.id)
        #expect(result.totalBytes == row.allocatedBytes)
        #expect(result.filteringNoise(below: Int64.max).entries.map(\.id) == [row.id])
        let excluded = try await scanner.scan(context: ScanContext(excludedPaths: [fixture.root.appendingPathComponent("Volumes").path]))
        #expect(excluded.entries.isEmpty)
        let protected = try await scanner.scan(context: ScanContext(excludedPatterns: ["*.dmg"]))
        #expect(protected.entries.isEmpty)
    }

    @Test("A fresh scan lists retained simulator downloads and refuses file removal", arguments: [false, true])
    func retainedDownloadInventory(patchable: Bool) async throws {
        let fixture = try Fixture()
        try fixture.writeXcodeVersion("27.1")
        let image = try fixture.download("retained", patchable: patchable)
        let scanner = fixture.scanner(fixture.service(inventoryData: Data("{}".utf8)), assetRoots: [fixture.downloadsRoot])
        let result = try await scanner.scan(context: ScanContext())
        let row = try #require(result.entries.first)
        let measured = try await AllocatedSizeMeasurer().measure(image)
        #expect(result.entries.count == 1)
        #expect(row.displayName == "Simulator Runtime Download 18.1 (22B81)")
        #expect(FileIdentity.of(row.url) == FileIdentity.of(image))
        #expect(row.displayBytes == measured.allocatedBytes)
        #expect(result.totalBytes == measured.allocatedBytes)
        #expect(row.isRemovalLocked)
        #expect(row.toolCommand == nil)
        #expect(!row.regeneratesSafely)
        #expect(row.protectionExplanation?.contains("without an installed runtime") == true)
        #expect(row.protectionExplanation?.contains("Xcode 27.1") == true)
        #expect(row.protectionExplanation?.contains("Apple lists a fix in Xcode 27.2.") == true)
        #expect(result.filteringNoise(below: Int64.max).entries.count == 1)
        let log = RemovalLog(directory: fixture.root.appendingPathComponent("history"))
        let removal = try await CleanupService(log: log).remove(entries: [row], trashFirst: false,
            userDataRemovalOverrides: [row.id])
        #expect(removal.failed == [row.id])
        #expect(FileManager.default.fileExists(atPath: image.path))
        let excluded = try await scanner.scan(context: ScanContext(excludedPaths: [image.path]))
        #expect(excluded.entries.isEmpty)
        let protected = try await scanner.scan(context: ScanContext(excludedPatterns: ["*.dmg"]))
        #expect(protected.entries.isEmpty)
    }

    @Test("Registered runtime images are not counted again as downloads", arguments: [false, true])
    func registeredDownloadOverlap(patchable: Bool) async throws {
        let fixture = try Fixture(patchable: patchable)
        let change = patchable ? [:] : ["parentImagePath": try fixture.download("installed").path]
        let scanner = fixture.scanner(fixture.service(change: change), assetRoots: [fixture.downloadsRoot])
        let result = try await scanner.scan(context: ScanContext())
        #expect(result.entries.count == 1)
        #expect(result.entries.first?.toolCommand != nil)
        let excluded = try await scanner.scan(context: ScanContext(excludedPaths: [fixture.root.appendingPathComponent("Volumes").path]))
        #expect(excluded.entries.isEmpty)
    }

    @Test("Download discovery validates metadata, rejects links, and counts shared files once")
    func downloadMetadataAndLinks() async throws {
        let fixture = try Fixture()
        let image = try fixture.download("first")
        let duplicate = try fixture.download("duplicate")
        try FileManager.default.removeItem(at: duplicate)
        try FileManager.default.linkItem(at: image, to: duplicate)
        let linked = try fixture.download("linked")
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: image)
        _ = try fixture.download("unrelated", identifier: "com.apple.MobileAsset.Other")
        let malformed = try fixture.download("malformed")
        let info = malformed.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        try Data("invalid metadata".utf8).write(to: info)
        let scanner = fixture.scanner(fixture.service(inventoryData: Data("{}".utf8)), assetRoots: [fixture.downloadsRoot])
        let result = try await scanner.scan(context: ScanContext())
        let measured = try await AllocatedSizeMeasurer().measure(image)
        #expect(result.entries.count == 1)
        #expect(result.totalBytes == measured.allocatedBytes)
        #expect(result.unreadableCount == 1)
        #expect(result.entries.first?.isRemovalLocked == true)
    }

    @Test("Downloads stay protected when runtime registration cannot be checked")
    func downloadWithUnavailableRuntimeInventory() async throws {
        let fixture = try Fixture()
        let image = try fixture.download("retained")
        let scanner = fixture.scanner(fixture.service(inventoryData: Data("invalid inventory".utf8)), assetRoots: [fixture.downloadsRoot])
        let result = try await scanner.scan(context: ScanContext())
        let identity = try #require(FileIdentity.of(image))
        let row = try #require(result.entries.first { FileIdentity.of($0.url) == identity })
        #expect(result.entries.count == 2)
        #expect(row.isRemovalLocked)
        #expect(row.protectionExplanation?.contains("cannot verify") == true)
        #expect(row.protectionExplanation?.contains("Apple lists a fix") == false)
        #expect(row.toolCommand == nil)
    }

    @Test("Retained image guidance uses the selected Xcode version",
          arguments: ["26.4.1", "27.1", "27.2", "27.2.1", "27.10", "28.0", "not a version"])
    func retainedImageVersionGuidance(version: String) throws {
        let fixture = try Fixture()
        let missing = try #require(SimulatorRuntimeService.retainedImageGuidance(developerDirectory: fixture.developer.path))
        #expect(missing.contains("If you use an older version"))
        try fixture.writeXcodeVersion(version)
        let guidance = SimulatorRuntimeService.retainedImageGuidance(developerDirectory: fixture.developer.path)
        switch version {
        case "27.2", "27.2.1", "27.10", "28.0": #expect(guidance == nil)
        case "not a version": #expect(guidance == missing)
        default:
            #expect(guidance?.contains("Xcode \(version)") == true)
            #expect(guidance?.contains("Apple lists a fix in Xcode 27.2.") == true)
            #expect(guidance?.contains("retry removal in Xcode Components") == true)
        }
    }

    @Test("Every installed Xcode version protects its chosen runtime")
    func requiredByOtherXcode() async throws {
        let fixture = try Fixture()
        let row = try await fixture.entry(fixture.service(required: true))
        #expect(row.isRemovalLocked)
        #expect(row.protectionExplanation?.contains("installed Xcode") == true)
        #expect(row.displayBytes > 0)
        #expect(!CleanupService.removalAllowed(row, userDataRemovalOverrides: [row.id]))
    }

    @Test("Active devices, incomplete checks, and unsupported runtimes remain protected")
    func protectedInventories() async throws {
        let fixture = try Fixture()
        let services = [fixture.service(active: true), fixture.service(failedMatch: true),
            fixture.service(discoveryFails: true), fixture.service(change: ["state": "Mounting"]),
            fixture.service(change: ["platformIdentifier": "com.apple.platform.unknown"])]
        for service in services {
            let row = try await fixture.entry(service)
            #expect(row.isRemovalLocked)
            #expect(row.protectionExplanation != nil)
        }
    }

    @Test("Patchable runtimes need the MobileAsset folder layout and a known signature state")
    func patchableRuntimeChecks() async throws {
        let fixture = try Fixture(patchable: true)
        let elsewhere = fixture.root.appendingPathComponent("Elsewhere/AssetData")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        for change in [["signatureState": "Invalid"], ["path": elsewhere.path], ["kind": "Cryptex Disk Image"]] {
            let row = try await fixture.entry(fixture.service(change: change))
            #expect(row.isRemovalLocked)
            #expect(row.protectionExplanation != nil)
        }
    }

    @Test("Shared backing assets appear once in totals and have distinct protected rows")
    func sharedAsset() async throws {
        let fixture = try Fixture()
        let result = try await fixture.scanner(fixture.service(shared: true)).scan(context: ScanContext())
        #expect(result.entries.count == 2)
        #expect(Set(result.entries.map(\.id)).count == 2)
        #expect(result.entries.allSatisfy { $0.isRemovalLocked })
        let measured = try await AllocatedSizeMeasurer().measure(fixture.asset)
        #expect(result.totalBytes == measured.allocatedBytes)
        #expect(result.filteringNoise(below: Int64.max).entries.count == 2)
    }

    @Test("Malformed inventories stay visible and cannot enable removal")
    func malformedInventory() async throws {
        let fixture = try Fixture()
        for data in [Data("not JSON".utf8), try fixture.inventory(change: ["identifier": "all"])] {
            let result = try await fixture.scanner(fixture.service(inventoryData: data)).scan(context: ScanContext())
            let row = try #require(result.entries.first)
            #expect(row.displayName == "Simulator runtime inventory unavailable")
            #expect(row.isRemovalLocked)
            #expect(row.toolCommand == nil)
            #expect(result.unreadableCount == 1)
            #expect(result.filteringNoise(below: Int64.max).entries.count == 1)
        }
    }

    @Test("Runtime removal records permanent History with receipts off", arguments: [false, true])
    func removalAndHistory(patchable: Bool) async throws {
        let fixture = try Fixture(patchable: patchable)
        let service = fixture.service()
        let row = try await fixture.entry(service)
        let command = try #require(row.toolCommand)
        let log = RemovalLog(directory: fixture.root.appendingPathComponent("history"))
        let cleaner = CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: log,
            toolCommands: fixture.remover(service))
        let outcome = try await cleaner.remove(entries: [row], trashFirst: true, keepReceipt: false,
            confirmedToolCommands: [row.id: command])
        let result = try #require(outcome.toolCommandResults.first)
        #expect(result.status == .completed)
        #expect(result.afterBytes == 0)
        #expect(result.removedBytes == row.allocatedBytes)
        #expect(outcome.deletedCount == 1 && outcome.trashedCount == 0)
        #expect(CleanupHistoryService(log: log).summary().items.first?.state == .removedPermanently)
        #expect(log.recentEntries().first?.trashedPath == nil)
    }

    @Test("Delayed runtime removal retries a timed out check and retains accurate storage results")
    func delayedRemovalWithRetainedImage() async throws {
        let fixture = try Fixture()
        try fixture.writeXcodeVersion("27.1")
        let row = try await fixture.entry(fixture.service())
        let command = try #require(row.toolCommand)
        let listed = try fixture.inventory()
        let inventory = InventorySequence(results: [.success(listed), .success(listed),
            .failure(.timedOut("/usr/bin/xcrun simctl runtime list --json")), .success(Data("{}".utf8))])
        let service = fixture.service(inventorySequence: inventory, verificationTimeout: .seconds(20))
        let log = RemovalLog(directory: fixture.root.appendingPathComponent("history"))
        let cleaner = CleanupService(measureSize: { try await AllocatedSizeMeasurer().measure($0) }, log: log,
            toolCommands: fixture.remover(service, removesAsset: false))
        let outcome = try await cleaner.remove(entries: [row], trashFirst: true, keepReceipt: false,
            confirmedToolCommands: [row.id: command])
        let result = try #require(outcome.toolCommandResults.first)
        #expect(await inventory.count == 4)
        #expect(await inventory.timeouts.allSatisfy { $0 == .seconds(10) })
        #expect(result.status == .completed)
        #expect(result.afterBytes == row.allocatedBytes)
        #expect(result.removedBytes == 0)
        #expect(result.freedBytes == nil)
        #expect(result.remainingStorageReason?.contains("macOS still stores the downloaded image") == true)
        #expect(result.summary.contains("Xcode 27.1"))
        #expect(result.summary.contains("Apple lists a fix in Xcode 27.2."))
        #expect(!result.summary.contains("Item storage decreased by 0 B"))
        #expect(result.summary.contains("is no longer installed. Cleanup is incomplete."))
        #expect(result.summary.contains("This space remains on disk."))
        #expect(!result.summary.contains("was removed permanently"))
        #expect(!result.summary.contains("Exit status: 0"))
        #expect(result.standardError.isEmpty)
        #expect(outcome.failed.isEmpty)
        #expect(outcome.deletedCount == 1 && outcome.freedBytes == 0)
        #expect(outcome.unreportedFreedCount == 1)
        let history = CleanupHistoryService(log: log).summary()
        #expect(history.items.first?.state == .removedPermanently)
        #expect(history.items.first?.toolCommandResult == result)
        #expect(history.availableInTrashCount == 0)
        #expect(FileManager.default.fileExists(atPath: fixture.asset.path))
    }

    @Test("A short verification budget does not start a process with a tiny deadline")
    func shortVerificationBudget() async throws {
        let fixture = try Fixture()
        let row = try await fixture.entry(fixture.service())
        let review = try #require(row.toolCommand?.simulatorRuntime)
        let inventory = InventorySequence([try fixture.inventory()])
        let service = fixture.service(inventorySequence: inventory, verificationTimeout: .milliseconds(100))
        guard case .stillPresent = await service.verifyRemoval(review) else {
            Issue.record("The completed inventory check must remain the verification result.")
            return
        }
        #expect(await inventory.timeouts == [.seconds(1)])
    }

    @Test("Unavailable verification preserves its diagnostic and does not claim success", arguments: [true, false])
    func unavailableVerification(timedOut: Bool) async throws {
        let fixture = try Fixture()
        let row = try await fixture.entry(fixture.service())
        let command = try #require(row.toolCommand)
        let response: Result<Data, ProcessError> = timedOut
            ? .failure(.timedOut("/usr/bin/xcrun simctl runtime list --json"))
            : .success(Data("invalid inventory".utf8))
        let inventory = InventorySequence(results: [.success(try fixture.inventory()), response])
        let service = fixture.service(inventorySequence: inventory)
        let result = await fixture.remover(service, removesAsset: false).remove(row, review: command, confirmed: command)
        #expect(result.status == .failed)
        #expect(result.failureReason == "Runtime removal could not be verified. Scan again.")
        #expect(!result.standardError.isEmpty)
        if timedOut {
            #expect(result.standardError == "The runtime inventory command reached its time limit.")
        }
        #expect(result.freedBytes == nil)
        #expect(result.remainingStorageReason != nil)
        #expect(!result.summary.contains("Apple lists a fix"))
        #expect(result.summary.contains("This space remains on disk."))
        #expect(!result.summary.contains("Item storage decreased by 0 B"))
        #expect(!result.summary.contains("Exit status: 0"))
    }

    @Test("Fresh runtime identity, Xcode requirements, and active device checks prevent execution")
    func changedReview() async throws {
        let fixture = try Fixture()
        let row = try await fixture.entry(fixture.service())
        let command = try #require(row.toolCommand)
        for service in [fixture.service(change: ["build": "22B82"]), fixture.service(required: true),
            fixture.service(active: true), fixture.service(failedMatch: true)] {
            let result = await fixture.remover(service).remove(row, review: command, confirmed: command)
            #expect(result.status == .notStarted)
            #expect(result.exitStatus == nil)
            #expect(FileManager.default.fileExists(atPath: fixture.asset.path))
        }
    }

    enum ChangedFile: CaseIterable { case image, patchableFolder, toolchain }

    @Test("Changed backing images and toolchains reject an earlier review", arguments: ChangedFile.allCases)
    func changedFiles(change: ChangedFile) async throws {
        let fixture = try Fixture(patchable: change == .patchableFolder)
        let service = fixture.service()
        let row = try await fixture.entry(service)
        let command = try #require(row.toolCommand)
        switch change {
        case .image: try Data("changed file".utf8).write(to: fixture.asset)
        case .toolchain: try Data("changed file".utf8).write(to: fixture.executable)
        case .patchableFolder:
            try FileManager.default.removeItem(at: fixture.asset)
            try FileManager.default.createDirectory(at: fixture.asset, withIntermediateDirectories: true)
        }
        let result = await fixture.remover(service).remove(row, review: command, confirmed: command)
        #expect(result.status == .notStarted)
        #expect(result.exitStatus == nil)
    }

    @Test("A successful command must remove the runtime from the inventory", arguments: [true, false])
    func retainedRuntime(removesAsset: Bool) async throws {
        let fixture = try Fixture()
        let service = fixture.service(inventoryData: try fixture.inventory())
        let row = try await fixture.entry(service)
        let command = try #require(row.toolCommand)
        let result = await fixture.remover(service, removesAsset: removesAsset).remove(row, review: command, confirmed: command)
        #expect(result.status == .failed)
        #expect(result.exitStatus == 0)
        #expect(result.removedBytes == (removesAsset ? row.allocatedBytes : 0))
        #expect(result.freedBytes == nil)
    }

    @Test("Command failures retain runtime storage and error output")
    func commandFailure() async throws {
        let fixture = try Fixture()
        let service = fixture.service()
        let row = try await fixture.entry(service)
        let command = try #require(row.toolCommand)
        let result = await fixture.remover(service, status: 23, removesAsset: false).remove(row, review: command, confirmed: command)
        #expect(result.status == .failed)
        #expect(result.standardError == "runtime is busy")
        #expect(result.afterBytes == row.allocatedBytes)
        #expect(FileManager.default.fileExists(atPath: fixture.asset.path))
    }
}
