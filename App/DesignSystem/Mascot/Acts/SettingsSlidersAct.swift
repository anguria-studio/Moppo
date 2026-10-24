import SwiftUI

/// Moppo faces the viewer and springs into the settings icon: three tracks, each with a knob.
/// The eyes become the holes of two knobs, and the knobs slide to new spots now and then.
/// The act holds the shape until the screen releases it. Then the knobs slide back, the tracks close,
/// and Moppo springs back.
@MainActor
final class SettingsSlidersAct: MascotAct {
    private enum Tuning {
        static let morphTime = 0.4, stiffness = 200.0, damping = 0.75
        static let width = 560.0, track = 38.0, gap = 113.0, centerY = 260.0
        static let openTime = 0.35
        static let knobRadius = 54.0, knobRing = 22.0, knobClearance = 14.0
        static let knobEvery = 0.85, knobStiffness = 170.0, knobDamping = 0.5
        /// Where each knob starts, from -1 to 1 along its track.
        static let home = [-0.35, 0.35, 0.1]
        /// Eye 0 (left) becomes the middle knob, and eye 1 (right) becomes the top knob.
        static let eyeKnobs = [1, 0]
    }

    private enum Phase { case morph, open, hold, close, back, done }

    private var phase: MascotActPhase<Phase>
    private var morphSpring = Spring(value: 0), tracks = Spring(value: 0)
    private var knobs = Tuning.home.map { Spring(value: $0) }
    private var knobTargets = Tuning.home
    private var nextKnob = 0.0
    private var lastKnob: Int?
    private var isReleased = false
    private var outline: [CGPoint]?

    init(rig: MascotRig) {
        phase = MascotActPhase(.morph, at: rig.time, duration: Tuning.morphTime)
    }

    var isFinished: Bool { phase.current == .done }

    /// Lets Moppo turn back.
    func release() { isReleased = true }

    /// Keeps the shape. If Moppo already turns back, the tracks open again.
    func hold(at time: Double) {
        isReleased = false
        if phase.current == .close || phase.current == .back {
            phase.set(.open, at: time, duration: Tuning.openTime)
        }
    }

    private var amount: CGFloat { CGFloat(min(1.15, max(0, morphSpring.value))) }
    private var openness: CGFloat { CGFloat(clamp01(tracks.value)) }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time, current = phase.current
        morphSpring.step(toward: current == .back ? 0 : 1, stiffness: Tuning.stiffness, damping: Tuning.damping, dt: dt)
        tracks.step(toward: current == .open || current == .hold ? 1 : 0,
                    stiffness: 12 / (Tuning.openTime * Tuning.openTime), damping: 0.9, dt: dt)
        for i in knobs.indices {
            knobs[i].step(toward: knobTargets[i], stiffness: Tuning.knobStiffness, damping: Tuning.knobDamping, dt: dt)
        }
        if current == .hold, t >= nextKnob { moveKnob(at: t) }

