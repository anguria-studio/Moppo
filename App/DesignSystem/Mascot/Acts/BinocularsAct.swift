import SwiftUI

/// Moppo faces the viewer and springs into binoculars seen from the front: two round lenses and a bridge.
/// Then the binoculars act like Moppo: they turn to look at the sides, glance around, and blink.
/// They are two cylinders, so a turn shows their length. At the end they face the viewer again
/// and spring back into Moppo, which turns to its side.
@MainActor
final class BinocularsAct: MascotAct {
    private enum Tuning {
        static let morphTime = 0.9, stiffness = 200.0, damping = 0.5
        static let barrelRadius = 105.0, gap = 30.0, bridgeHeight = 70.0, centerY = 260.0
        static let lensSize = 0.78, barrelLength = 360.0
        static let lineOpacity = 0.45, lineWidth = 19.5, shading = 0.1
        static let eyepieceLength = 70.0, eyepieceSize = 0.6
        static let yaw = 55.0, pupil = 0.45
        static let look = 4.5, turnEvery = 1.8
    }

    private enum Phase { case morph, look, front, back, done }

    private var phase: MascotActPhase<Phase>
    private var morphSpring = Spring(value: 0)
    private var nextTurn = 0.0
    private var outline: [CGPoint]?

    init(rig: MascotRig) {
        phase = MascotActPhase(.morph, at: rig.time, duration: Tuning.morphTime)
    }

    var isFinished: Bool { phase.current == .done }

    /// While they look around, the binoculars are drawn as 3D cylinders instead of a flat outline.
    private var isLive: Bool { phase.current == .look || phase.current == .front }

    private var amount: CGFloat { CGFloat(min(1.15, max(0, morphSpring.value))) }

    private static var lensRadius: Double { Tuning.barrelRadius * Tuning.lensSize }
    private static var lensOffset: Double { Tuning.gap / 2 + Tuning.barrelRadius }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time, current = phase.current
        morphSpring.step(toward: current == .back ? 0 : 1, stiffness: Tuning.stiffness, damping: Tuning.damping, dt: dt)
        var controls = MascotControls(gaze: (0, 0))
        switch current {
        case .look:
            // Search like Moppo: glance around, blink, and turn to the other side now and then.
            controls.gaze = nil
            rig.lookAround()
            if t >= nextTurn {
                rig.turnAround()
                nextTurn = t + .random(in: 0.7...1.3) * Tuning.turnEvery
            }
        case .morph, .front:
            controls.facing = 0
        case .back, .done:
            break
        }

