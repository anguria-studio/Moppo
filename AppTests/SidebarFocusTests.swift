import AppKit
import SwiftUI
import Testing

@Suite("Sidebar focus", .serialized)
@MainActor
struct SidebarFocusTests {
    @Test("The sidebar focus ring follows keyboard and mouse input", arguments: [false, true])
    func focusRing(dark: Bool) async throws {
        _ = NSApplication.shared
        let scanner = HeldCleanupScanner()
        let model = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        model.view = .dashboard
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            SidebarView(model: model).frame(width: Token.Size.sidebarWidth)
            Color.clear.frame(width: 200, height: 640)
        }
        .modifier(KeyboardFocusVisibility())
        .background(dark ? Color.black : Color.white)
        .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: Token.Size.sidebarWidth + 200, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
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
        #expect(try sidebarFocusRingPixels(in: host) == 0)

        // Programmatic navigation moves focus without starting keyboard navigation.
        model.view = .scanner
        try await Task.sleep(for: .milliseconds(100))
        #expect(try sidebarFocusRingPixels(in: host) == 0)
        try sendKey("\u{F701}", code: 125, to: window)
        try await waitUntil { model.view == .storageExplorer }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try sidebarFocusRingPixels(in: host) > 20)

        try click(NSPoint(x: Token.Size.sidebarWidth + 100, y: 320), in: host, window: window)
        model.view = .scanner
        try await waitUntil { model.view == .scanner }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try sidebarFocusRingPixels(in: host) == 0)

        model.cleanup.startScan(automatic: true, refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.report(0, percent: 42)
        try await waitUntil { model.cleanup.scanProgress == 42 }
        #expect(try sidebarFocusRingPixels(in: host) == 0)
        await scanner.finish(0, results: .init(categories: [], startedAt: Date(), finishedAt: Date()))
        _ = await model.cleanup.waitForScan()
        #expect(try sidebarFocusRingPixels(in: host) == 0)

        // Tab starts keyboard navigation even when the page changes on the next turn.
        try sendKey("\t", code: 48, to: window)
        model.view = .dashboard
        try await Task.sleep(for: .milliseconds(100))
        #expect(try sidebarFocusRingPixels(in: host) > 20)
        for (characters, code) in [(" ", UInt16(49)), ("\r", UInt16(36))] {
            try sendKey(characters, code: code, to: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.view == .dashboard)
            #expect(try sidebarFocusRingPixels(in: host) > 20)
        }

        // A click on the selected row must also clear keyboard focus styling.
        try click(NSPoint(x: 100, y: 244), in: host, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.view == .dashboard)
        #expect(try sidebarFocusRingPixels(in: host) == 0)
    }

    @Test("Sidebar traversal reaches page input and preserves its focus")
    func pageNavigation() async throws {
        _ = NSApplication.shared
        let scanner = HeldCleanupScanner()
        let model = AppModel(hasFullDiskAccess: { true }, cleanupScanner: scanner)
        model.view = .dashboard
        var text = ""
        let host = NSHostingView(rootView: VStack {
            SidebarView(model: model)
            TextField("Test input", text: Binding(get: { text }, set: { text = $0 }))
        }.frame(width: Token.Size.sidebarWidth)
        .modifier(KeyboardFocusVisibility()))
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
        // Native key view actions also work when another test has the key window.
        window.orderOut(nil)
        window.selectNextKeyView(nil)
        try await Task.sleep(for: .milliseconds(100))
        let field = try #require(textField(in: host))
        let responder = try #require(field.currentEditor())
        #expect(window.firstResponder === responder)
        model.view = .history
        try await Task.sleep(for: .milliseconds(100))
        #expect(window.firstResponder === responder)
        model.cleanup.startScan(automatic: true, refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.report(0, percent: 42)
        try await waitUntil { model.cleanup.scanProgress == 42 }
        #expect(window.firstResponder === responder)
        #expect(model.view == .history)
        model.cleanup.cancelScan()
        await scanner.fail(0)
        _ = await model.cleanup.waitForScan()
        #expect(window.firstResponder === responder)
        #expect(model.view == .history)
    }

    @Test("Mouse input hides a page outline without clearing keyboard focus")
    func pageFocusVisibility() async throws {
        _ = NSApplication.shared
        var showsFocus = false
        let host = NSHostingView(rootView: PageFocusProbe(
            onVisibility: { showsFocus = $0 }
        ).modifier(KeyboardFocusVisibility()))
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: 320, height: 200),
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
        #expect(!showsFocus)
        let field = try #require(textField(in: host))
        #expect(window.makeFirstResponder(field))
        let responder = try #require(field.currentEditor())

        try sendKey("\u{F700}", code: 126, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(showsFocus)
        #expect(window.firstResponder === responder)

        try click(NSPoint(x: 300, y: 180), in: host, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(!showsFocus)
        #expect(window.firstResponder === responder)

        try sendKey("\u{F700}", code: 126, to: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(showsFocus)
        #expect(window.firstResponder === responder)
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
}

private struct PageFocusProbe: View {
    let onVisibility: (Bool) -> Void
    @Environment(\.isFocusEffectEnabled) private var showsFocus

    var body: some View {
        TextField("Test input", text: .constant(""))
            .frame(width: 120)
            .frame(width: 320, height: 200, alignment: .topLeading)
            .onChange(of: showsFocus, initial: true) { _, value in onVisibility(value) }
    }
}
