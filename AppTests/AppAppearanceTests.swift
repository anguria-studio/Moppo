import AppKit
import SwiftUI
import Testing

@Suite("Application appearance", .serialized)
@MainActor
struct AppAppearanceTests {
    @Test("Missing and invalid appearance preferences use System and preserve other settings")
    func defaultAppearance() throws {
        let suite = "moppo-tests.appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let fresh = SettingsStore(defaults: defaults, managesLoginItem: false)
        #expect(fresh.appearance == .system)
        fresh.showInMenuBar = false
        fresh.scanSchedule = .daily
        fresh.warnBelowGB = 35

        for stored in [Optional<String>.none, "unknown"] {
            defaults.set(stored, forKey: AppAppearance.defaultsKey)
            let existing = SettingsStore(defaults: defaults, managesLoginItem: false)
            #expect(existing.appearance == .system)
            #expect(!existing.showInMenuBar)
            #expect(existing.scanSchedule == .daily)
            #expect(existing.warnBelowGB == 35)
            #expect(defaults.string(forKey: AppAppearance.defaultsKey) == stored)
        }
    }

    @Test("Appearance survives reopening and resets to System", arguments: [AppAppearance.light, .dark])
    func persistence(appearance: AppAppearance) throws {
        let suite = "moppo-tests.appearance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults, managesLoginItem: false)
        settings.appearance = appearance
        let reopened = SettingsStore(defaults: defaults, managesLoginItem: false)
        #expect(reopened.appearance == appearance)
        #expect(AppAppearance.saved(in: defaults) == appearance)
        reopened.resetToDefaults()
        #expect(reopened.appearance == .system)
        #expect(SettingsStore(defaults: defaults, managesLoginItem: false).appearance == .system)
    }

    @Test("Open windows, dialogs, and SwiftUI content follow the application appearance")
    func propagation() async throws {
        let application = NSApplication.shared
        let original = application.appearance
        defer { application.appearance = original }
        let parent = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        parent.isReleasedWhenClosed = false
        defer { parent.close() }
        var colorScheme: ColorScheme?
        let host = NSHostingView(rootView: AppearanceProbe { colorScheme = $0 })
        parent.contentView = host
        let presenter = FloatingDialogWindowPresenter(
            isPresented: true, title: "Appearance test",
            size: NSSize(width: 560, height: 460), minimumSize: NSSize(width: 520, height: 460),
            onClose: {}, content: { Text("Dialog") }
        )
        let coordinator = presenter.makeCoordinator()
        defer { coordinator.close() }
        coordinator.update(presenter: presenter, parent: parent)
        let panel = try #require(coordinator.panel)
        let (alert, _) = HomebrewPasswordPrompt.makeAlert(package: "test-package")
        alert.layout()
        alert.window.orderFront(nil)
        defer { alert.window.orderOut(nil) }

        for appearance in [AppAppearance.light, .dark, .light] {
            appearance.apply(to: application)
            let expected: NSAppearance.Name = appearance == .dark ? .darkAqua : .aqua
            #expect(parent.appearance == nil)
            #expect(panel.appearance == nil)
            #expect(parent.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            #expect(alert.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            host.layoutSubtreeIfNeeded()
            try await waitUntil { colorScheme == (appearance == .dark ? .dark : .light) }

            let newWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 340, height: 260),
                styleMask: [.titled], backing: .buffered, defer: false
            )
            newWindow.isReleasedWhenClosed = false
            #expect(newWindow.appearance == nil)
            #expect(newWindow.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected)
            newWindow.close()
        }

        AppAppearance.system.apply(to: application)
        #expect(application.appearance == nil)
        #expect(parent.appearance == nil)
        #expect(panel.appearance == nil)
        let system = application.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
        #expect(parent.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == system)
        #expect(panel.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == system)
    }
}

private struct AppearanceProbe: View {
    @Environment(\.colorScheme) private var colorScheme
    let onChange: (ColorScheme) -> Void

    var body: some View {
        Text("Appearance")
            .onChange(of: colorScheme, initial: true) { _, value in onChange(value) }
    }
}
