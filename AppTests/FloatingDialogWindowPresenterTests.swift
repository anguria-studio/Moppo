import AppKit
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct FloatingDialogWindowPresenterTests {
    @Test("Dialog updates keep the panel and guard dismissal during removal and confirmation")
    func panelLifetime() async throws {
        _ = NSApplication.shared
        let bounds = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 640)
        let size = NSSize(width: min(1000, bounds.width - 48), height: min(640, bounds.height - 48))
        let parent = NSWindow(
            contentRect: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                                width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        var dismissals = 0
        var presenter = FloatingDialogWindowPresenter(
            isPresented: true, title: "Dialog test",
            size: NSSize(width: 860, height: 720),
            minimumSize: NSSize(width: 680, height: 460),
            onClose: { dismissals += 1 }, content: { Text("Loading") }
        )
        let coordinator = presenter.makeCoordinator()
        defer { coordinator.close() }

        coordinator.update(presenter: presenter, parent: nil)
        #expect(coordinator.panel == nil)
        coordinator.update(presenter: presenter, parent: parent)
        let panel = try #require(coordinator.panel)
        let frame = panel.frame
        #expect(frame.width <= parent.frame.width - 48)
        #expect(frame.height <= parent.frame.height - 48)
        #expect(abs(frame.midX - parent.frame.midX) < 1)
        #expect(abs(frame.midY - parent.frame.midY) < 1)

        presenter = FloatingDialogWindowPresenter(
            isPresented: true, title: "Dialog test",
            size: NSSize(width: 860, height: 720),
            minimumSize: NSSize(width: 680, height: 460), canClose: false,
            onClose: { dismissals += 1 }, content: { Text("Related files") }
        )
        coordinator.update(presenter: presenter, parent: parent)
        #expect(coordinator.panel === panel)
        #expect(panel.frame == frame)
        #expect(!coordinator.windowShouldClose(panel))
        panel.cancelOperation(nil)
        #expect(coordinator.panel === panel)
        #expect(dismissals == 0)

        presenter.canClose = true
        coordinator.update(presenter: presenter, parent: parent)
        let confirmation = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        panel.beginSheet(confirmation, completionHandler: nil)
        #expect(!coordinator.windowShouldClose(panel))
        panel.cancelOperation(nil)
        #expect(coordinator.panel === panel)
        #expect(dismissals == 0)
        panel.endSheet(confirmation)
        confirmation.orderOut(nil)
        try await waitUntil { panel.attachedSheet == nil }

        #expect(coordinator.windowShouldClose(panel))
        panel.cancelOperation(nil)
        #expect(coordinator.panel == nil)
        #expect(dismissals == 1)
    }
}