        if current == .hold, isReleased {
            // The knobs slide back to their start spots first, so the eyes come back from the face.
            knobTargets = Tuning.home
            phase.set(.close, at: t, duration: max(Tuning.openTime, 0.45))
        } else if phase.isOver(at: t) {
            switch current {
            case .morph: phase.set(.open, at: t, duration: Tuning.openTime)
            case .open:
                nextKnob = t + 0.4
                phase.set(.hold, at: t, duration: .infinity)
            case .close: phase.set(.back, at: t, duration: Tuning.morphTime)
            case .back: phase.set(.done, at: t, duration: 0)
            case .hold, .done: break
            }
        }
        return MascotControls(gaze: (0, 0), facing: current == .back || current == .done ? nil : 0)
    }

    /// Slides one knob to a new spot, a good distance from where it is. The same knob does not move twice in a row.
    private func moveKnob(at t: Double) {
        let choices = knobs.indices.filter { $0 != lastKnob }
        guard let i = choices.randomElement() else { return }
        var target: Double
        repeat { target = .random(in: -1...1) } while abs(target - knobTargets[i]) < 0.5
        knobTargets[i] = target
        lastKnob = i
        nextKnob = t + .random(in: 0.7...1.3) * Tuning.knobEvery
    }

    // MARK: Layout

    private static var height: Double { 3 * Tuning.track + 2 * Tuning.gap }

    private static func trackCenterY(_ i: Int) -> Double {
        Tuning.centerY - height / 2 + Tuning.track / 2 + Double(i) * (Tuning.track + Tuning.gap)
    }

    private func knobCenter(_ i: Int, centerX: CGFloat) -> CGPoint {
        let travel = Tuning.width / 2 - Tuning.knobRadius - 14
        return CGPoint(x: centerX + knobs[i].value * travel, y: Self.trackCenterY(i))
    }

    /// The ring of a knob grows out of the eye as the tracks open.
    private func knobSizes(_ i: Int) -> (inner: CGFloat, outer: CGFloat, clearance: CGFloat) {
        let k = openness, eye = Tuning.knobRadius - Tuning.knobRing
        let inner = Tuning.eyeKnobs.contains(i) ? eye : eye * k
        let outer = inner + (Tuning.knobRadius - inner) * k
        return (inner, outer, outer + Tuning.knobClearance * k)
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    // MARK: Drawing

    func shape(_ frame: inout MascotFrame) {
        let m = amount
        guard m > 0.001 else { return }
        let outline = outline ?? makeOutline(frame.geometry)
        self.outline = outline
        frame.body = morph(frame.body, toward: { outline[$0] }, amount: m)
        // Each eye becomes the hole in one knob.
        let k = min(1, m), cx = frame.geometry.centerX
        for e in frame.eyes.indices {
            let knob = Tuning.eyeKnobs[e], center = knobCenter(knob, centerX: cx), radius = knobSizes(knob).inner
            let hole = roundEye(center: center, radiusX: radius, radiusY: radius, count: frame.eyes[e].count)
            frame.eyes[e] = morph(frame.eyes[e], toward: { hole[$0] }, amount: k)
            frame.eyeCenters[e] = MoppoMascotGeometry.mix(frame.eyeCenters[e], center, k)
        }
    }

    /// The gaps between the tracks, and room around each knob, so the knob stands apart from its track.
    func extraHoles(_ frame: MascotFrame) -> Path? {
        let k = openness
        guard amount > 0.001, k > 0.001 else { return nil }
        let cx = frame.geometry.centerX, left = cx - Tuning.width / 2, top = Tuning.centerY - Self.height / 2
        let trackHeight = Tuning.track + (1 - k) * Tuning.gap
        var tracks = Path()
        for i in 0..<3 {
            tracks.addRoundedRect(in: CGRect(x: left, y: Self.trackCenterY(i) - trackHeight / 2, width: Tuning.width, height: trackHeight),
                                  cornerSize: CGSize(width: Tuning.track / 2, height: Tuning.track / 2))
        }
        var holes = Path(CGRect(x: left - 80, y: top - 80, width: Tuning.width + 160, height: Self.height + 160))
            .subtracting(tracks)
        for i in 0..<3 { holes = holes.union(Self.circle(knobCenter(i, centerX: cx), knobSizes(i).clearance)) }
        return holes
    }

    /// The knobs: rings in Moppo's color around the holes.
    func drawInEyes(_ frame: MascotFrame, eyes: Path, in graphics: inout GraphicsContext) {
        guard amount > 0.001, openness > 0.001 else { return }
        for i in 0..<3 {
            let center = knobCenter(i, centerX: frame.geometry.centerX), size = knobSizes(i)
            graphics.fill(Self.circle(center, size.outer).subtracting(Self.circle(center, size.inner)), with: frame.bodyFill)
        }
    }

    /// A rounded block, clockwise from the top center, like Moppo's outline.
    private func makeOutline(_ geometry: MoppoMascotGeometry) -> [CGPoint] {
        let cx = geometry.centerX, r = Tuning.track / 2
        let left = cx - Tuning.width / 2, right = cx + Tuning.width / 2
        let top = Tuning.centerY - Self.height / 2, bottom = top + Self.height
        var corners: [CGPoint] = [CGPoint(x: cx, y: top)]
        func corner(_ x: Double, _ y: Double, from: Double) {
            for i in 0..<24 {
                let a = from + .pi / 2 * Double(i) / 24
                corners.append(CGPoint(x: x + r * cos(a), y: y + r * sin(a)))
            }
        }
        corner(right - r, top + r, from: -.pi / 2)
        corner(right - r, bottom - r, from: 0)
        corner(left + r, bottom - r, from: .pi / 2)
        corner(left + r, top + r, from: .pi)
        return geometry.outline(matching: MoppoMascotGeometry.filled(corners, step: 4))
    }
}
