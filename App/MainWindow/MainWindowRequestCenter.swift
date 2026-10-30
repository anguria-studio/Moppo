import AppKit
import SwiftUI

/// Keeps a request until the app model and main window can receive it.
@MainActor
final class MainWindowRequestCenter {
    static let uninstall = MainWindowRequestCenter()
    static let savedPlan = MainWindowRequestCenter()
    private var handler: ((URL) -> Void)?
    private var presenter: (() -> Void)?
    private var pendingURL: URL?

    func install(_ handler: @escaping (URL) -> Void) {
        self.handler = handler
        if let pendingURL { self.pendingURL = nil; handler(pendingURL) }
    }

    func installPresenter(_ presenter: @escaping () -> Void) { self.presenter = presenter }

    func submit(_ url: URL) {
        presenter?()
        guard let handler else { pendingURL = url; return }
        handler(url)
    }
}

struct MainWindowRequestReceiver: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindowIdentityView()
            .frame(width: 0, height: 0)
            .onAppear {
                for center in [MainWindowRequestCenter.uninstall, .savedPlan] {
                    center.installPresenter { MainWindowPresenter.present { openWindow(id: "main") } }
                }
            }
    }
}
