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
    let defaults: UserDefaults
    private let suite = "RemovalSettingsTests.\(UUID().uuidString)"

    init(confirm: Bool) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
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

/// Finds scroll views in a hosted view.
@MainActor
func scrollViews(in view: NSView) -> [NSScrollView] {
    let current = (view as? NSScrollView).map { [$0] } ?? []
    return current + view.subviews.flatMap { scrollViews(in: $0) }
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


actor HeldCleanupRemoval: CleanupRemoving {
    private(set) var requestCount = 0
    private(set) var entries: [FileEntry] = []
    private(set) var overrides: Set<FileEntry.ID> = []
    private(set) var keepReceipt = true
    private(set) var trashFirst = false
    private(set) var confirmedToolCommands: [FileEntry.ID: ToolCommandRemoval] = [:]
    private(set) var wasCancelled = false
    private var continuation: CheckedContinuation<CleanupOutcome, Never>?
    var isPending: Bool { continuation != nil }
    func remove(
        entries: [FileEntry], trashFirst: Bool, keepReceipt: Bool,
        userDataRemovalOverrides: Set<FileEntry.ID>, appDataRemovalOverrides: Set<FileEntry.ID>,
        expectedIdentities: [FileEntry.ID: String],
        confirmedToolCommands: [FileEntry.ID: ToolCommandRemoval],
        runID: UUID
    ) async throws -> CleanupOutcome {
        requestCount += 1
        self.entries = entries
        self.overrides = userDataRemovalOverrides
        self.keepReceipt = keepReceipt
        self.trashFirst = trashFirst
        self.confirmedToolCommands = confirmedToolCommands
        let outcome = await withCheckedContinuation { continuation = $0 }
        wasCancelled = Task.isCancelled
        return outcome
    }
    func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan, bundleIdentifiers: Set<String>, itemPaths: Set<String>?,
        registeredApplicationBundleIdentifiers: Set<String>, keepReceipt: Bool,
        runID: UUID
    ) async throws -> CleanupOutcome {
        CleanupOutcome(failed: plan.items(for: bundleIdentifiers, itemPaths: itemPaths).map(\.id))
    }
    func finish(_ result: CleanupOutcome) { continuation?.resume(returning: result); continuation = nil }
}


