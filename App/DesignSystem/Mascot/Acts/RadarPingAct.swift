import SwiftUI

/// Moppo braces, sends a few pings, then listens. Each ping is a ring in the air and a flat ring on the floor.
/// Hidden spots on the floor light up when a floor ring reaches them.
@MainActor
final class RadarPingAct: MascotAct {
    private enum Tuning {
        static let brace = 0.45, braceSquash = 0.12
        static let pings = 3, every = 0.6, hop = 260.0
        static let reach = 750.0, ringLife = 1.2, ringWidth = 18.0, floorFlatness = 0.05
        static let blips = 4, blipLife = 1.8
        static let listen = 1.0
    }

    private enum Phase { case brace, ping, listen, done }

    private struct Blip {
        let offsetX: Double
        var litAt: Double?
    }

    private var phase: MascotActPhase<Phase>
    private var squash = Spring(value: 0), glow = Spring(value: 0)
    private var pingsLeft = Tuning.pings
    private var nextPing = 0.0
    private var pings: [Double] = []
    private var blips: [Blip]
    private var time = 0.0

    init(rig: MascotRig) {
        phase = MascotActPhase(.brace, at: rig.time, duration: Tuning.brace)
        blips = (0..<Tuning.blips).map { _ in
            Blip(offsetX: (Bool.random() ? -1 : 1) * .random(in: 150...(Tuning.reach * 0.95)))
        }
    }

    var isFinished: Bool { phase.current == .done }

    private func radius(bornAt born: Double) -> Double {
        let p = min(1, (time - born) / Tuning.ringLife)
        return Tuning.reach * (1 - pow(1 - p, 2))
    }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time
        time = t
        squash.step(toward: phase.current == .brace ? Tuning.braceSquash : 0, stiffness: 300, damping: 0.5, dt: dt)
        glow.step(toward: phase.current == .brace || phase.current == .ping ? 1 : 0, stiffness: 120, damping: 0.8, dt: dt)
        if phase.current == .ping, t >= nextPing, pingsLeft > 0 {
            pings.append(t)
            pingsLeft -= 1
            nextPing = t + Tuning.every
            rig.kick(headY: -Tuning.hop, squash: 0)
            glow.velocity += 12
            if pingsLeft == 0 { phase.end = t + Tuning.ringLife * 0.5 }
        }
        pings.removeAll { t - $0 >= Tuning.ringLife }
        // A blip lights when a floor ring reaches it.
        for born in pings {
            let reach = radius(bornAt: born)
            for i in blips.indices where blips[i].litAt == nil && reach >= abs(blips[i].offsetX) { blips[i].litAt = t }
        }

        var gaze = (x: 0.0, y: 0.3)
        if phase.current == .listen {
            // Listen: glance to one side, then the other.
            let p = (t - phase.start) / Tuning.listen
            gaze = p < 0.45 ? (-0.9, 0.2) : p < 0.9 ? (0.9, 0.2) : (0, 0)
        }

        if phase.isOver(at: t) {
            switch phase.current {
            case .brace:
                phase.set(.ping, at: t, duration: .infinity)
                nextPing = t
            case .ping: phase.set(.listen, at: t, duration: Tuning.listen)
            case .listen, .done: phase.set(.done, at: t, duration: 0)
            }
        }
        return MascotControls(gaze: gaze, squash: squash.value, eyeGlow: glow.value)
    }

    func drawBehind(_ frame: MascotFrame, in graphics: inout GraphicsContext) {
        let color = MascotTuning.beamColor
        let cx = frame.pivot.x + frame.head.x, floorY = MascotTuning.floorY
        for born in pings {
            let a = (time - born) / Tuning.ringLife, r = radius(bornAt: born)
            let ring = Path(ellipseIn: CGRect(x: cx - r, y: floorY - r * Tuning.floorFlatness,
                                              width: r * 2, height: r * 2 * Tuning.floorFlatness))
            graphics.stroke(ring, with: .color(color.opacity(0.6 * (1 - a))), lineWidth: Tuning.ringWidth * 0.8)
        }
        for blip in blips {
            guard let lit = blip.litAt else { continue }
            let a = (time - lit) / Tuning.blipLife
            guard a < 1 else { continue }
            let x = cx + blip.offsetX, size = 26 * (1 + a)
            let dot = Gradient(stops: [
                .init(color: Color(red: 1, green: 236 / 255, blue: 170 / 255).opacity(1 - a), location: 0),
                .init(color: color.opacity(0.8 * (1 - a)), location: 0.4),
                .init(color: color.opacity(0), location: 1),
            ])
            var spot = graphics
            spot.translateBy(x: x, y: floorY)
            spot.scaleBy(x: size, y: size * 0.45)
            spot.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                      with: .radialGradient(dot, center: .zero, startRadius: 0, endRadius: 1))
        }
    }

    func drawFront(_ frame: MascotFrame, in graphics: inout GraphicsContext) {
        let color = MascotTuning.beamColor
        let o = MoppoMascotGeometry.center(of: frame.eyeCenters)
        for born in pings {
            let a = (time - born) / Tuning.ringLife, r = radius(bornAt: born) * 0.6
            graphics.stroke(Path(ellipseIn: CGRect(x: o.x - r, y: o.y - r, width: r * 2, height: r * 2)),
                            with: .color(color.opacity(0.85 * (1 - a))), lineWidth: Tuning.ringWidth * (1 - a * 0.7))
        }
    }
}
