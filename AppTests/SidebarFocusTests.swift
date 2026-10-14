import AppKit
import SwiftUI
import Testing

@Suite("Sidebar focus", .serialized)
@MainActor
struct SidebarFocusTests {
    @Test("Page navigation moves keyboard input, and scan progress keeps the current responder")
    func pageNavigation() async throws {
        _ = NSApplication.shared
        let scanner = HeldCleanupScanner()
        let model = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        model.view = .dashboard
        var text = ""
        let host = NSHostingView(rootView: VStack {
            SidebarView(model: model)
            TextField("Test input", text: Binding(get: { text }, set: { text = $0 }))
        }.frame(width: Token.Size.sidebarWidth))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: Token.Size.sidebarWidth, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer {
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))

        model.view = .scanner
        try await Task.sleep(for: .milliseconds(100))
        try sendKey("\u{F701}", code: 125, to: window)
        try await waitUntil { model.view == .storageExplorer }

        model.view = .dashboard
        try await Task.sleep(for: .milliseconds(100))
        try sendKey("\u{F700}", code: 126, to: window)
        try await waitUntil { model.view == .duplicates }

        // Finish the navigation layout before the user moves focus into the page.
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        // Other native tests can open key windows. Keep this window's responder independent.
        window.orderOut(nil)
        let field = try #require(textField(in: host))
        #expect(window.makeFirstResponder(field))
        let responder = try #require(window.firstResponder)
        model.cleanup.startScan(automatic: true, refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.report(0, percent: 42)
        try await waitUntil { model.cleanup.scanProgress == 42 }
        #expect(window.firstResponder === responder)
        #expect(model.view == .duplicates)
        model.cleanup.cancelScan()
        await scanner.fail(0)
        _ = await model.cleanup.waitForScan()
        #expect(window.firstResponder === responder)
        #expect(model.view == .duplicates)
    }

    private func sendKey(
        _ characters: String, code: UInt16, to window: NSWindow
    ) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        ))
        window.sendEvent(event)
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
}
