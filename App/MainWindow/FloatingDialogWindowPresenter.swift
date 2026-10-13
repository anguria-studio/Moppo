import AppKit
import SwiftUI

/// Presents a dialog above the dimmed main window.
struct FloatingDialogWindowPresenter<Content: View>: NSViewRepresentable {
    let isPresented: Bool
    let title: String
    let size: NSSize
    let minimumSize: NSSize
    var canClose = true
    let onClose: () -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> DialogAnchorView { DialogAnchorView() }

    func updateNSView(_ nsView: DialogAnchorView, context: Context) {
        let coordinator = context.coordinator
        nsView.onWindowChange = { [weak coordinator] window in
            coordinator?.update(presenter: self, parent: window)
        }
        coordinator.update(presenter: self, parent: nsView.window)
    }

    static func dismantleNSView(_ nsView: DialogAnchorView, coordinator: Coordinator) {
        nsView.onWindowChange = nil
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSWindowDelegate {
        private(set) var panel: NSPanel?
        private var hostingView: NSHostingView<Content>?
        private var backdropClickMonitor: Any?
        private weak var parentWindow: NSWindow?
        private var canClose = true
        private var onClose: (() -> Void)?

        func update(presenter: FloatingDialogWindowPresenter, parent: NSWindow?) {
            canClose = presenter.canClose
            onClose = presenter.onClose
            guard presenter.isPresented else { close(); return }
            guard let parent else { return }
            parentWindow = parent

            if let panel, let hostingView {
                hostingView.rootView = presenter.content()
                panel.appearance = parent.appearance
                return
            }

            let panel = DialogPanel(
                contentRect: NSRect(origin: .zero, size: presenter.size),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered, defer: false
            )
            panel.title = presenter.title
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = true
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.contentMinSize = presenter.minimumSize
            panel.collectionBehavior = [.fullScreenAuxiliary]
            panel.appearance = parent.appearance
            panel.onCancel = { [weak self] in self?.dismiss() }
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                panel.standardWindowButton(button)?.isHidden = true
            }
            let hostingView = NSHostingView(rootView: presenter.content())
            panel.contentView = hostingView
            panel.delegate = self
            self.hostingView = hostingView
            self.panel = panel

            let bounds = parent.screen?.visibleFrame ?? parent.frame
            let width = min(presenter.size.width, max(presenter.minimumSize.width, parent.frame.width - 48), bounds.width)
            let height = min(presenter.size.height, max(presenter.minimumSize.height, parent.frame.height - 48), bounds.height)
            let x = min(max(parent.frame.midX - width / 2, bounds.minX), bounds.maxX - width)
            let y = min(max(parent.frame.midY - height / 2, bounds.minY), bounds.maxY - height)
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: false)
            panel.makeKeyAndOrderFront(nil)
            installBackdropClickMonitor()
        }

        private func installBackdropClickMonitor() {
            backdropClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self, let panel = self.panel, event.window === self.parentWindow else { return false }
                    (panel.attachedSheet ?? panel).makeKeyAndOrderFront(nil)
                    return true
                }
                return consumed ? nil : event
            }
        }

        private func dismiss() {
            guard canClose, panel?.attachedSheet == nil else { return }
            onClose?()
            close()
        }

        func windowShouldClose(_ sender: NSWindow) -> Bool {
            canClose && sender.attachedSheet == nil
        }

        func windowWillClose(_ notification: Notification) {
            onClose?()
            close()
        }

        func close() {
            if let backdropClickMonitor { NSEvent.removeMonitor(backdropClickMonitor) }
            backdropClickMonitor = nil
            panel?.delegate = nil
            panel?.close()
            panel = nil
            hostingView = nil
            parentWindow = nil
        }
    }
}

final class DialogAnchorView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private final class DialogPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}
