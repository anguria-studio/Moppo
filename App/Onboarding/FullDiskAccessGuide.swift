import AppKit
import SwiftUI

/// Keeps the app icon available while System Settings is in front.
@MainActor
final class FullDiskAccessGuide: NSObject, NSWindowDelegate {
    static let shared = FullDiskAccessGuide()
    private var panel: NSPanel?
    private var statusTask: Task<Void, Never>?

    func show() {
        if let panel, panel.isVisible {
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Enable Full Disk Access"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: FullDiskAccessGuideView(appURL: Bundle.main.bundleURL))
        if let screen = NSApp.keyWindow?.screen ?? NSScreen.main {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: bounds.maxX - panel.frame.width - 24,
                                         y: bounds.midY - panel.frame.height / 2))
        }
        self.panel = panel
        panel.orderFrontRegardless()
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                if FullDiskAccess.isGranted {
                    self?.panel?.close()
                    return
                }
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        statusTask?.cancel()
        statusTask = nil
        panel = nil
    }
}

struct FullDiskAccessGuideView: View {
    let appURL: URL

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appURL.path))
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 88, height: 88)
                .onDrag { Self.dragItem(for: appURL) }
                .accessibilityLabel("Moppo app")
                .accessibilityHint("Drag this app into the Full Disk Access list in System Settings.")
                .accessibilityAction(named: Text("Show in Finder")) { revealApp() }
                .help("Drag Moppo into the Full Disk Access list")
            Text("Drag Moppo into Settings")
                .font(.system(size: 20, weight: .semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Drag this icon into the Full Disk Access list.\nThen turn on Moppo.")
                .font(.system(size: 13))
                .foregroundStyle(Token.Text.secondary)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Token.Text.primary)
        .padding(24)
        .frame(width: 340, height: 260)
        .background(Token.chrome)
    }

    static func dragItem(for appURL: URL) -> NSItemProvider {
        // Send the original app URL so Settings receives the installed app.
        NSItemProvider(object: appURL as NSURL)
    }

    private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([appURL])
    }
}

#Preview("Full Disk Access guide") {
    FullDiskAccessGuideView(appURL: Bundle.main.bundleURL)
}
