import SwiftUI

/// Moppo turns into a magnifying lens and glides it to random spots, then turns back.
/// The outline flows into the outer edge of the ring and the handle, and both eyes flow into the glass.
@MainActor
final class MagnifyingLensAct: MascotAct {
    private enum Tuning {
        static let gather = 0.35, gatherSquash = 0.15
        static let morphTime = 0.45, search = 4.5
        static let stiffness = 245.0, damping = 0.5
        static let radius = 165.0, ring = 34.0, centerY = 332.0
        static let handleWidth = 58.0, handleLength = 210.0, handleAngle = 45.0
        static let travelX = 285.0, travelY = 189.0
        static let move = 0.7, stop = 0.45, tilt = 18.5
        // The bounce when the lens turns back into Moppo
        static let recoil = 420.0
    }

    private enum Phase { case gather, morphIn, search, morphOut, done }

    private var phase: MascotActPhase<Phase>
    private var morphSpring = Spring(value: 0), squash = Spring(value: 0)
    private var lensX = Spring(value: 0), lensY = Spring(value: 0), tilt = Spring(value: 0)
    private var target = CGPoint.zero
    private var isMoving = false
    private var nextStop = 0.0
    /// The lens outline for the side that Moppo faces. The handle points down and away from that side.
    private var outline: (side: Double, points: [CGPoint])?

    init(rig: MascotRig) {
        phase = MascotActPhase(.gather, at: rig.time, duration: Tuning.gather)
    }

    var isFinished: Bool { phase.current == .done }

    private var amount: CGFloat { CGFloat(min(1.15, max(0, morphSpring.value))) }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time
        let isSearching = phase.current == .search
        morphSpring.step(toward: phase.current == .morphIn || isSearching ? 1 : 0,
                         stiffness: Tuning.stiffness, damping: Tuning.damping, dt: dt)
        squash.step(toward: phase.current == .gather ? Tuning.gatherSquash : 0, stiffness: 300, damping: 0.5, dt: dt)
        if isSearching, t >= nextStop {
            isMoving.toggle()
            nextStop = t + (isMoving ? Tuning.move : Tuning.stop)
            if isMoving {
                target = CGPoint(x: .random(in: -1...1) * Tuning.travelX, y: .random(in: -1...1) * Tuning.travelY)
            }
        }
        let goal = isSearching ? target : .zero
        let k = 4 / max(0.1, Tuning.move)
        lensX.step(toward: goal.x, stiffness: k * k, damping: 0.85, dt: dt)
        lensY.step(toward: goal.y, stiffness: k * k, damping: 0.85, dt: dt)
        // Lean into the movement a little.
        tilt.step(toward: min(1, max(-1, lensX.velocity / 300)) * Tuning.tilt, stiffness: 120, damping: 0.7, dt: dt)

