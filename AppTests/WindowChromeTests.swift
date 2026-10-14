import AppKit
import Testing

@Suite("Native window controls", .serialized)
@MainActor
struct WindowChromeTests {
    @Test("Native controls stay aligned before and after resize layout", arguments: [false, true])
    func resize(dark: Bool) async throws {
        _ = NSApplication.shared
        let window = makeWindow()
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let chrome = WindowChrome.ChromeView()
        let content = try #require(window.contentView)
        content.addSubview(chrome)
        defer { window.contentView = nil }

        // Attachment configures the title bar before the next main queue turn.
        let toolbar = try #require(window.toolbar)
        #expect(window.toolbarStyle == .unified)
        #expect(window.titleVisibility == .hidden)
        #expect(window.titlebarAppearsTransparent)
        #expect(window.isMovable)
        #expect(!window.isMovableByWindowBackground)
        #expect(toolbar.items.isEmpty)
        content.superview?.layoutSubtreeIfNeeded()
        #expect(window.frame.height - window.contentLayoutRect.height <= Token.Size.headerBand)

        let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        let buttons = try types.map { try #require(window.standardWindowButton($0)) }
        let actions = buttons.map(\.action)
        let baseline = buttons.map { headerFrame($0, in: window) }
        for frame in baseline {
            #expect(frame.height > 0)
            #expect(abs(frame.midY - Token.Size.headerBand / 2) < 1)
        }

        for index in 0..<48 {
            let width: CGFloat = [1240, Token.Size.windowWidth, 1000][index % 3]
            let height: CGFloat = [734, 900, 640][index % 3]
            let frame = NSRect(x: CGFloat(80 + index % 7), y: CGFloat(80 + index % 11), width: width, height: height)
            window.setFrame(frame, display: false)
            content.superview?.layoutSubtreeIfNeeded()
            #expect(buttons.map { headerFrame($0, in: window) } == baseline)
            #expect(content.frame.size == window.frame.size)
            #expect(window.toolbar === toolbar)
        }
        try await Task.sleep(for: .milliseconds(30))
        content.superview?.layoutSubtreeIfNeeded()
        #expect(buttons.map { headerFrame($0, in: window) } == baseline)

        for (index, type) in types.enumerated() {
            let button = try #require(window.standardWindowButton(type))
            #expect(button === buttons[index])
            #expect(button.action == actions[index])
            #expect(button.isEnabled)
            #expect(!button.isHidden)
            let container = try #require(button.superview)
            #expect(container.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)
        }

        // Welcome and main content share the same window and native toolbar.
        chrome.removeFromSuperview()
        content.addSubview(WindowChrome.ChromeView())
        content.superview?.layoutSubtreeIfNeeded()
        #expect(window.toolbar === toolbar)
        #expect(buttons.map { headerFrame($0, in: window) } == baseline)

        let reopened = makeWindow()
        defer { reopened.contentView = nil }
        reopened.setFrame(window.frame, display: false)
        reopened.contentView?.addSubview(chrome)
        reopened.contentView?.superview?.layoutSubtreeIfNeeded()
        let reopenedButtons = try types.map { try #require(reopened.standardWindowButton($0)) }
        #expect(reopenedButtons.map { headerFrame($0, in: reopened) } == baseline)
    }

    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: Token.Size.windowWidth, height: Token.Size.windowHeight),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
    }

    private func headerFrame(_ button: NSButton, in window: NSWindow) -> NSRect {
        let frame = button.convert(button.bounds, to: nil)
        return NSRect(x: frame.minX, y: window.frame.height - frame.maxY, width: frame.width, height: frame.height)
    }
}
