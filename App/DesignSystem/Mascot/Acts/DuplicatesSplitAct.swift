import SwiftUI

/// A second Moppo slides out of the first. The two copies look at each other and blink together, turn in sync,
/// then slide back together into one Moppo, which bounces once. Only the duplicate scans show it.
@MainActor
final class DuplicatesSplitAct: MascotAct {
    private enum Tuning {
        static let distance = 760.0, stiffness = 140.0, damping = 0.5
        static let split = 0.55, look = 1.0
        static let syncTurns = 3, syncEvery = 0.5
        static let merge = 0.55, bounce = 500.0
    }

    private enum Phase { case split, look, sync, merge, done }

    private var phase: MascotActPhase<Phase>
    private var distance = Spring(value: 0)
    // The left copy and the right copy. Facing each other means the left one faces right.
    private var leftTurn: Spring, rightTurn: Spring
    private var syncFacing: Double
    private var syncTurnsLeft = 0
    private var nextSync = 0.0
    private var hasBlinkedInLook = false

    init(rig: MascotRig) {
        phase = MascotActPhase(.split, at: rig.time, duration: Tuning.split)
        leftTurn = Spring(value: rig.turn)
        rightTurn = Spring(value: rig.turn)
        syncFacing = rig.facing
    }

    var isFinished: Bool { phase.current == .done }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time, current = phase.current
        distance.step(toward: current == .merge ? 0 : Tuning.distance, stiffness: Tuning.stiffness, damping: Tuning.damping, dt: dt)
        let leftTarget = current == .look ? 1 : current == .sync ? syncFacing : rig.facing
        let rightTarget = current == .look ? -1 : current == .sync ? syncFacing : rig.facing
        leftTurn.step(toward: leftTarget, stiffness: MascotTuning.turnStiffness, damping: MascotTuning.turnDamping, dt: dt)
        rightTurn.step(toward: rightTarget, stiffness: MascotTuning.turnStiffness, damping: MascotTuning.turnDamping, dt: dt)
        if current == .sync, t >= nextSync, syncTurnsLeft > 0 {
            syncFacing = -syncFacing
            syncTurnsLeft -= 1
            nextSync = t + Tuning.syncEvery
            if Bool.random() { rig.startBlink() }
        }
        // The copies blink at the same moment while they look at each other.
        if current == .look, !hasBlinkedInLook, t - phase.start > Tuning.look * 0.5 {
            hasBlinkedInLook = true
            rig.startBlink()
        }

        if phase.isOver(at: t) {
            switch current {
            case .split: phase.set(.look, at: t, duration: Tuning.look)
            case .look:
                syncTurnsLeft = Tuning.syncTurns
                nextSync = t
                phase.set(.sync, at: t, duration: Double(Tuning.syncTurns) * Tuning.syncEvery + 0.3)
            case .sync: phase.set(.merge, at: t, duration: Tuning.merge)
            case .merge:
                phase.set(.done, at: t, duration: 0)
                rig.kick(headY: -Tuning.bounce, squash: -Tuning.bounce / 300)
            case .done: break
            }
        }
        return MascotControls(gaze: current == .sync ? (syncFacing * 0.8, -0.2) : (0, 0))
    }

    var copies: [MascotCopy]? {
        guard !isFinished else { return nil }
        // The copies meet in the middle and do not cross, even when the merge spring overshoots.
        let half = CGFloat(max(0, distance.value) / 2)
        let isLooking = phase.current == .look
        // While they face each other, each copy looks at the other one.
        return [
            MascotCopy(turn: leftTurn.value, offsetX: -half, eyeX: isLooking ? 0.9 : nil),
            MascotCopy(turn: rightTurn.value, offsetX: half, eyeX: isLooking ? -0.9 : nil),
        ]
    }
}