        if phase.isOver(at: t) {
            switch current {
            case .morph:
                nextTurn = t + 0.2
                phase.set(.look, at: t, duration: Tuning.look)
            case .look: phase.set(.front, at: t, duration: 0.45)
            case .front: phase.set(.back, at: t, duration: 0.6)
            case .back, .done: phase.set(.done, at: t, duration: 0)
            }
        }
        return controls
    }

    private func lensCenters(_ geometry: MoppoMascotGeometry) -> [CGPoint] {
        [-1.0, 1.0].map { CGPoint(x: geometry.centerX + $0 * Self.lensOffset, y: Tuning.centerY) }
    }

    func shape(_ frame: inout MascotFrame) {
        let m = amount
        guard m > 0.001 else { return }
        let outline = outline ?? makeOutline(frame.geometry)
        self.outline = outline
        frame.body = morph(frame.body, toward: { outline[$0] }, amount: m)
        // Each eye grows into the lens of one barrel.
        let lenses = lensCenters(frame.geometry), k = min(1, m)
        for e in frame.eyes.indices {
            let lens = roundEye(center: lenses[e], radiusX: Self.lensRadius, radiusY: Self.lensRadius, count: frame.eyes[e].count)
            frame.eyes[e] = morph(frame.eyes[e], toward: { lens[$0] }, amount: k)
            frame.eyeCenters[e] = MoppoMascotGeometry.mix(frame.eyeCenters[e], lenses[e], k)
        }
    }

    func drawInEyes(_ frame: MascotFrame, eyes: Path, in graphics: inout GraphicsContext) {
        let glass = min(1, Double(amount))
        guard glass > 0.01 else { return }
        // Dark glass with a pupil and a glint in each lens.
        let r = Self.lensRadius
        graphics.fill(eyes, with: .color(Self.glassColor.opacity(0.92 * glass)))
        for o in frame.eyeCenters {
            let pupil = r * Tuning.pupil
            graphics.fill(Path(ellipseIn: CGRect(x: o.x - pupil, y: o.y - pupil, width: pupil * 2, height: pupil * 2)),
                          with: .color(.black.opacity(0.9 * glass)))
            graphics.stroke(ellipseArc(center: o, radiusX: r * 0.7, radiusY: r * 0.7, from: .pi * 1.1, to: .pi * 1.42),
                            with: .color(.white.opacity(MascotTuning.glint * glass)),
                            style: StrokeStyle(lineWidth: r * 0.11, lineCap: .round))
        }
    }

    private static let glassColor = Color(red: 20 / 255, green: 24 / 255, blue: 30 / 255)

    /// Draws the binoculars as two cylinders and a bridge, turned by the same turn as Moppo. A barrel is the outline
    /// of its back and front ends (ovals) and the band between them. The barrel farther from the viewer is drawn first.
    /// Each front lens has dark glass, a pupil that follows the gaze, and a glint. A blink narrows the glass.
    func drawInstead(_ frame: MascotFrame, in graphics: inout GraphicsContext) -> Bool {
        guard isLive else { return false }
        let yaw = min(1, max(-1, frame.turn)) * Tuning.yaw * .pi / 180
        let c = cos(yaw), s = sin(yaw), length = Tuning.barrelLength, radius = Tuning.barrelRadius
        var g = graphics
        g.translateBy(x: frame.geometry.centerX + frame.head.x + frame.offset.x, y: Tuning.centerY + frame.head.y + frame.offset.y)
        g.rotate(by: .degrees(frame.headAngle * 0.6))
        let line = GraphicsContext.Shading.color(.black.opacity(Tuning.lineOpacity))
        let lineStyle = StrokeStyle(lineWidth: Tuning.lineWidth)
        func oval(_ x: Double, _ r: Double) -> Path {
            Path(ellipseIn: CGRect(x: x - r * abs(c), y: -r, width: 2 * r * abs(c), height: 2 * r))
        }

        // One cylinder along the barrel axis, from depth `near` to `far`, with radius r. Its ends are ovals.
        func cylinder(_ xb: Double, from t0: Double, to t1: Double, radius r: Double) {
            let a = xb * c + t0 * s, b = xb * c + t1 * s
            let shape = oval(a, r).union(Path(CGRect(x: min(a, b), y: -r, width: abs(b - a), height: 2 * r))).union(oval(b, r))
            g.fill(shape, with: frame.bodyFill)
            if Tuning.shading > 0 {
                // Light on top, darker below, so the barrel reads as round.
                let shade = Gradient(stops: [
                    .init(color: .white.opacity(Tuning.shading * 0.5), location: 0),
                    .init(color: .clear, location: 0.45),
                    .init(color: .black.opacity(Tuning.shading), location: 1),
                ])
                g.fill(shape, with: .linearGradient(shade, startPoint: CGPoint(x: 0, y: -r), endPoint: CGPoint(x: 0, y: r)))
            }
            // Edge lines: the top and bottom of the cylinder, and the outline of its back end.
            var edges = Path()
            edges.move(to: CGPoint(x: a, y: -r)); edges.addLine(to: CGPoint(x: b, y: -r))
            edges.move(to: CGPoint(x: a, y: r)); edges.addLine(to: CGPoint(x: b, y: r))
            edges.addPath(ellipseArc(center: CGPoint(x: a, y: 0), radiusX: r * abs(c), radiusY: r,
                                     from: .pi / 2, to: s < 0 ? -.pi / 2 : 1.5 * .pi))
            g.stroke(edges, with: line, style: lineStyle)
        }

        let offsets = [-Self.lensOffset, Self.lensOffset]
        let bandX = offsets.map { $0 * c - length * 0.5 * s }
        let bridgeHalf = min(Tuning.bridgeHeight, radius * 1.9) / 2
        let bridge = Path(CGRect(x: bandX.min() ?? 0, y: -bridgeHalf, width: abs(bandX[1] - bandX[0]), height: 2 * bridgeHalf))
        g.fill(bridge, with: frame.bodyFill)
        g.stroke(bridge, with: line, style: lineStyle)

        let lens = Self.lensRadius
        for xb in offsets.sorted(by: { -$0 * s < -$1 * s }) {
            // The eyepiece at the back, then the barrel, then the front rim with its outline.
            if Tuning.eyepieceLength > 0 {
                cylinder(xb, from: -length - Tuning.eyepieceLength, to: -length, radius: radius * Tuning.eyepieceSize)
            }
            cylinder(xb, from: -length, to: 0, radius: radius)
            let front = xb * c, rim = oval(front, radius)
            g.fill(rim, with: frame.bodyFill)
            g.fill(rim, with: .color(.white.opacity(0.12)))
            g.stroke(rim, with: line, style: lineStyle)

            let rx = lens * abs(c), ry = lens * frame.blink
            g.fill(Path(ellipseIn: CGRect(x: front - rx, y: -ry, width: 2 * rx, height: 2 * ry)),
                   with: .color(Self.glassColor.opacity(0.92)))
            // The pupil looks where Moppo looks.
            let px = front + frame.gaze.x * rx * 0.35, py = frame.gaze.y * ry * 0.35
            g.fill(Path(ellipseIn: CGRect(x: px - rx * Tuning.pupil, y: py - ry * Tuning.pupil,
                                          width: 2 * rx * Tuning.pupil, height: 2 * ry * Tuning.pupil)),
                   with: .color(.black.opacity(0.9)))
            g.stroke(ellipseArc(center: CGPoint(x: front, y: 0), radiusX: rx * 0.7, radiusY: ry * 0.7, from: .pi * 1.1, to: .pi * 1.42),
                     with: .color(.white.opacity(MascotTuning.glint)), style: StrokeStyle(lineWidth: lens * 0.11, lineCap: .round))
        }
        return true
    }

    /// The front view outline: two circles joined by a band, clockwise from the top of the band.
    private func makeOutline(_ geometry: MoppoMascotGeometry) -> [CGPoint] {
        let cx = geometry.centerX, cy = Tuning.centerY, r = Tuning.barrelRadius
        let half = min(Tuning.bridgeHeight, r * 1.9) / 2, inner = asin(min(0.99, half / r))
        var dense = [CGPoint(x: cx, y: cy - half)]
        func arc(_ x: Double, from: Double, to: Double) {
            for i in 0...240 {
                let a = from + (to - from) * Double(i) / 240
                dense.append(CGPoint(x: x + r * cos(a), y: cy + r * sin(a)))
            }
        }
        arc(cx + Self.lensOffset, from: -.pi + inner, to: .pi - inner)
        dense.append(CGPoint(x: cx, y: cy + half))
        arc(cx - Self.lensOffset, from: inner, to: 2 * .pi - inner)
        return geometry.outline(matching: MoppoMascotGeometry.filled(dense))
    }
}
