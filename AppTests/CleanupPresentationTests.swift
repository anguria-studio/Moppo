import AppKit
import MoppoCore
import SwiftUI
import Testing

@Suite("Cleanup presentation", .serialized)
@MainActor
struct CleanupPresentationTests {
    @Test("The notice about older results leaves the sidebar and header visible", arguments: [false, true])
    func outdatedOverlay(dark: Bool) async throws {
        _ = NSApplication.shared
        let folder = try TemporaryFolder()
        let entry = FileEntry(url: try folder.write("Cached item"), kind: .file, allocatedBytes: 100)
        let model = AppModel(hasFullDiskAccess: { false })
        model.dashboard.canLoad = { false }
        model.cleanup.scanFilter = .all
        model.cleanup.scanResults = ScanResults(
            categories: [.init(categoryID: .systemCaches, totalBytes: 100, entries: [entry])],
            startedAt: .now, finishedAt: .now
        )
        let host = NSHostingView(rootView: MainWindow(model: model)
            .environment(\.scenePhase, .inactive)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 1120, height: 734),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        let before = try capture(host)
        model.cleanup.markResultsOutdated()
        try await Task.sleep(for: .milliseconds(100))
        let after = try capture(host)
        let scale = CGFloat(after.pixelsWide) / host.bounds.width
        let sidebar = CGRect(x: 0, y: 0, width: Token.Size.sidebarWidth * scale,
                             height: CGFloat(after.pixelsHigh))
        let header = CGRect(x: sidebar.maxX, y: 0,
                            width: CGFloat(after.pixelsWide) - sidebar.width,
                            height: Token.Size.headerBand * scale)
        #expect(try pixels(before, in: sidebar) == pixels(after, in: sidebar))
        #expect(try pixels(before, in: header) == pixels(after, in: header))
        #expect(before.tiffRepresentation != after.tiffRepresentation)
        let name = dark ? "dark" : "light"
        try after.representation(using: .png, properties: [:])?.write(
            to: URL(fileURLWithPath: "/tmp/moppo-cleanup-overlay-\(name).png")
        )
    }

    private func capture(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func pixels(_ bitmap: NSBitmapImageRep, in rect: CGRect) throws -> Data {
        let bytes = try #require(bitmap.bitmapData)
        let pixelBytes = bitmap.bitsPerPixel / 8
        var data = Data()
        for y in Int(rect.minY)..<Int(rect.maxY) {
            let offset = y * bitmap.bytesPerRow + Int(rect.minX) * pixelBytes
            data.append(bytes.advanced(by: offset), count: Int(rect.width) * pixelBytes)
        }
        return data
    }
}
