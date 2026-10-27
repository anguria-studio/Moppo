import SwiftUI
import MoppoCore
import UserNotifications

#if !MOPPO_APP_TESTS
@main
#endif
struct MoppoApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    @State private var settings: SettingsStore
    @State private var access: AccessModel
    @State private var updates: UpdateController

    static var isRunningPreview: Bool {
        ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
    }

    init() {
        if Self.isRunningPreview {
            let settings = SettingsStore.preview { $0.showInMenuBar = false }
            _settings = State(initialValue: settings)
            _model = State(initialValue: AppModel(launchAccess: .welcome, hasFullDiskAccess: { false }))
            _access = State(initialValue: .preview())
            _updates = State(initialValue: UpdateController(operations: OperationCoordinator(), configuration: nil))
            return
        }
        AppIdentity.migratePreferences()
        // One store, handed to the model so the engine actually receives the
        // preferences the panes edit.
        let settings = SettingsStore()
        settings.appearance.apply()
        let model = AppModel(
            settings: settings, launchAccess: OnboardingView.launchAccess,
            onboardingProgress: OnboardingProgress(defaults: .standard)
        )
        _settings = State(initialValue: settings)
        _model = State(initialValue: model)
        _access = State(initialValue: AccessModel())
        _updates = State(initialValue: UpdateController(operations: model.operations))
        appDelegate.operations = model.operations
        FinderUninstallRequestCenter.shared.install { [weak model] applicationURL in
            model?.uninstaller.planAppUninstall(applicationURL)
        }
    }

    var body: some Scene {
        Window("Moppo", id: "main") {
            WelcomeRoot(model: model, settings: settings, access: access)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .onChange(of: model.isShowingWelcome, initial: true) { _, showingWelcome in
                    if !showingWelcome && !Self.isRunningPreview { updates.start() }
                }
                .frame(
                    minWidth: 1000, idealWidth: Token.Size.windowWidth,
                    minHeight: 640, idealHeight: Token.Size.windowHeight
                )
                .background(FinderUninstallRequestReceiver())
        }
        .defaultSize(width: Token.Size.windowWidth, height: Token.Size.windowHeight)
        // The sidebar extends behind the window controls.
        .windowStyle(.hiddenTitleBar)
        .onChange(of: settings.appearance) { _, appearance in
            guard !Self.isRunningPreview else { return }
            appearance.apply()
        }

        Window("Report a Problem", id: "support") {
            SupportView()
        }
        .windowResizability(.contentSize)

        Window("Privacy Information", id: "privacy") {
            PrivacyView()
        }
        .windowResizability(.contentSize)

        Settings {
            PreferencesView(
                settings: settings,
                access: access,
                updates: updates,
                dashboard: model.dashboard,
                categorySizes: model.categorySizes,
                onRebuildIndex: {
                    Task { await model.dashboard.rebuildSizeIndex() }
                },
                onClearMeasurementHistory: { model.dashboard.clearMeasurementHistory() }
            )
        }
        // Without this AppKit lets the Settings window be dragged wider than any of
        // its content; the design specifies a fixed 660 x 484.
        .windowResizability(.contentSize)

        MenuBarExtra(isInserted: $settings.showInMenuBar) {
            MenuBarView(model: model)
        } label: {
            MenuBarLabel(volume: model.dashboard.volume)
        }
        .menuBarExtraStyle(.window)
        .commands { MoppoCommands(model: model, updates: updates) }
    }
}

