import SwiftUI

/// Scan beams: Moppo charges its eyes, fires two beams, sweeps them up or down, and powers down.
extension MoppoMascotMotion {
    /// The duplicate scans are long, so Moppo fires even less often during them.
    var restDuration: Double {
        let rest = mode == .scanning ? T.scanRest : T.duplicateScanRest
        return rest * Double.random(in: 0.7...1.3)
    }

    var beamColor: Color { mode == .destroying ? T.destroyColor : T.beamColor }

    func updateBeams(_ dt: Double) {
        stepBeamPhase()
        let isFiring = phase == .charge || phase == .fire || phase == .sweep || phase == .off
        if isFiring {
            let direction = beamDirection().direction
            gaze = (Double(direction.x) * 0.9, Double(direction.y) * 0.9)
            micro = (0, 0)
        } else if phase == .rest {
            // During the rests between shots, Moppo searches without rays.
            updateSearch()
        }
        if !isFiring, time >= nextBlink { scheduleBlink() }
        // Blinks while shooting cut the beams for a moment.
        if phase == .sweep, time >= nextShotBlink {
            startBlink()
            nextShotBlink = time + .random(in: (T.shotBlinkEvery * 0.5)...(T.shotBlinkEvery * 1.5))
        }

        if phase == .sweep {
            elevation = clampElevation(sweepFrom + (sweepTo - sweepFrom) * MascotEasing.inOut(phaseProgress))
        }
    }

    var phaseProgress: Double {
        min(1, (time - phaseStart) / max(0.001, phaseEnd - phaseStart))
    }

    func stepBeamSprings(_ dt: Double) {
        let progress = phaseProgress
        let isOn = phase == .fire || phase == .sweep
        let glowTarget: Double = phase == .charge || isOn || (phase == .off && progress < 0.6) ? 1 : 0
        let lengthTarget: Double = isOn || (phase == .off && progress < 0.4) ? 1 : 0
        let thicknessTarget: Double = isOn ? 1 : phase == .off ? 0.08 : 0
        eyeGlow.step(toward: glowTarget, stiffness: 500, damping: 0.9, dt: dt)
        beamLength.step(toward: lengthTarget, stiffness: 500, damping: 0.85, dt: dt)
        beamThickness.step(toward: thicknessTarget, stiffness: 600, damping: 0.8, dt: dt)
        squash.step(toward: phase == .off ? T.offSquash : 0, stiffness: 300, damping: 0.45, dt: dt)
    }

    private func stepBeamPhase() {
        // Turn around in the middle of a sweep. The beams follow the turn to the new side and keep sweeping.
        if phase == .sweep, turnInSweep, pendingFacing == nil,
           time >= phaseStart + (phaseEnd - phaseStart) * 0.35 {
            turnInSweep = false
            turnAround()
            pickSweep(from: elevation)
            setPhase(.sweep, duration: T.sweepTime)
            return
        }
        guard time >= phaseEnd else { return }
        switch phase {
        case .rest:
            if mode == .scanning, Double.random(in: 0..<1) < T.turnBetweenShots {
                turnAround()
                setPhase(.turning, duration: T.eyeLead + 0.35)
            } else {
                startCharge()
            }
        case .turning, .aim:
            startCharge()
        case .charge:
            setPhase(.fire, duration: T.fireTime)
            recoil()
        case .fire:
            setPhase(.sweep, duration: T.sweepTime)
            turnInSweep = Double.random(in: 0..<1) < T.turnWhileShooting
            nextShotBlink = time + .random(in: (T.shotBlinkEvery * 0.5)...(T.shotBlinkEvery * 1.5))
        case .sweep:
            setPhase(.off, duration: T.offTime)
        case .off:
            setPhase(.rest, duration: restDuration)
        }
    }

    func setPhase(_ next: BeamPhase, duration: Double) {
        phase = next
        phaseStart = time
        phaseEnd = time + duration
    }

    /// Firing pushes the head back, away from the beams.
    func recoil() {
        let direction = beamDirection().direction
        headX.velocity -= Double(direction.x) * T.recoil
        headY.velocity -= Double(direction.y) * T.recoil * 0.5
    }

    private func startCharge() {
        // Aim toward the side Moppo faces, then sweep up or down within the allowed angles.
        pickSweep(from: .random(in: -T.maxUp...T.maxDown))
        elevation = sweepFrom
        setPhase(.charge, duration: T.chargeTime)
    }

    private func pickSweep(from start: Double) {
        sweepFrom = start
        let direction = start > (T.maxDown - T.maxUp) / 2 ? -1.0 : 1.0
        sweepTo = clampElevation(start + direction * T.sweepRange * .random(in: 0.6...1))
    }

    private func clampElevation(_ value: Double) -> Double {
        min(T.maxDown, max(-T.maxUp, value))
    }

    /// Mid turn, Moppo faces the viewer, so the beams point out of the screen and look short.
    func beamDirection() -> (direction: CGPoint, reach: CGFloat) {
        if mode == .destroying {
            let a = rayAngle * .pi / 180
            return (CGPoint(x: cos(a), y: sin(a)), 1)
        }
        let e = elevation * .pi / 180
        let side = min(1, max(-1, bodyTurn.value))
        let x = side * cos(e), y = sin(e)
        let length = hypot(x, y)
        guard length > 0 else { return (CGPoint(x: 0, y: 1), 0.2) }
        return (CGPoint(x: x / length, y: y / length), CGFloat(max(0.2, length)))
    }
}
