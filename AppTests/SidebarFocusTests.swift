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
        #expect(try focusRingPixels(in: host) == 0)

        // Programmatic navigation moves focus without starting keyboard navigation.
        model.view = .scanner
        try await Task.sleep(for: .milliseconds(100))
        #expect(try focusRingPixels(in: host) == 0)
        try sendKey("\u{F701}", code: 125, to: window)
        try await waitUntil { model.view == .storageExplorer }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try focusRingPixels(in: host) > 20)

        try click(NSPoint(x: Token.Size.sidebarWidth + 100, y: 320), in: host, window: window)
        model.view = .scanner
        try await waitUntil { model.view == .scanner }
        try await Task.sleep(for: .milliseconds(100))
        #expect(try focusRingPixels(in: host) == 0)

        model.cleanup.startScan(automatic: true, refreshOverview: false)
        try await waitUntil { await scanner.requestCount == 1 }
        await scanner.report(0, percent: 42)
        try await waitUntil { model.cleanup.scanProgress == 42 }
        #expect(try focusRingPixels(in: host) == 0)
        await scanner.finish(0, results: .init(categories: [], startedAt: Date(), finishedAt: Date()))
        _ = await model.cleanup.waitForScan()
        #expect(try focusRingPixels(in: host) == 0)

        // Tab starts keyboard navigation even when the page changes on the next turn.
        try sendKey("\t", code: 48, to: window)
        model.view = .dashboard
        try await Task.sleep(for: .milliseconds(100))
        #expect(try focusRingPixels(in: host) > 20)
        for (characters, code) in [(" ", UInt16(49)), ("\r", UInt16(36))] {
            try sendKey(characters, code: code, to: window)
            try await Task.sleep(for: .milliseconds(100))
            #expect(model.view == .dashboard)
            #expect(try focusRingPixels(in: host) > 20)
        }

        // A click on the selected row must also clear keyboard focus styling.
        try click(NSPoint(x: 100, y: 244), in: host, window: window)
        try await Task.sleep(for: .milliseconds(100))
        #expect(model.view == .dashboard)
        #expect(try focusRingPixels(in: host) == 0)
    }

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
        NSApp.sendEvent(event)
    }

    private func click(_ point: NSPoint, in host: NSView, window: NSWindow) throws {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: host.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0
            ))
            NSApp.sendEvent(event)
        }
    }

    private func focusRingPixels(in host: NSView) throws -> Int {
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

    private func textField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }
}
