import AppKit
import SwiftUI
import Testing
import MoppoCore

@Suite("Cleanup quit controls", .serialized)
@MainActor
struct CleanupQuitControlTests {
    @Test("Escape cancels the quit wait while the main page is disabled", arguments: [false, true])
    func cancelFromMainWindow(dark: Bool) async throws {
        let folder = try TemporaryFolder()
        let owner = FileEntry.RunningOwner(name: "Fixture", bundleIdentifier: "test.quit", bundlePath: "/fixture.app")
        let entry = FileEntry(url: try folder.write("cache"), kind: .file,
            allocatedBytes: 64, isRegenerable: true, inUseBy: owner)
        let gate = TestGate()
        let model = AppModel(
            launchAccess: .welcome, hasFullDiskAccess: { false },
            cleanupApplications: CleanupApplications(stillRunning: { $0 }, quit: { owners in
                await gate.wait()
                return owners
            })
        )
        model.view = .scanner
        model.cleanup.scanResults = ScanResults(categories: [
            ScanCategoryResult(categoryID: .systemCaches, entries: [entry])
        ], startedAt: .now, finishedAt: .now)
        let caller = Task { await model.cleanup.quitAppsForCleanup() }
        defer { Task { await gate.finish() } }
        try await waitUntil { await gate.isPending }
        #expect(model.activity != nil)
        let host = NSHostingView(rootView: MainWindow(model: model)
            .environment(\.scenePhase, .inactive)
            .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 640),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))
        window.sendEvent(event)
        try await waitUntil { model.cleanup.isInterruptingApplicationQuit }
        #expect(model.isBusyWithDisk)
        await gate.finish()
        await caller.value
        #expect(model.activity == nil)
        #expect(!model.isBusyWithDisk)
        #expect(model.notice == nil)
        #expect(model.cleanup.scanResults != nil)
    }
}
