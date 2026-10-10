import Foundation
import Testing
import MoppoCore

@Suite("Onboarding restart recovery")
@MainActor
struct OnboardingProgressTests {
    @Test("A permission restart resumes first or repeated setup", arguments: [false, true])
    func restartDuringWelcome(previouslyCompleted: Bool) throws {
        let fixture = try ProgressFixture()
        defer { fixture.removeDomain() }
        fixture.defaults.set(previouslyCompleted, forKey: "onboarding.completed")
        let first = fixture.app(forceWelcome: previouslyCompleted, hasDiskAccess: false)
        #expect(first.isShowingWelcome)

        // A macOS relaunch has no Xcode argument and can have a new permission grant.
        let reopened = try fixture.reopenProgress()
        let next = AppModel(
            launchAccess: reopened.launchAccess(hasFullDiskAccess: true),
            onboardingProgress: reopened, hasFullDiskAccess: { true }
        )
        #expect(reopened.pendingStep == .welcome)
        #expect(next.isShowingWelcome)
        #expect(!next.checkDiskAccess(automatic: true))
        next.startInitialCleanupScan()
        #expect(!next.cleanup.hasStartedInitialScan)
    }

    @Test("A restart preserves the preferences page and saved preferences")
    func restartDuringPreferences() throws {
        let fixture = try ProgressFixture()
        defer { fixture.removeDomain() }
        let first = fixture.app(hasDiskAccess: false)
        first.onboardingProgress?.save(.preferences)
        let settings = SettingsStore(defaults: fixture.defaults, managesLoginItem: false)
        settings.scanSchedule = .daily
        settings.lowSpaceAlertsEnabled = false

        let reopened = try fixture.reopenProgress()
        let next = AppModel(
            launchAccess: reopened.launchAccess(hasFullDiskAccess: true),
            onboardingProgress: reopened, hasFullDiskAccess: { true }
        )
        #expect(next.isShowingWelcome)
        #expect(reopened.pendingStep == .preferences)
        let restoredSettings = SettingsStore(defaults: reopened.defaults, managesLoginItem: false)
        #expect(restoredSettings.scanSchedule == .daily)
        #expect(!restoredSettings.lowSpaceAlertsEnabled)

        reopened.save(.welcome)
        #expect(try fixture.reopenProgress().pendingStep == .welcome)
    }

    @Test("Finishing or skipping setup clears restart recovery", arguments: [false, true])
    func finishSetup(hasDiskAccess: Bool) throws {
        let fixture = try ProgressFixture()
        defer { fixture.removeDomain() }
        let app = fixture.app(hasDiskAccess: hasDiskAccess)
        app.onboardingProgress?.save(.preferences)
        app.finishWelcomeGuide()

        let reopened = try fixture.reopenProgress()
        #expect(reopened.pendingStep == nil)
        #expect(reopened.launchAccess(hasFullDiskAccess: hasDiskAccess) == (hasDiskAccess ? .ready : .limited))
    }

    @Test("Opening the welcome guide again starts a resumable session")
    func reopenFromMenu() throws {
        let fixture = try ProgressFixture()
        defer { fixture.removeDomain() }
        fixture.defaults.set(true, forKey: "onboarding.completed")
        let app = fixture.app(hasDiskAccess: true)
        #expect(!app.isShowingWelcome)
        app.showWelcomeGuide()

        let reopened = try fixture.reopenProgress()
        #expect(reopened.pendingStep == .welcome)
        #expect(reopened.launchAccess(hasFullDiskAccess: true) == .welcome)
    }

    @Test("Access recovery also survives a restart")
    func revokedAccess() throws {
        let fixture = try ProgressFixture()
        defer { fixture.removeDomain() }
        fixture.defaults.set(true, forKey: "onboarding.completed")
        let app = AppModel(
            launchAccess: .ready, onboardingProgress: OnboardingProgress(defaults: fixture.defaults),
            hasFullDiskAccess: { false }
        )
        #expect(!app.checkDiskAccess())
        #expect(app.isShowingWelcome)
        let reopened = try fixture.reopenProgress()
        #expect(reopened.pendingStep == .welcome)
        #expect(reopened.launchAccess(hasFullDiskAccess: true) == .welcome)
    }
}

@MainActor
private struct ProgressFixture {
    let suite: String
    let defaults: UserDefaults

    init() throws {
        suite = "moppo-tests.onboarding-progress.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func reopenProgress() throws -> OnboardingProgress {
        OnboardingProgress(defaults: try #require(UserDefaults(suiteName: suite)))
    }

    func app(forceWelcome: Bool = false, hasDiskAccess: Bool) -> AppModel {
        let progress = OnboardingProgress(defaults: defaults)
        return AppModel(
            launchAccess: progress.launchAccess(hasFullDiskAccess: hasDiskAccess, forceWelcome: forceWelcome),
            onboardingProgress: progress, hasFullDiskAccess: { hasDiskAccess }
        )
    }

    func removeDomain() {
        defaults.removePersistentDomain(forName: suite)
    }
}
