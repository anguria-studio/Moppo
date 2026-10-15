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
            let size = try await render(cards, width: width, dark: dark, name: "cards-\(Int(width))")
            #expect(abs(size.width - width) < 0.5)
            #expect(size.height < 1100)
        }
        let model = DashboardModel()
        let sheet = ICloudSetupView(model: model, access: .preview())
        let sheetSize = try await render(sheet, width: 560, dark: dark, name: "setup")
        #expect(sheetSize.height < 540)
        let unavailable = DashboardModel(service: UnavailableICloudMeasurements())
        await unavailable.loadICloud()
        let recoverySheet = ICloudSetupView(model: unavailable, access: .preview(disk: true))
        let recoverySize = try await render(recoverySheet, width: 560, dark: dark, name: "setup-account")
        #expect(recoverySize.height < 540)
        let settings = SettingsStore.preview()
        let preferences = ICloudPreferences(settings: settings, dashboard: model, access: .preview())
            .padding(26).background(Token.pageBackground)
        let settingsSize = try await render(preferences, width: 660, dark: dark, name: "settings")
        #expect(settingsSize.height < PrefMetrics.paneHeight)
    }

    private func render<V: View>(_ view: V, width: CGFloat, dark: Bool, name: String) async throws -> CGSize {
        let host = NSHostingView(rootView: view
            .environment(\.colorScheme, dark ? .dark : .light)
            .frame(width: width).fixedSize(horizontal: false, vertical: true))
        let height = host.fittingSize.height
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/moppo-189-\(name)-\(dark ? "dark" : "light").png"))
        return host.fittingSize
    }
}

private struct UnavailableICloudMeasurements: DashboardMeasuring {
    func volumeInfo() async throws -> VolumeInfo { throw CocoaError(.fileReadUnknown) }
    func snapshots() async throws -> [SnapshotInfo] { [] }
    func measure() async throws -> StorageMeasurement { throw CocoaError(.fileReadUnknown) }
    func iCloudStorage(planBytes: Int64?) async throws -> ICloudStorage { throw CocoaError(.fileReadUnknown) }
}
