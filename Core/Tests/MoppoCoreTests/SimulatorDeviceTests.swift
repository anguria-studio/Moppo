import Foundation
import Testing
@testable import MoppoCore

@Suite("Simulator devices")
struct SimulatorDeviceTests {
    private final class Fixture: Sendable {
        let root: URL
        let developer: URL
        let toolchains: [URL]
        let simctl: URL

        init(toolchainCount: Int = 1) throws {
            let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("moppo-devices-\(UUID())")
            self.root = root
            developer = root.appendingPathComponent("Library/Developer")
            toolchains = (0..<toolchainCount).map { root.appendingPathComponent("Xcode\($0).app/Contents/Developer") }
            simctl = root.appendingPathComponent("simctl")
            for toolchain in toolchains {
                try FileManager.default.createDirectory(at: toolchain, withIntermediateDirectories: true)
            }
            try Data("stub executable".utf8).write(to: simctl)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        /// Writes a device folder with app data. A `nil` name writes no `device.plist`.
        @discardableResult
        func device(_ udid: String, name: String?, runtime: String = "iOS-18-1") throws -> URL {
            let folder = developer.appendingPathComponent("CoreSimulator/Devices/\(udid)")
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("data"), withIntermediateDirectories: true)
            try Data(repeating: 1, count: 65_536).write(to: folder.appendingPathComponent("data/app.db"))
            if let name {
                let plist = try PropertyListSerialization.data(fromPropertyList: [
                    "UDID": udid, "name": name, "runtime": "com.apple.CoreSimulator.SimRuntime.\(runtime)", "state": 1,
                ], format: .binary, options: 0)
                try plist.write(to: folder.appendingPathComponent("device.plist"))
            }
            return folder
        }

        /// `devices` gives the `simctl list devices` records for each toolchain, in toolchain order.
        func scanner(devices: [[[String: Any]]], discoveryFails: Bool = false) -> XcodeScanner {
            let lists = devices.map { list in
                try! JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-18-1": list]])
            }
            let directories = toolchains.map(\.path)
            let simctlPath = simctl.path
            let service = SimulatorRuntimeService(run: { _, arguments, environment, _ in
                switch arguments {
                case ["--find", "simctl"]: return Data(simctlPath.utf8)
                case ["simctl", "runtime", "match", "list", "--json"]:
                    return Data(#"{"iphoneos18.1":{"platform":"com.apple.platform.iphoneos","chosenRuntimeBuild":"22B81"}}"#.utf8)
                case ["simctl", "list", "devices", "--json"]:
                    return lists[directories.firstIndex(of: environment["DEVELOPER_DIR"] ?? "") ?? 0]
                case ["simctl", "runtime", "list", "--json"]:
                    let id = "62F84A00-333C-4895-B0A5-C19C5717C4EF"
                    return Data(#"{"\#(id)":{"identifier":"\#(id)","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-18-1"}}"#.utf8)
                default: throw SimulatorRuntimeService.InventoryError.invalidInventory
                }
            }, discover: { [toolchains] in
                if discoveryFails { throw SimulatorRuntimeService.InventoryError.invalidToolchain }
                return toolchains
            })
            var scanner = XcodeScanner(developerRoot: developer, projectRoots: [],
                systemSimulatorRoot: root.appendingPathComponent("no-runtimes"), temporaryRoots: [], simulatorAssetRoots: [])
            scanner.simulatorRuntimes = service
            return scanner
        }
    }

    private static func record(_ udid: String, available: Bool, state: String = "Shutdown") -> [String: Any] {
        ["udid": udid, "isAvailable": available, "state": state, "name": "Device"]
    }

    @Test("only a shut down device without an installed runtime counts as safe")
    func deviceAvailability() async throws {
        let fixture = try Fixture()
        let available = "11111111-1111-4111-8111-111111111111"
        let unavailable = "22222222-2222-4222-8222-222222222222"
        let booted = "33333333-3333-4333-8333-333333333333"
        let unreadable = "44444444-4444-4444-8444-444444444444"
        let installedRuntime = "55555555-5555-4555-8555-555555555555"
        try fixture.device(available, name: "iPhone 16")
        try fixture.device(unavailable, name: "Apple TV 4K", runtime: "tvOS-17-0")
        try fixture.device(booted, name: "Apple Watch", runtime: "watchOS-10-0")
        try fixture.device(unreadable, name: nil)
        try fixture.device(installedRuntime, name: "iPad Air")
        let scanner = fixture.scanner(devices: [[
            Self.record(available, available: true),
            Self.record(unavailable, available: false),
            Self.record(booted, available: false, state: "Booted"),
            Self.record(unreadable, available: false),
            // simctl can report a device as unavailable for another cause, such as an unsupported device type.
            Self.record(installedRuntime, available: false),
        ]])

        let result = try await scanner.scan(context: ScanContext())
        func row(_ udid: String) throws -> FileEntry {
            try #require(result.entries.first { $0.url.lastPathComponent == udid })
        }
        let appData = FileEntry.RegenerationLabel.notRegenerable(reason: XcodeScanner.simulatorAppData.reason)
        let expected: [(udid: String, name: String, summary: String, safe: Bool, label: FileEntry.RegenerationLabel?)] = [
            (available, "iPhone 16",
             "Simulator device · iOS 18.1 · Removal deletes the apps and app data in this simulator", false, appData),
            (unavailable, "Apple TV 4K", "Simulator device · tvOS 17.0 · Runtime not installed", true, .regenerable),
            (booted, "Apple Watch", "Simulator device · watchOS 10.0 · Simulator is running", false, appData),
            (unreadable, unreadable, "Simulator device · Availability could not be checked", false, nil),
            (installedRuntime, "iPad Air",
             "Simulator device · iOS 18.1 · Removal deletes the apps and app data in this simulator", false, appData),
        ]
        for item in expected {
            let entry = try row(item.udid)
            #expect(entry.displayName == item.name)
            #expect(FileEntryPresentation(entry: entry).summary == item.summary)
            #expect(result.isCountedSafe(entry) == item.safe, "\(item.name)")
            #expect(entry.regenerationLabel == item.label, "\(item.name)")
        }
        #expect(result.safeToRemoveBytes == (try row(unavailable)).allocatedBytes)
    }

    @Test("a failed simctl check keeps an unavailable device out of Safe to Remove")
    func failedInventory() async throws {
        let fixture = try Fixture()
        let udid = "22222222-2222-4222-8222-222222222222"
        try fixture.device(udid, name: "Apple TV 4K", runtime: "tvOS-17-0")
        let result = try await fixture.scanner(devices: [[Self.record(udid, available: false)]], discoveryFails: true)
            .scan(context: ScanContext())

        let entry = try #require(result.entries.first)
        #expect(entry.safetyCaveat == "Availability could not be checked")
        #expect(result.safeToRemoveBytes == 0)
    }

    @Test("a device that another Xcode can start is available")
    func availableInAnotherToolchain() async throws {
        let fixture = try Fixture(toolchainCount: 2)
        let udid = "22222222-2222-4222-8222-222222222222"
        try fixture.device(udid, name: "Apple TV 4K", runtime: "tvOS-17-0")
        let result = try await fixture.scanner(devices: [
            [Self.record(udid, available: false)], [Self.record(udid, available: true)],
        ]).scan(context: ScanContext())

        let entry = try #require(result.entries.first)
        #expect(entry.simulatorDevice?.availability == .available)
        #expect(result.safeToRemoveBytes == 0)
    }
}
