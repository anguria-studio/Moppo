import SwiftUI

struct OnboardingEntrance: ViewModifier {
    var index: Int
    var enabled = true
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isVisible: Bool { hasAppeared || !enabled || reduceMotion }

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: isVisible ? 0 : 16)
            .animation(
                enabled && !reduceMotion ? .easeOut(duration: 0.2).delay(Double(index) * 0.03) : nil,
                value: hasAppeared
            )
            .onAppear { hasAppeared = true }
    }
}
