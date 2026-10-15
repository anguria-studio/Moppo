import SwiftUI

/// Moppo squashes, morphs into a flaming eye, searches with a slit pupil, then morphs back.
@MainActor
final class SauronEyeAct: MascotAct {
    private enum Tuning {
        static let gather = 0.35, gatherSquash = 0.2
        static let morphTime = 0.9, search = 3.5
        static let stiffness = 55.0, damping = 0.6
        static let halfWidth = 330.0, halfHeight = 150.0, centerY = 240.0
        static let flameHeight = 38.0, flameSpeed = 1.0
        static let pupilHalfWidth = 18.0, pupilHalfHeight = 105.0, pupilTravel = 120.0
    }

    private enum Phase { case gather, morphIn, search, morphOut, done }

    private var phase: MascotActPhase<Phase>
    private var morphSpring = Spring(value: 0), squash = Spring(value: 0)
    private var pupilX = Spring(value: 0), pupilWidth = Spring(value: 1)
    private var lookX = 0.0, dilate = 1.0, nextLook = 0.0
    private var outline: (points: [CGPoint], normals: [CGPoint], angles: [Double])?

    init(rig: MascotRig) {
        phase = MascotActPhase(.gather, at: rig.time, duration: Tuning.gather)
    }

    var isFinished: Bool { phase.current == .done }

    /// The morph can overshoot a little past the eye, which reads as a spring.
    private var amount: CGFloat { CGFloat(min(1.15, max(0, morphSpring.value))) }
    private var fire: Double { min(1, Double(amount)) }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time
        let isSearching = phase.current == .search
        morphSpring.step(toward: phase.current == .morphIn || isSearching ? 1 : 0,
                         stiffness: Tuning.stiffness, damping: Tuning.damping, dt: dt)
        squash.step(toward: phase.current == .gather ? Tuning.gatherSquash : 0, stiffness: 300, damping: 0.5, dt: dt)
        if isSearching, t >= nextLook {
            lookX = .random(in: -1...1)
            nextLook = t + .random(in: 0.5...1.2)
            dilate = Double.random(in: 0..<1) < 0.35 ? .random(in: 0.5...2) : 1
        }
        pupilX.step(toward: isSearching ? lookX : 0, stiffness: 40, damping: 0.8, dt: dt)
        pupilWidth.step(toward: isSearching ? dilate : 1, stiffness: 60, damping: 0.6, dt: dt)

