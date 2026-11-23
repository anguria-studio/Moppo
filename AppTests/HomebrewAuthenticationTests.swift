import AppKit
import Testing

@Suite("Homebrew password helper", .serialized)
@MainActor
struct HomebrewAuthenticationTests {
    private let now = Date(timeIntervalSince1970: 1_000)
    private let appPath = "/Applications/Moppo.app/Contents/MacOS/Moppo"

    private var environment: [String: String] {
        [
            "HOMEBREW_MOPPO_APP_PID": "100",
            "HOMEBREW_MOPPO_CASK": "ferdium",
            "HOMEBREW_MOPPO_AUTH_DEADLINE": "1200",
        ]
    }

    @Test("Only sudo within the Moppo process tree can request a password")
    func trustedAncestry() throws {
        let request = try #require(HomebrewAskpassRequest(environment: environment, now: now))
        let chain: [pid_t: HomebrewAskpassRequest.ProcessIdentity] = [
            100: .init(parent: 1, executable: appPath),
            101: .init(parent: 100, executable: "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby"),
            102: .init(parent: 101, executable: "/usr/bin/sudo"),
        ]
        #expect(request.accepts(parentPID: 102, applicationExecutable: appPath, now: now, identity: { chain[$0] }))
        #expect(!request.accepts(parentPID: 101, applicationExecutable: appPath, now: now, identity: { chain[$0] }))
        #expect(!request.accepts(parentPID: 102, applicationExecutable: "/tmp/FakeMoppo", now: now, identity: { chain[$0] }))
        #expect(!request.accepts(parentPID: 102, applicationExecutable: appPath, now: Date(timeIntervalSince1970: 1200), identity: { chain[$0] }))
    }

    @Test("Detached or unrelated callers cannot display a password prompt")
    func unrelatedAncestry() throws {
        let request = try #require(HomebrewAskpassRequest(environment: environment, now: now))
        for parent: pid_t in [1, 102, 999] {
            #expect(!request.accepts(parentPID: 102, applicationExecutable: appPath, now: now) { pid in
                pid == 102 ? .init(parent: parent, executable: "/usr/bin/sudo") : nil
            })
        }
        #expect(!request.accepts(parentPID: 102, applicationExecutable: appPath, now: now) { _ in nil })
    }

    @Test("Missing or expired requests do not open a password prompt")
    func invalidRequests() {
        #expect(HomebrewAskpassRequest(environment: [:], now: now) == nil)
        for value in ["0", "-1", "bad"] {
            var changed = environment
            changed["HOMEBREW_MOPPO_APP_PID"] = value
            #expect(HomebrewAskpassRequest(environment: changed, now: now) == nil)
        }
        for value in ["999", "1000", "1301", "nan", "inf", "bad"] {
            var changed = environment
            changed["HOMEBREW_MOPPO_AUTH_DEADLINE"] = value
            #expect(HomebrewAskpassRequest(environment: changed, now: now) == nil)
        }
        for value in ["", "-ferdium", "../../ferdium", "ferdium\nother", "ferdium;command", String(repeating: "a", count: 201)] {
            var changed = environment
            changed["HOMEBREW_MOPPO_CASK"] = value
            #expect(HomebrewAskpassRequest(environment: changed, now: now) == nil)
        }
    }

    @Test("Process inspection supports both the current user and system processes")
    func systemProcessIdentity() throws {
        let current = try #require(HomebrewAskpassRequest.identity(getpid()))
        #expect(current.parent == getppid())
        #expect(!current.executable.isEmpty)
        let launchd = try #require(HomebrewAskpassRequest.identity(1))
        #expect(launchd.executable == "/sbin/launchd")
        #expect(!HomebrewAskpassRequest.isSignedMoppo(getpid()))
        #expect(!HomebrewAskpassRequest.isSignedMoppo(1))
    }

    @Test("App resources include supported languages and use the source language as fallback")
    func localizations() throws {
        let resources = MoppoResources.bundle
        #expect(resources.developmentLocalization == "en")
        let expected = [
            "en": "Full Disk Access",
            "it": "Accesso completo al disco",
            "fr": "Accès complet au disque",
            "es": "Acceso total al disco",
        ]
        for (language, label) in expected {
            let bundle = try #require(HomebrewPasswordPrompt.localizationBundle(in: resources, language: language))
            #expect(String(localized: "Full Disk Access", bundle: bundle) == label)
            #expect(bundle.localizedString(forKey: "NSPhotoLibraryUsageDescription", value: nil, table: "InfoPlist")
                != "NSPhotoLibraryUsageDescription")
            #expect(bundle.url(forResource: "Privacy", withExtension: "md") != nil)
        }
        let spanish = try #require(HomebrewPasswordPrompt.localizationBundle(in: resources, language: "es"))
        #expect(String(localized: "Moppo", bundle: spanish) == "Moppo")
        let fallback = try #require(HomebrewPasswordPrompt.localizationBundle(in: resources, language: "unavailable"))
        #expect(String(localized: "Full Disk Access", bundle: fallback) == "Full Disk Access")
    }

    @Test("The exclusion count uses the plural rules of the selected language")
    func exclusionCountLocalization() throws {
        let resources = MoppoResources.bundle
        let expected = [
            "en": ["0 rules", "1 rule", "2 rules"],
            "fr": ["0 règle", "1 règle", "2 règles"],
        ]
        for (language, forms) in expected {
            let bundle = try #require(HomebrewPasswordPrompt.localizationBundle(in: resources, language: language))
            let counts = (0...2).map { count in
                String(localized: "\(count) rules", bundle: bundle, locale: Locale(identifier: language))
            }
            #expect(counts == forms)
        }
    }

    @Test("The password dialog identifies the package and uses a secure field")
    func prompt() throws {
        _ = NSApplication.shared
        let spanish = try #require(HomebrewPasswordPrompt.localizationBundle(in: MoppoResources.bundle, language: "es"))
        let (localizedAlert, localizedPassword) = HomebrewPasswordPrompt.makeAlert(package: "ferdium", bundle: spanish)
        #expect(localizedAlert.messageText == "Homebrew requiere acceso de administrador")
        #expect(localizedAlert.informativeText.contains("ferdium"))
        #expect(localizedPassword.placeholderString == "Contraseña de inicio de sesión")

        let (alert, password) = HomebrewPasswordPrompt.makeAlert(package: "ferdium")
        #expect(alert.informativeText.contains("ferdium"))
        #expect(alert.informativeText.contains(NSUserName()))
        #expect(password.stringValue.isEmpty)
        #expect(alert.accessoryView === password)
        #expect(alert.window.initialFirstResponder === password)
        #expect(alert.buttons[1].keyEquivalent == "\u{1b}")
        #expect(!alert.buttons[0].isEnabled)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-homebrew-previews")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            alert.window.appearance = NSAppearance(named: appearance)
            alert.layout()
            let view = try #require(alert.window.contentView)
            view.wantsLayer = true
            alert.window.appearance?.performAsCurrentDrawingAppearance {
                view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            }
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: directory.appendingPathComponent("password-\(name).png"))
        }
        alert.window.orderOut(nil)
    }
}