        if phase.isOver(at: t) {
            switch phase.current {
            case .gather: phase.set(.morphIn, at: t, duration: Tuning.morphTime)
            case .morphIn:
                phase.set(.search, at: t, duration: Tuning.search)
                nextStop = t
            case .search: phase.set(.morphOut, at: t, duration: Tuning.morphTime)
            case .morphOut:
                phase.set(.done, at: t, duration: 0)
                rig.kick(headY: -Tuning.recoil, squash: -Tuning.recoil / 300)
            case .done: break
            }
        }
        return MascotControls(gaze: (0, 0), squash: squash.value)
    }

    private func center(_ geometry: MoppoMascotGeometry) -> CGPoint {
        CGPoint(x: geometry.centerX, y: Tuning.centerY)
    }

    /// Tilts the lens around its center, then moves it with the search.
    private func place(_ p: CGPoint, around c: CGPoint) -> CGPoint {
        let a = tilt.value * .pi / 180, dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a) + lensX.value, y: c.y + dx * sin(a) + dy * cos(a) + lensY.value)
    }

    func shape(_ frame: inout MascotFrame) {
        let m = amount
        guard m > 0.001 else { return }
        let side: Double = frame.turn >= 0 ? 1 : -1
        if outline?.side != side { outline = (side, makeOutline(frame.geometry, side: side)) }
        guard let points = outline?.points else { return }
        let c = center(frame.geometry)
        frame.body = morph(frame.body, toward: { self.place(points[$0], around: c) }, amount: m)
        // Both eyes grow into the round hole of the lens, so they become the glass.
        let inner = Tuning.radius - Tuning.ring
        frame.eyes = frame.eyes.map { eye in
            let glass = roundEye(center: c, radiusX: inner, radiusY: inner, count: eye.count)
            return morph(eye, toward: { self.place(glass[$0], around: c) }, amount: m)
        }
        let placed = place(c, around: c)
        frame.eyeCenters = frame.eyeCenters.map { MoppoMascotGeometry.mix($0, placed, m) }
    }

    func drawInEyes(_ frame: MascotFrame, eyes: Path, in graphics: inout GraphicsContext) {
        let glass = min(1, Double(amount))
        guard glass > 0.01 else { return }
        // The glass: a light tint and a curved glint near the top left of the rim.
        let c = center(frame.geometry), q = place(c, around: c), inner = Tuning.radius - Tuning.ring
        graphics.fill(eyes, with: .color(Color(red: 190 / 255, green: 225 / 255, blue: 1).opacity(MascotTuning.glassTint * glass)))
        let a = tilt.value * .pi / 180
        let glint = ellipseArc(center: q, radiusX: inner * 0.72, radiusY: inner * 0.72,
                               from: .pi * 1.08 + a, to: .pi * 1.38 + a)
        graphics.stroke(glint, with: .color(.white.opacity(MascotTuning.glint * glass)),
                        style: StrokeStyle(lineWidth: inner * 0.09, lineCap: .round))
    }

    /// Clockwise from the top: the rim to the handle, out along one edge, the round end, back along the other edge.
    private func makeOutline(_ geometry: MoppoMascotGeometry, side: Double) -> [CGPoint] {
        let c = center(geometry), r = Tuning.radius, half = Tuning.handleWidth / 2
        let angle = (side >= 0 ? 180 - Tuning.handleAngle : Tuning.handleAngle) * .pi / 180
        let d = CGPoint(x: cos(angle), y: sin(angle)), n = CGPoint(x: -sin(angle), y: cos(angle))
        let delta = asin(min(0.99, half / r)), base = r * cos(delta)
        func normalized(_ a: Double) -> Double {
            var a = a
            while a < -.pi / 2 { a += 2 * .pi }
            while a >= 1.5 * .pi { a -= 2 * .pi }
            return a
        }
        var dense: [CGPoint] = []
        func circle(from: Double, to: Double, steps: Int) {
            for i in 0..<steps {
                let a = from + (to - from) * Double(i) / Double(steps)
                dense.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
            }
        }
        func along(_ u: Double, _ sideSign: Double) -> CGPoint {
            CGPoint(x: c.x + d.x * (base + Tuning.handleLength * u) + n.x * half * sideSign,
                    y: c.y + d.y * (base + Tuning.handleLength * u) + n.y * half * sideSign)
        }
        circle(from: -.pi / 2, to: normalized(angle - delta), steps: 160)
        for i in 0..<40 { dense.append(along(Double(i) / 40, -1)) }
        let end = CGPoint(x: c.x + d.x * (base + Tuning.handleLength), y: c.y + d.y * (base + Tuning.handleLength))
        for i in 0..<24 {
            let a = angle - .pi / 2 + .pi * Double(i) / 24
            dense.append(CGPoint(x: end.x + half * cos(a), y: end.y + half * sin(a)))
        }
        for i in 0..<40 { dense.append(along(1 - Double(i) / 40, 1)) }
        circle(from: normalized(angle + delta), to: 1.5 * .pi, steps: 160)
        return geometry.outline(matching: dense)
    }
}