        if phase.isOver(at: t) {
            switch phase.current {
            case .gather: phase.set(.morphIn, at: t, duration: Tuning.morphTime)
            case .morphIn:
                phase.set(.search, at: t, duration: Tuning.search)
                nextLook = t
            case .search:
                phase.set(.morphOut, at: t, duration: Tuning.morphTime)
                dilate = 1
            case .morphOut, .done: phase.set(.done, at: t, duration: 0)
            }
        }
        return MascotControls(gaze: (0, 0), squash: squash.value)
    }

    private func pupilCenter(_ frame: MascotFrame) -> CGPoint {
        CGPoint(x: frame.geometry.centerX + pupilX.value * Tuning.pupilTravel, y: Tuning.centerY)
    }

    func shape(_ frame: inout MascotFrame) {
        let m = amount
        guard m > 0.001 else { return }
        let outline = outline ?? makeOutline(frame.geometry)
        self.outline = outline
        let t = frame.time
        frame.body = morph(frame.body, toward: { i in
            // Flames: a flicker that moves along the edge, taller on the top half and pulled upward.
            let base = outline.points[i], n = outline.normals[i], angle = outline.angles[i]
            let up = max(0, -n.y)
            let f = Tuning.flameHeight * (0.55 + 0.45 * sin(angle * 9 + t * Tuning.flameSpeed * 6)
                * sin(angle * 4 - t * Tuning.flameSpeed * 4.3))
            let push = CGFloat(f * (0.35 + 0.9 * Double(up)))
            return CGPoint(x: base.x + n.x * push, y: base.y + n.y * push - CGFloat(f * 0.7) * up)
        }, amount: m)
        // Both eyes flow into one slit pupil.
        let center = pupilCenter(frame)
        frame.eyes = frame.eyes.map { eye in
            let slit = roundEye(center: center, radiusX: Tuning.pupilHalfWidth * pupilWidth.value,
                                radiusY: Tuning.pupilHalfHeight * frame.openness, count: eye.count)
            return morph(eye, toward: { slit[$0] }, amount: m)
        }
        frame.eyeCenters = frame.eyeCenters.map { MoppoMascotGeometry.mix($0, center, m) }
    }

    func drawBehind(_ frame: MascotFrame, in graphics: inout GraphicsContext) {
        guard fire > 0.01 else { return }
        // A soft fiery glow around the eye.
        let center = pupilCenter(frame), radius = Tuning.halfWidth * 1.5
        let halo = Gradient(colors: [Color(red: 1, green: 120 / 255, blue: 20 / 255).opacity(0.35 * fire),
                                     Color(red: 1, green: 60 / 255, blue: 0).opacity(0)])
        graphics.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                      with: .radialGradient(halo, center: center, startRadius: 0, endRadius: radius))
    }

    func drawOnBody(_ frame: MascotFrame, body: Path, in graphics: inout GraphicsContext) {
        guard fire > 0.01 else { return }
        // The body color fades into fire: yellow at the pupil, orange, then deep red at the edge.
        let flame = Gradient(stops: [
            .init(color: Color(red: 1, green: 0xF2 / 255, blue: 0xA0 / 255), location: 0),
            .init(color: Color(red: 1, green: 0xB2 / 255, blue: 0x1A / 255), location: 0.25),
            .init(color: Color(red: 1, green: 0x5A / 255, blue: 0), location: 0.6),
            .init(color: Color(red: 0x9E / 255, green: 0x14 / 255, blue: 0), location: 1),
        ])
        var context = graphics
        context.opacity = fire
        context.fill(body, with: .radialGradient(flame, center: pupilCenter(frame), startRadius: 0, endRadius: Tuning.halfWidth))
    }

    func drawInEyes(_ frame: MascotFrame, eyes: Path, in graphics: inout GraphicsContext) {
        guard fire > 0.01 else { return }
        // The slit pupil is dark, not a hole, so it reads on both light and dark pages.
        graphics.fill(eyes, with: .color(Color(red: 25 / 255, green: 4 / 255, blue: 0).opacity(fire)))
    }

    /// An almond: two circle arcs that meet in points at the left and right ends.
    private func makeOutline(_ geometry: MoppoMascotGeometry) -> (points: [CGPoint], normals: [CGPoint], angles: [Double]) {
        let a = Tuning.halfWidth, b = Tuning.halfHeight, cx = geometry.centerX, cy = Tuning.centerY
        let k = (a * a - b * b) / (2 * b), r = k + b
        var dense: [CGPoint] = []
        func arc(_ offsetY: Double, from: Double, to: Double, count: Int) {
            for i in 0..<count {
                let angle = from + (to - from) * Double(i) / Double(count)
                dense.append(CGPoint(x: cx + r * cos(angle), y: cy + offsetY + r * sin(angle)))
            }
        }
        arc(k, from: -.pi / 2, to: atan2(-k, a), count: 200)
        arc(-k, from: atan2(k, a), to: atan2(k, -a), count: 400)
        arc(k, from: atan2(-k, -a), to: -.pi / 2, count: 200)
        let points = geometry.outline(matching: dense)
        // Outward normals, from the next point. The outline runs clockwise.
        let normals = points.indices.map { i -> CGPoint in
            let p = points[i], q = points[(i + 1) % points.count]
            let length = max(0.0001, hypot(q.x - p.x, q.y - p.y))
            return CGPoint(x: (q.y - p.y) / length, y: -(q.x - p.x) / length)
        }
        let angles = points.map { atan2(Double($0.y) - cy, Double($0.x) - cx) }
        return (points, normals, angles)
    }
}
