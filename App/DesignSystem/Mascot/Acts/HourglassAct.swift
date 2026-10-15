import SwiftUI

/// Moppo quickly springs into an hourglass. The eyes flow into the two glass bulbs.
/// Sand already runs while the morph lands, so it reads as an hourglass even if the operation ends at once.
/// When the upper bulb is empty, the hourglass flips and runs again, until the operation ends.
/// The hourglass mode plays this act in place of the static hourglass symbol.
@MainActor
final class HourglassAct: MascotAct {
    private enum Tuning {
        static let sand = Color(red: 0xF2 / 255, green: 0xB3 / 255, blue: 0)
        static let stiffness = 260.0, damping = 0.55
        static let bulbHalfWidth = 190.0, halfHeight = 260.0, neck = 16.0
        static let capHalfWidth = 250.0, capThickness = 30.0, glass = 18.0, centerY = 260.0
        static let runTime = 1.6, flipStiffness = 160.0, flipDamping = 0.5, flipTime = 0.5
    }

    private enum Phase { case run, flip }

    private struct Layout {
        let outline: [CGPoint]
        let bulbs: [[CGPoint]]
        let center: CGPoint
        let innerTop: CGFloat
    }

    private var phase: MascotActPhase<Phase>
    private var morphSpring = Spring(value: 0)
    private var angle = Spring(value: 0)
    /// The share of the sand in the upper bulb.
    private var sand = 0.95
    private var restAngle = 0.0
    private var layout: Layout?

    init(rig: MascotRig) {
        phase = MascotActPhase(.run, at: rig.time, duration: Tuning.runTime)
    }

    var isFinished: Bool { false }

