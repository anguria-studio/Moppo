import SwiftUI

/// Large deletion: red rays sweep a half circle below Moppo while it turns from one side to the other.
extension MoppoMascotMotion {
    /// One pass: face the start side, charge, fire, then sweep a half circle below Moppo to the other side.
    /// The ray angle drives the turn, so Moppo faces the viewer when the rays point straight down.
    func updateDestroying(_ dt: Double) {
        stepDestroyPhase()
        let isFiring = phase == .charge || phase == .fire || phase == .sweep || phase == .off
        if isFiring || phase == .aim {
            let direction = beamDirection().direction
            gaze = (Double(direction.x) * 0.9, Double(direction.y) * 0.9)
            micro = (0, 0)
        } else if phase == .rest {
            // Between passes, Moppo looks around and blinks. It does not blink while the rays are on.
            lookAround()
        }
        let isOn = phase == .fire || phase == .sweep
        shake = isOn
            ? CGPoint(x: CGFloat(Double.random(in: -1...1) * T.destroyShake),
                      y: CGFloat(Double.random(in: -1...1) * T.destroyShake))
            : .zero
    }

    private func stepDestroyPhase() {
        let from = destroyDirection > 0 ? 180 - T.destroyStartBelow : T.destroyStartBelow
        let to = 180 - from
        if phase == .sweep {
            rayAngle = from + (to - from) * MascotEasing.inOut(phaseProgress)
            facing = cos(rayAngle * .pi / 180)
        }
        guard time >= phaseEnd else { return }
        switch phase {
        case .rest, .turning:
            let startFacing: Double = cos(from * .pi / 180) < 0 ? -1 : 1
            rayAngle = from
            pendingFacing = nil
            if facing == startFacing {
                // Moppo already faces the side where the next pass starts, so it fires again at once.
                setPhase(.charge, duration: T.openingCharge)
            } else {
                facing = startFacing
                setPhase(.aim, duration: 0.45)
            }
        case .aim:
            setPhase(.charge, duration: T.chargeTime)
        case .charge:
            setPhase(.fire, duration: T.fireTime)
            recoil()
        case .fire:
            setPhase(.sweep, duration: T.destroySweepTime)
        case .sweep:
            facing = facing < 0 ? -1 : 1
            setPhase(.off, duration: T.offTime)
        case .off:
            if T.destroyAlternates { destroyDirection = -destroyDirection }
            setPhase(.rest, duration: T.destroyRest)
        }
    }
}
