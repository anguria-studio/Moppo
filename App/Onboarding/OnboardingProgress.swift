import Foundation
import MoppoCore

/// Preserves unfinished setup when macOS restarts the app after a permission change.
struct OnboardingProgress {
    enum Step: String { case welcome, preferences }

    let defaults: UserDefaults
    private static let stepKey = "onboarding.step"
    private static let completedKey = "onboarding.completed"

    var pendingStep: Step? {
        guard let value = defaults.string(forKey: Self.stepKey) else { return nil }
        return Step(rawValue: value) ?? .welcome
    }

    func launchAccess(hasFullDiskAccess: Bool, forceWelcome: Bool = false) -> LaunchAccess {
        LaunchAccess(
            hasCompletedOnboarding: defaults.bool(forKey: Self.completedKey) && pendingStep == nil,
            hasFullDiskAccess: hasFullDiskAccess,
            forceWelcome: forceWelcome
        )
    }

    func begin() {
        guard pendingStep == nil else { return }
        save(.welcome)
    }

    func save(_ step: Step) {
        defaults.set(step.rawValue, forKey: Self.stepKey)
    }

    func finish() {
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.stepKey)
    }
}