    private var amount: CGFloat { CGFloat(min(1.15, max(0, morphSpring.value))) }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time
        morphSpring.step(toward: 1, stiffness: Tuning.stiffness, damping: Tuning.damping, dt: dt)
        angle.step(toward: restAngle, stiffness: Tuning.flipStiffness, damping: Tuning.flipDamping, dt: dt)
        if phase.current == .run { sand = max(0, sand - dt / Tuning.runTime) }
        if phase.isOver(at: t) {
            switch phase.current {
            case .run:
                restAngle += 180
                phase.set(.flip, at: t, duration: Tuning.flipTime)
            case .flip:
                sand = 1 - sand
                phase.set(.run, at: t, duration: Tuning.runTime)
            }
        }
        return MascotControls(gaze: (0, 0), facing: 0)
    }

    /// Turns a point with the flip of the glass.
    private func flipped(_ p: CGPoint, around c: CGPoint) -> CGPoint {
        let a = angle.value * .pi / 180, dx = p.x - c.x, dy = p.y - c.y
        return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
    }

    func shape(_ frame: inout MascotFrame) {
        let m = amount
        guard m > 0.001 else { return }
        let layout = layout ?? makeLayout(frame.geometry)
        self.layout = layout
        let c = layout.center
        frame.body = morph(frame.body, toward: { self.flipped(layout.outline[$0], around: c) }, amount: m)
        // Each eye flows into one glass bulb.
        let k = min(1, m)
        for e in frame.eyes.indices {
            let bulb = layout.bulbs[e]
            frame.eyes[e] = morph(frame.eyes[e], toward: { self.flipped(bulb[$0 % bulb.count], around: c) }, amount: k)
            let target = flipped(CGPoint(x: c.x, y: c.y + (e == 0 ? -1 : 1) * Tuning.halfHeight * 0.4), around: c)
            frame.eyeCenters[e] = MoppoMascotGeometry.mix(frame.eyeCenters[e], target, k)
        }
    }

    func drawInEyes(_ frame: MascotFrame, eyes: Path, in graphics: inout GraphicsContext) {
        let m = Double(amount)
        guard let layout, m > 0.01 else { return }
        // A light glass tint, then the sand once the bulbs have formed.
        graphics.fill(eyes, with: .color(Color(red: 190 / 255, green: 225 / 255, blue: 1).opacity(MascotTuning.glassTint * min(1, m))))
        guard m > 0.6 else { return }
        var context = graphics
        context.opacity = min(1, (m - 0.6) / 0.3)
        context.clip(to: eyes)
        drawSand(layout, time: frame.time, in: &context)
    }

    /// The sand turns with the glass during a flip. While it runs, the upper pile drains with a small dip
    /// in the middle, a thin stream falls through the neck, and the lower pile grows into a cone.
    private func drawSand(_ layout: Layout, time: Double, in graphics: inout GraphicsContext) {
        let isFlipping = phase.current == .flip
        let turn = angle.value - (isFlipping ? restAngle - 180 : restAngle)
        let upper = sand, lower = 1 - sand
        let bulbHeight = layout.center.y - layout.innerTop, w = Tuning.bulbHalfWidth
        var g = graphics
        g.translateBy(x: layout.center.x, y: layout.center.y)
        g.rotate(by: .degrees(turn))
        let fill = GraphicsContext.Shading.color(Tuning.sand)
        if upper > 0.005 {
            let level = -bulbHeight * upper * 0.92, dip = isFlipping ? 0 : min(28, bulbHeight * upper * 0.25)
            var pile = Path()
            pile.addLines([CGPoint(x: -w, y: level), CGPoint(x: 0, y: level + dip), CGPoint(x: w, y: level),
                           CGPoint(x: w, y: 0), CGPoint(x: -w, y: 0)])
            pile.closeSubpath()
            g.fill(pile, with: fill)
        }
        if lower > 0.005 {
            let height = bulbHeight * lower * 0.85, peak = min(60, height * 0.5)
            var pile = Path()
            pile.addLines([CGPoint(x: -w, y: bulbHeight), CGPoint(x: -w, y: bulbHeight - height + peak),
                           CGPoint(x: 0, y: bulbHeight - height), CGPoint(x: w, y: bulbHeight - height + peak),
                           CGPoint(x: w, y: bulbHeight)])
            pile.closeSubpath()
            g.fill(pile, with: fill)
        }
        if !isFlipping, upper > 0.01 {
            // The stream through the neck, with a small flicker.
            let width = 5 + sin(time * 40) * 1.2
            g.fill(Path(CGRect(x: -width / 2, y: -2, width: width, height: bulbHeight * (1 - lower * 0.85) + 2)), with: fill)
        }
    }

    private func makeLayout(_ geometry: MoppoMascotGeometry) -> Layout {
        let cx = geometry.centerX, cy = Tuning.centerY, h = Tuning.halfHeight
        let top = cy - h, bottom = cy + h, innerTop = top + Tuning.capThickness, innerBottom = bottom - Tuning.capThickness
        // The inner half width of a bulb: widest near the cap, narrowing to the neck.
        func inner(_ y: Double) -> Double {
            let u = min(1, abs(y - cy) / (cy - innerTop))
            return Tuning.neck + (Tuning.bulbHalfWidth - Tuning.neck) * pow(sin(u * .pi / 2), 0.7)
        }
        func side(from: Double, to: Double, sign: Double, extra: Double) -> [CGPoint] {
            (0...60).map { i in
                let y = from + (to - from) * Double(i) / 60
                return CGPoint(x: cx + sign * (inner(y) + extra), y: y)
            }
        }
        // The frame: caps on top and bottom, and the outer side of the glass. Clockwise from the top center.
        let cap = Tuning.capHalfWidth
        var corners = [CGPoint(x: cx, y: top), CGPoint(x: cx + cap, y: top), CGPoint(x: cx + cap, y: innerTop)]
        corners += side(from: innerTop, to: innerBottom, sign: 1, extra: Tuning.glass)
        corners += [CGPoint(x: cx + cap, y: innerBottom), CGPoint(x: cx + cap, y: bottom),
                    CGPoint(x: cx - cap, y: bottom), CGPoint(x: cx - cap, y: innerBottom)]
        corners += side(from: innerBottom, to: innerTop, sign: -1, extra: Tuning.glass)
        corners += [CGPoint(x: cx - cap, y: innerTop), CGPoint(x: cx - cap, y: top)]
        // The two bulbs, clockwise from the top center of each. The eyes flow into them.
        func bulb(_ y0: Double, _ y1: Double) -> [CGPoint] {
            MoppoMascotGeometry.resampled([CGPoint(x: cx, y: y0)] + side(from: y0, to: y1, sign: 1, extra: 0)
                + side(from: y1, to: y0, sign: -1, extra: 0), count: 72)
        }
        return Layout(outline: geometry.outline(matching: MoppoMascotGeometry.filled(corners)),
                      bulbs: [bulb(innerTop, cy), bulb(cy, innerBottom)], center: CGPoint(x: cx, y: cy), innerTop: innerTop)
    }
}
