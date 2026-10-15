import SwiftUI

/// Moppo stretches up with its eyes shut, gets sleepy with floating z letters, then shakes itself awake
/// and its eyes pop open. Only long scans show it.
@MainActor
final class YawnAct: MascotAct {
    private enum Tuning {
        static let stretchTime = 1.2, stretch = 0.16, headBack = 9.0
        static let sleepyTime = 1.8, sleepyLids = 0.3, sag = 22.0
        static let letters = 3, letterSize = 70.0, letterLife = 1.6
        static let wakeTime = 0.5, wakeShake = 16.0
    }

    /// After the wake, the act settles until the last z letter fades.
    private enum Phase { case stretch, sleepy, wake, settle, done }

    private var phase: MascotActPhase<Phase>
    private var lids = Spring(value: 1), squash = Spring(value: 0)
    private var letters: [Double] = []
    private var nextLetter = 0.0
    private var time = 0.0
    private var facing = 1.0

    init(rig: MascotRig) {
        phase = MascotActPhase(.stretch, at: rig.time, duration: Tuning.stretchTime)
    }

    var isFinished: Bool { phase.current == .done }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time, current = phase.current, p = phase.progress(at: t)
        time = t
        facing = rig.facing
        switch current {
        case .stretch:
            lids.step(toward: 0.08, stiffness: 60, damping: 0.9, dt: dt)
            squash.step(toward: -Tuning.stretch, stiffness: 120, damping: 0.8, dt: dt)
        case .sleepy:
            lids.step(toward: Tuning.sleepyLids, stiffness: 60, damping: 0.9, dt: dt)
            squash.step(toward: 0.05, stiffness: 120, damping: 0.8, dt: dt)
            if t >= nextLetter, letters.count < Tuning.letters {
                letters.append(t)
                nextLetter = t + Tuning.sleepyTime / Double(Tuning.letters)
            }
        case .wake:
            lids.step(toward: 1.15, stiffness: 400, damping: 0.4, dt: dt)
            squash.step(toward: -0.05, stiffness: 120, damping: 0.35, dt: dt)
        case .settle, .done:
            lids.step(toward: 1, stiffness: 200, damping: 0.6, dt: dt)
            squash.step(toward: 0, stiffness: 300, damping: 0.5, dt: dt)
        }
        letters.removeAll { t - $0 >= Tuning.letterLife }

        let gaze: (x: Double, y: Double) = switch current {
        case .stretch: (0, -0.3)
        case .sleepy: (sin(t * 1.3) * 0.3, 0.35)
        case .wake, .settle, .done: (0, 0)
        }
        // Tip back while stretching, sag and sway while sleepy, and shake when waking.
        let head: (x: Double, y: Double, angle: Double)? = switch current {
        case .stretch: (0, -10, -facing * Tuning.headBack)
        case .sleepy: (sin(t * 1.6) * 10, Tuning.sag, sin(t * 1.6) * 3)
        case .wake: (sin(t * 45) * Tuning.wakeShake * (1 - p), 0, 0)
        case .settle, .done: nil
        }

        switch current {
        case .stretch where phase.isOver(at: t):
            nextLetter = t + 0.2
            phase.set(.sleepy, at: t, duration: Tuning.sleepyTime)
        case .sleepy where phase.isOver(at: t): phase.set(.wake, at: t, duration: Tuning.wakeTime)
        case .wake where phase.isOver(at: t): phase.set(.settle, at: t, duration: Tuning.letterLife)
        case .settle where letters.isEmpty || phase.isOver(at: t): phase.set(.done, at: t, duration: 0)
        default: break
        }
        return MascotControls(gaze: gaze, head: head, squash: squash.value, lids: lids.value)
    }

    /// Each z letter rises from the top of the head, drifts, grows, and fades.
    func drawFront(_ frame: MascotFrame, in graphics: inout GraphicsContext) {
        guard !letters.isEmpty, frame.eyeCenters.count == 2 else { return }
        let from = CGPoint(x: (frame.eyeCenters[0].x + frame.eyeCenters[1].x) / 2,
                           y: min(frame.eyeCenters[0].y, frame.eyeCenters[1].y) - 60)
        for born in letters {
            let a = (time - born) / Tuning.letterLife
            var context = graphics
            context.opacity = sin(a * .pi) * 0.9
            let letter = frame.bodyColored(Text("z")
                .font(.system(size: Tuning.letterSize * (0.6 + 0.6 * a), weight: .bold, design: .rounded)))
            context.draw(letter, at: CGPoint(x: from.x + facing * (40 + 70 * a) + sin(a * 6) * 18, y: from.y - 160 * a))
        }
    }
}
