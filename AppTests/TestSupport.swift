import AppKit
import Foundation
import SwiftUI
import Testing
@testable import MoppoCore

/// Waits for asynchronous model work. The test stops when the deadline expires.
@MainActor
func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: () async -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !(await condition()), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition(), "The operation did not finish before the deadline.", sourceLocation: sourceLocation)
}

/// Sends a keyboard event to a test window.
@MainActor
func sendKey(
    _ characters: String, code: UInt16, to window: NSWindow
) throws {
    let event = try #require(NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil,
        characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: code
    ))
    NSApp.sendEvent(event)
}

/// Counts focus pixels with the accent color at the sidebar edge.
@MainActor
func sidebarFocusRingPixels(in host: NSView) throws -> Int {
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    var accent: NSColor?
    host.effectiveAppearance.performAsCurrentDrawingAppearance {
        accent = NSColor.controlAccentColor.usingColorSpace(bitmap.colorSpace)
    }
    let color = try #require(accent)
    let x = Int(11 * CGFloat(bitmap.pixelsWide) / host.bounds.width)
    return (0..<bitmap.pixelsHigh).count { y in
        guard let pixel = bitmap.colorAt(x: x, y: y) else { return false }
        return pixel.alphaComponent > 0.9
            && abs(pixel.redComponent - color.redComponent) < 0.06
            && abs(pixel.greenComponent - color.greenComponent) < 0.06
            && abs(pixel.blueComponent - color.blueComponent) < 0.06
    }
}


/// Holds an asynchronous call until the test releases it.
actor TestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var count = 0
    var isPending: Bool { continuation != nil }

    func wait() async {
        count += 1
        await withCheckedContinuation { continuation = $0 }
    }

    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

enum RemovalConfirmationChoice: CaseIterable {
    case disabled, confirm, cancel
    var isEnabled: Bool { self != .disabled }
}

/// Keeps removal preferences separate from the user's settings.
@MainActor
final class RemovalSettingsFixture {
    let settings: SettingsStore
    private let suite = "RemovalSettingsTests.\(UUID().uuidString)"

    init(confirm: Bool) throws {
        let defaults = try #require(UserDefaults(suiteName: suite))
        settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        settings.confirmBeforeCleanup = confirm
    }

    deinit { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
}

/// Creates a disposable folder and removes it when the test releases the folder.
final class TemporaryFolder {
    let url: URL

    init(prefix: String = "moppo-test") throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ name: String, contents: String = "Fixture") throws -> URL {
        let file = url.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return file
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

struct DiagnosticRecord: Decodable {
    let event: String
    let details: [String: String]
}

func diagnosticRecords(_ log: ScanDiagnostics) throws -> [DiagnosticRecord] {
    log.flush()
    return try Data(contentsOf: log.fileURL).split(separator: 10).map {
        try JSONDecoder().decode(DiagnosticRecord.self, from: Data($0))
    }
}

/// Supplies downloaded content for model tests without reading system libraries.
func soundLibraryItem() -> AppUninstallPlan.Item {
    let url = URL(fileURLWithPath: "/moppo-fixture/Library/Application Support/Logic")
    return .init(
        url: url, category: .support, content: .soundLibrary, allocatedBytes: 64,
        ownerBundleIdentifier: AppleSoundLibrary.garageBandIdentifier,
        soundLibrary: AppleSoundLibrary.Inventory(
            url: url, ownerIdentifiers: AppleSoundLibrary.ownerIdentifiers, permittedOwner: nil,
            applicationRoots: [], libraryRoot: url.deletingLastPathComponent(), identities: [:]
        )
    )
}

actor HeldCleanupScanner: CleanupScanning {
    private(set) var preferences: [CleanupModel.Preferences] = []
    private var scans: [Int: CheckedContinuation<ScanResults, any Error>] = [:]
    private var reports: [Int: @Sendable (ScanProgress) -> Void] = [:]
    var requestCount: Int { preferences.count }
    func scan(
        preferences: CleanupModel.Preferences,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResults {
        let index = requestCount
        self.preferences.append(preferences)
        reports[index] = onProgress
        return try await withCheckedThrowingContinuation { scans[index] = $0 }
    }
    func report(_ index: Int, percent: Int, phase: String? = nil) {
        reports[index]?(ScanProgress(percent: percent, completedCategories: 1, totalCategories: 2, phase: phase))
    }
    func finish(_ index: Int, results: ScanResults) { scans.removeValue(forKey: index)?.resume(returning: results) }
    func fail(_ index: Int) { scans.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadUnknown)) }
}

/// Finds native buttons in a hosted view.
@MainActor
func nativeButtons(in view: NSView) -> [NSButton] {
    if let button = view as? NSButton { return [button] }
    return view.subviews.flatMap(nativeButtons)
}

/// Renders a native view for layout checks. Give an output URL to save a PNG for visual review.
@MainActor
func renderTestView<V: View>(_ view: V, width: CGFloat, dark: Bool, output: URL? = nil) async throws -> CGSize {
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
    if let output {
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: output)
    }
    return host.fittingSize
}

func dashboardVolume(free: Int64 = 200) -> VolumeInfo {
    VolumeInfo(name: "Fixture", capacityBytes: 1000, freeBytes: free, filesystem: "apfs", isEncrypted: true)
}

func dashboardMeasurement(free: Int64 = 200) -> StorageMeasurement {
    let raw: [StorageSegmentID: Int64] = [.documentsDesktop: 1000 - free, .free: free]
    return StorageMeasurement(
        home: URL(fileURLWithPath: "/moppo-fixture"), volume: dashboardVolume(free: free),
        breakdown: .make(capacityBytes: 1000, rawSegments: raw, unreadableCount: 0), rawSegments: raw,
        homeTree: [:], rootMeasurements: [:], nodeDepth: 4
    )
}

/// Sends a pointer click to a view in a test window.
@MainActor
func click(_ point: NSPoint, in host: NSView, window: NSWindow) throws {
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
        ))
        NSApp.sendEvent(event)
    }
}