/// Keeps the app out of the Dock and ⌘-Tab while it is only a status item.
///
/// AppKit's activation policy decides that: `.regular` apps have a Dock icon and a
/// ⌘-Tab entry, `.accessory` apps have neither but keep their menu bar extra. The
/// policy follows the windows. A login launch starts `.accessory`; the first real
/// window to become main — opened from the menu bar, a Finder relaunch, or Settings
/// — promotes the app to `.regular`; closing the last such window demotes it again,
/// so no Dock icon lingers with nothing behind it.
///
/// The launch Apple event names the reason for the launch, so a Finder or Dock
/// launch, which carries no login flag, keeps its window and its Dock icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    private let finderUninstallServiceProvider = FinderUninstallServiceProvider()
    weak var operations: OperationCoordinator?
    var completeTermination: (NSApplication) -> Void = { $0.reply(toApplicationShouldTerminate: true) }

    /// True while a login launch is still settling: SwiftUI can present the
    /// restored window just after `applicationDidFinishLaunching`, and without this
    /// the window observer would promote the app straight back to the Dock.
    private var isSettlingLoginLaunch = false

    /// Whether the status item is on screen — the app's only face once the last
    /// window closes. Read from defaults rather than the store, which the delegate
    /// has no handle on; `SettingsStore` writes this key and defaults it to true.
    private static var menuBarItemIsVisible: Bool {
        UserDefaults.standard.object(forKey: "settings.showInMenuBar") as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !MoppoApp.isRunningPreview else { return }
        _ = try? ScanLog.recordApplicationEvent("application_started")
        // Low-space readings often finish while the Dashboard is the active window.
        // Foreground notifications are silent unless the app supplies a delegate.
        UNUserNotificationCenter.current().delegate = self
        NSApp.servicesProvider = finderUninstallServiceProvider
        NSUpdateDynamicServices()
        observeWindows()
        // With the menu bar item switched off there is nothing to become: an
        // accessory app with no status item and no window is a process the user
        // can neither see nor quit. It keeps its Dock icon instead.
        if Self.launchedAsLoginItem, Self.menuBarItemIsVisible,
           !OnboardingView.launchAccess.requiresOnboarding {
            isSettlingLoginLaunch = true
            Self.setPolicy(.accessory)
            closeMainWindows()
            // Sweep once more on the next runloop turn for the late-presented window.
            DispatchQueue.main.async {
                self.closeMainWindows()
                self.isSettlingLoginLaunch = false
            }
        } else {
            MainWindowPresenter.activateAfterLaunch()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        guard notification.request.identifier
            == LowDiskNotificationService.notificationIdentifier else { return [] }
        return [.banner, .list, .sound]
    }

    /// Stops scans before quitting. File changes must finish before another quit request.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let operation = operations?.activeOperation.map { String(describing: $0.kind) } ?? "none"
        let reply: NSApplication.TerminateReply
        let completeTermination = completeTermination
        if let operations, operations.isBusy, operations.activeOperation?.kind != .updateInstallation {
            reply = operations.cancelForTermination(whenReady: {
                // Reply after AppKit receives terminateLater, including immediate cancellation.
                Task { @MainActor in
                    _ = try? ScanLog.recordApplicationEvent("termination_ready", details: ["operation": operation])
                    completeTermination(sender)
                }
            }) ? .terminateLater : .terminateCancel
        } else {
            reply = .terminateNow
        }
        let decision = reply == .terminateNow ? "now" : reply == .terminateLater ? "after_cancellation" : "blocked"
        _ = try? ScanLog.recordApplicationEvent("termination_requested", details: ["operation": operation, "decision": decision])
        return reply
    }

    func applicationWillTerminate(_ notification: Notification) {
        _ = try? ScanLog.recordApplicationEvent("application_terminating")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Policy follows the windows

    private func observeWindows() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )
    }

    /// A real window is on screen: make sure the app has a Dock icon to go with it.
    @objc private func windowDidBecomeMain(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        if isSettlingLoginLaunch {
            // The restored window arriving late on a login launch: not a request
            // to open the app, so close it rather than promote for it.
            window.close()
            return
        }
        guard NSApp.activationPolicy() != .regular else { return }
        Self.setPolicy(.regular)
        // The policy flip re-registers the app with the window server, which can
        // drop key focus from the window that triggered it. Reassert it next turn.
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// The last real window is closing: return to the menu bar.
    ///
    /// Checked on the next turn, because at `willClose` the window is still visible.
    /// This applies however the app was launched: a Dock icon with no window behind
    /// it is exactly the state this delegate exists to avoid.
    @objc private func windowWillClose(_ note: Notification) {
        guard let closing = note.object as? NSWindow else { return }
        DispatchQueue.main.async {
            let remaining = NSApp.windows.filter {
                $0 !== closing && $0.canBecomeMain && $0.isVisible
            }
            guard remaining.isEmpty, NSApp.activationPolicy() == .regular,
                  // Same rule as at launch: the Dock icon stays when it is the only
                  // way left to reach the app.
                  Self.menuBarItemIsVisible
            else { return }
            Self.setPolicy(.accessory)
            // An accessory app with no windows has nothing to be active for; hiding
            // hands focus to the next app the way ⌘H would. The status item is
            // unaffected, and `activate` unhides.
            NSApp.hide(nil)
        }
    }

    static func setPolicy(_ policy: NSApplication.ActivationPolicy) {
        NSApp.setActivationPolicy(policy)
    }

    // MARK: - Login launch

    /// Only windows that can become main: the status item's own window and panels
    /// must survive, or the menu bar item dies with the launch.
    private func closeMainWindows() {
        for window in NSApp.windows where window.canBecomeMain && window.isVisible {
            window.close()
        }
    }

    private static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return false
        }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue
                == keyAELaunchedAsLogInItem
    }
}

/// Keeps command updates separate from the application scene.
private struct MoppoCommands: Commands {
    @Bindable var model: AppModel
    @Bindable var updates: UpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…", action: updates.checkForUpdates)
                .disabled(!updates.canCheckForUpdates)
        }
        // Update menu availability without rebuilding the application scene.
        CommandMenu("Cleanup") {
            Button("Scan for Cleanup Items") { model.cleanup.startScan() }
                .keyboardShortcut("r")
                .disabled(model.isShowingWelcome || model.isBusyWithDisk
                          || model.uninstaller.isShowingAppUninstallDetail)
            Button(model.cleanup.isInterruptingScan ? ScanInterruptionView.title : "Stop Scan") { model.cleanup.cancelScan() }
                .keyboardShortcut(".")
                .disabled(!model.cleanup.isScanning || model.cleanup.isInterruptingScan)
        }
        // Replace document editing commands with the application search command.
        CommandGroup(replacing: .textEditing) {
            Button("Find") { model.requestFind() }
                .keyboardShortcut("f")
                .disabled(!model.canFind || model.uninstaller.isShowingAppUninstallDetail)
        }
        CommandGroup(after: .help) {
            if ScanLog.isEnabled {
                Button("Show Scan Logs") { ScanLog.reveal() }
            }
            Button("Report a Problem…") {
                openWindow(id: "support")
            }
            Button("Privacy Information") {
                openWindow(id: "privacy")
            }
        }
        CommandGroup(after: .appSettings) {
            Button("Show Welcome Guide") {
                model.showWelcomeGuide()
                MainWindowPresenter.present { openWindow(id: "main") }
            }
            .disabled(model.isBusyWithDisk || model.uninstaller.isShowingAppUninstallDetail)
            Button("Grant Full Disk Access") {
                FullDiskAccess.openSystemSettings()
            }
        }
    }
}

private struct WelcomeRoot: View {
    @Bindable var model: AppModel
    let settings: SettingsStore
    let access: AccessModel

    var body: some View {
        Group {
            if model.isShowingWelcome {
                OnboardingView(settings: settings, access: access, progress: model.onboardingProgress) {
                    model.finishWelcomeGuide()
                }
            } else {
                MainWindow(model: model, settings: settings, access: access)
            }
        }
    }
}