actor HeldDashboardMeasurements: DashboardMeasuring {
    let holdCloud: Bool
    let holdVolume: Bool
    let volume: VolumeInfo
    private(set) var measurementCount = 0
    private(set) var cloudPlans: [Int64?] = []
    private(set) var volumeCount = 0
    private(set) var cancelled: [Bool] = []
    private var measurements: [Int: CheckedContinuation<StorageMeasurement, Error>] = [:]
    private var clouds: [Int: CheckedContinuation<ICloudStorage, Error>] = [:]
    private var volumes: [Int: CheckedContinuation<VolumeInfo, Never>] = [:]
    init(holdCloud: Bool = false, holdVolume: Bool = false, volume: VolumeInfo = dashboardVolume()) {
        self.holdCloud = holdCloud
        self.holdVolume = holdVolume
        self.volume = volume
    }
    func volumeInfo() async throws -> VolumeInfo {
        let index = volumeCount
        volumeCount += 1
        if holdVolume { return await withCheckedContinuation { volumes[index] = $0 } }
        return volume
    }
    private var snapshotList = ["boot", "data"].map {
        SnapshotInfo(uuid: $0, name: $0, purgeable: $0 != "boot", limitingContainerShrink: false,
                     isBootSnapshot: $0 == "boot", volumeDisk: "disk-fixture")
    }
    private(set) var deletedStamps: [String] = []
    func snapshots() async throws -> [SnapshotInfo] { snapshotList }
    func purgeableBytes() async -> Int64? { snapshotList.contains { $0.timeMachineStamp != nil } ? 50 : nil }
    func deleteTimeMachineSnapshots(_ snapshots: [SnapshotInfo]) async throws {
        let stamps = snapshots.compactMap(\.timeMachineStamp)
        deletedStamps += stamps
        snapshotList.removeAll { $0.timeMachineStamp.map(stamps.contains) ?? false }
    }
    func setSnapshots(_ snapshots: [SnapshotInfo]) { snapshotList = snapshots }
    func measure() async throws -> StorageMeasurement {
        let index = measurementCount
        measurementCount += 1
        let value = try await withCheckedThrowingContinuation { measurements[index] = $0 }
        cancelled.append(Task.isCancelled)
        return value
    }
    func iCloudStorage(planBytes: Int64?) async throws -> ICloudStorage {
        let index = cloudPlans.count
        cloudPlans.append(planBytes)
        if holdCloud { return try await withCheckedThrowingContinuation { clouds[index] = $0 } }
        return ICloudStorage(totalBytes: planBytes ?? 100, freeBytes: 20, documentsBytes: 40)
    }
    func finishMeasurement(_ index: Int, _ value: StorageMeasurement) { measurements.removeValue(forKey: index)?.resume(returning: value) }
    func failMeasurement(_ index: Int) { measurements.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func finishCloud(_ index: Int, _ value: ICloudStorage) { clouds.removeValue(forKey: index)?.resume(returning: value) }
    func failCloud(_ index: Int) { clouds.removeValue(forKey: index)?.resume(throwing: CocoaError(.fileReadNoPermission)) }
    func finishVolume(_ index: Int, _ value: VolumeInfo) { volumes.removeValue(forKey: index)?.resume(returning: value) }
}

actor HeldDashboardPersistence: DashboardPersisting {
    let holdHistory: Bool
    let holdRecord: Bool
    let recordHistory: (@Sendable (StorageMeasurement, SnapshotTrigger) async throws -> [StorageSnapshot])?
    private(set) var cache: BreakdownCache?
    private(set) var cacheLoads = 0
    private(set) var cacheClears = 0
    private(set) var historyLoads = 0
    private(set) var records: [SnapshotTrigger] = []
    private(set) var clearCount = 0
    private var history: [StorageSnapshot] = []
    private var rejectsNextRecord = false
    private var historyReply: CheckedContinuation<[StorageSnapshot], Never>?
    private var recordReply: CheckedContinuation<[StorageSnapshot], Never>?
    init(cache: BreakdownCache? = nil, holdHistory: Bool = false, holdRecord: Bool = false,
         recordHistory: (@Sendable (StorageMeasurement, SnapshotTrigger) async throws -> [StorageSnapshot])? = nil) {
        self.cache = cache
        self.holdHistory = holdHistory
        self.holdRecord = holdRecord
        self.recordHistory = recordHistory
    }
    func loadCache() -> BreakdownCache? { cacheLoads += 1; return cache }
    func saveCache(_ cache: BreakdownCache) { self.cache = cache }
    func clearCache() { cache = nil; cacheClears += 1 }
    func loadHistory() async -> [StorageSnapshot] {
        historyLoads += 1
        if holdHistory { return await withCheckedContinuation { historyReply = $0 } }
        return history
    }
    func rejectNextRecord() { rejectsNextRecord = true }
    func record(_ measurement: StorageMeasurement, trigger: SnapshotTrigger) async throws -> [StorageSnapshot] {
        records.append(trigger)
        if rejectsNextRecord {
            rejectsNextRecord = false
            throw CocoaError(.fileWriteNoPermission)
        }
        if holdRecord { return await withCheckedContinuation { recordReply = $0 } }
        if let recordHistory {
            history = try await recordHistory(measurement, trigger)
            return history
        }
        if let snapshot = SnapshotCapture.snapshot(from: measurement, trigger: trigger) { history.insert(snapshot, at: 0) }
        return history
    }
    func clearHistory() { clearCount += 1; history = [] }
    func finishHistory(_ history: [StorageSnapshot]) { historyReply?.resume(returning: history); historyReply = nil }
    func finishRecord(_ history: [StorageSnapshot]) { recordReply?.resume(returning: history); recordReply = nil }
}


struct UnreadableTrash: TrashServicing {
    func summary(limit: Int) async throws -> TrashSummary { throw TrashError.unreadable("/fixture/.Trash") }
    func empty() async throws -> EmptyTrashOutcome { Issue.record("The action must not empty the Trash."); return .init() }
    func putBack(_ item: TrashItem) async throws { Issue.record("The action must not restore an item.") }
}

func recoveryItem(_ name: String) -> TrashItem {
    TrashItem(url: URL(fileURLWithPath: "/moppo-fixture/.Trash/\(name)"), bytes: 64, canPutBack: true)
}

actor HeldRecoveryTrash: TrashServicing {
    let holdReads: Bool
    private(set) var readLimits: [Int] = []
    private(set) var restorations: [TrashItem] = []
    private(set) var emptyRequests = 0
    private(set) var cancelled: [Bool] = []
    private var reads: [Int: CheckedContinuation<TrashSummary, Error>] = [:]
    private var restore: CheckedContinuation<Void, Error>?
    private var empty: CheckedContinuation<EmptyTrashOutcome, Error>?
    init(holdReads: Bool = false) { self.holdReads = holdReads }
    func summary(limit: Int) async throws -> TrashSummary {
        let index = readLimits.count
        readLimits.append(limit)
        if holdReads { return try await withCheckedThrowingContinuation { reads[index] = $0 } }
        return TrashSummary()
    }
    func empty() async throws -> EmptyTrashOutcome {
        emptyRequests += 1
        let result = try await withCheckedThrowingContinuation { empty = $0 }
        cancelled.append(Task.isCancelled)
        return result
    }
    func putBack(_ item: TrashItem) async throws {
        restorations.append(item)
        try await withCheckedThrowingContinuation { restore = $0 }
        cancelled.append(Task.isCancelled)
    }
    func finishRead(_ index: Int, _ summary: TrashSummary) { reads.removeValue(forKey: index)?.resume(returning: summary) }
    func failRead(_ index: Int) { reads.removeValue(forKey: index)?.resume(throwing: TrashError.unreadable("fixture")) }
    func finishRestoration() { restore?.resume(); restore = nil }
    func failRestoration(_ error: TrashError) { restore?.resume(throwing: error); restore = nil }
    func finishEmpty(freed: Int64, skipped: Int) { empty?.resume(returning: EmptyTrashOutcome(freedBytes: freed, skippedURLs: (0..<skipped).map { recoveryItem("Survivor-\($0)").url })); empty = nil }
}

actor HeldRecoveryHistory: CleanupHistoryReading {
    let holdReads: Bool
    private(set) var readCount = 0
    private var reads: [Int: CheckedContinuation<CleanupHistorySummary, Never>] = [:]
    init(holdReads: Bool = true) { self.holdReads = holdReads }
    func summary() async -> CleanupHistorySummary {
        let index = readCount
        readCount += 1
        if holdReads { return await withCheckedContinuation { reads[index] = $0 } }
        return CleanupHistorySummary()
    }
    func finish(_ index: Int, _ summary: CleanupHistorySummary) { reads.removeValue(forKey: index)?.resume(returning: summary) }
}
