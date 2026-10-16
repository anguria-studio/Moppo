import AppKit
import SwiftUI
import Testing
@testable import MoppoCore

@Suite("iCloud setup presentation", .serialized)
@MainActor
struct ICloudPresentationTests {
    @Test("Cloud states, setup, and Settings fit both appearances", arguments: [false, true])
    func layouts(dark: Bool) async throws {
        let gib: Int64 = 1024 * 1024 * 1024
        let states: [DashboardModel.ICloudState] = [
            .idle, .loading, .unavailable,
            .available(ICloudStorage(totalBytes: 200 * gib, freeBytes: 148 * gib, documentsBytes: 6 * gib))
        ]
        for width in [788.0, 908.0] {
            let cards = VStack(spacing: 16) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    StatTiles(results: nil, iCloudState: state)
                }
                StatTiles(results: nil)
            }
            .padding(24)
            .background(Token.pageBackground)
            let size = try await renderTestView(cards, width: width, dark: dark, output: imageURL("cards-\(Int(width))", dark: dark))
            #expect(abs(size.width - width) < 0.5)
            #expect(size.height < 1100)
        }
        let model = DashboardModel()
        let sheet = ICloudSetupView(model: model, access: .preview())
        let sheetSize = try await renderTestView(sheet, width: 560, dark: dark, output: imageURL("setup", dark: dark))
        #expect(sheetSize.height < 540)
        let unavailable = DashboardModel(service: UnavailableICloudMeasurements())
        await unavailable.loadICloud()
        let recoverySheet = ICloudSetupView(model: unavailable, access: .preview(disk: true))
        let recoverySize = try await renderTestView(recoverySheet, width: 560, dark: dark, output: imageURL("setup-account", dark: dark))
        #expect(recoverySize.height < 540)
        let settings = SettingsStore.preview()
        let preferences = ICloudPreferences(settings: settings, dashboard: model, access: .preview())
            .padding(26).background(Token.pageBackground)
        let settingsSize = try await renderTestView(preferences, width: 660, dark: dark, output: imageURL("settings", dark: dark))
        #expect(settingsSize.height < PrefMetrics.paneHeight)
    }

    private func imageURL(_ name: String, dark: Bool) -> URL {
        URL(fileURLWithPath: "/tmp/moppo-189-\(name)-\(dark ? "dark" : "light").png")
    }
}

private struct UnavailableICloudMeasurements: DashboardMeasuring {
    func volumeInfo() async throws -> VolumeInfo { throw CocoaError(.fileReadUnknown) }
    func snapshots() async throws -> [SnapshotInfo] { [] }
    func measure() async throws -> StorageMeasurement { throw CocoaError(.fileReadUnknown) }
    func iCloudStorage(planBytes: Int64?) async throws -> ICloudStorage { throw CocoaError(.fileReadUnknown) }
}
