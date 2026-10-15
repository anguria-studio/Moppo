import SwiftUI

/// Moppo faces the viewer and springs into a block. Gaps open and split the block into bars, and the eyes stretch
/// into two of the gaps. A laser line sweeps across the bars, beeps green, and Moppo springs back.
@MainActor
final class BarcodeAct: MascotAct {
    private enum Tuning {
        static let laserColor = (red: 0xFF / 255.0, green: 0x3B / 255.0, blue: 0x30 / 255.0)
        static let beepColor = (red: 0x34 / 255.0, green: 0xC7 / 255.0, blue: 0x59 / 255.0)
        static let morphTime = 0.5, stiffness = 140.0, damping = 0.6
        static let width = 520.0, height = 340.0, centerY = 250.0
        static let stripeTime = 0.35, sweeps = 4, scanTime = 0.9, beepTime = 0.6
        /// Bar and gap widths in modules, starting and ending with a bar.
        static let pattern = [2, 1, 1, 2, 3, 1, 1, 1, 2, 2, 1, 3, 1, 1, 2, 1, 3, 2, 1, 1, 1, 2, 2, 1, 1, 3, 2]
        static let digits = "4 006381 333931"
    }

    private enum Phase { case morph, stripes, scan, beep, unstripe, back, done }

    private struct Layout {
        let outline: [CGPoint]
        let top: CGFloat, bottom: CGFloat, centerX: CGFloat
        let gaps: [(x: CGFloat, width: CGFloat)]
        let eyeGaps: [Int]
    }

    private var phase: MascotActPhase<Phase>
    private var morphSpring = Spring(value: 0)
    private var stripes = Spring(value: 0), line = Spring(value: 0), beep = Spring(value: 0)
    private var scanY = 0.0, scanFrom = 0.0, scanTo = 0.0
    private var sweepIndex = 0
    private var layout: Layout?

    init(rig: MascotRig) {
        phase = MascotActPhase(.morph, at: rig.time, duration: Tuning.morphTime)
    }

    var isFinished: Bool { phase.current == .done }

    /// The morph can overshoot a little, which reads as a spring.
    private var amount: CGFloat { CGFloat(min(1.15, max(0, morphSpring.value))) }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time, current = phase.current
        let isScanning = current == .scan || current == .beep
        morphSpring.step(toward: current == .back ? 0 : 1, stiffness: Tuning.stiffness, damping: Tuning.damping, dt: dt)
        stripes.step(toward: current == .stripes || isScanning ? 1 : 0,
                     stiffness: 12 / (Tuning.stripeTime * Tuning.stripeTime), damping: 0.9, dt: dt)
        line.step(toward: isScanning ? 1 : 0, stiffness: 120, damping: 0.9, dt: dt)
        beep.step(toward: 0, stiffness: 60, damping: 0.7, dt: dt)
        if current == .scan {
            let p = min(1, (t - phase.start) / Tuning.scanTime)
            scanY = scanFrom + (scanTo - scanFrom) * MascotEasing.inOut(p)
        }

        if phase.isOver(at: t) {
            let top = Tuning.centerY - Tuning.height / 2 - 20, bottom = Tuning.centerY + Tuning.height / 2 + 20
            switch current {
            case .morph: phase.set(.stripes, at: t, duration: Tuning.stripeTime)
            case .stripes:
                (scanFrom, scanTo, scanY) = (top, bottom, top)
                phase.set(.scan, at: t, duration: Tuning.scanTime)
            case .scan:
                sweepIndex += 1
                if sweepIndex < Tuning.sweeps {
                    (scanFrom, scanTo) = (scanTo, scanFrom)
                    phase.set(.scan, at: t, duration: Tuning.scanTime)
                } else {
                    beep.velocity += 25
                    phase.set(.beep, at: t, duration: Tuning.beepTime)
                }
            case .beep: phase.set(.unstripe, at: t, duration: Tuning.stripeTime)
            case .unstripe: phase.set(.back, at: t, duration: 0.6)
            case .back, .done: phase.set(.done, at: t, duration: 0)
            }
        }
        // Moppo faces the viewer for the whole act, and turns back to its side at the end.
        return MascotControls(gaze: (0, 0), facing: current == .back || current == .done ? nil : 0)
    }

    func shape(_ frame: inout MascotFrame) {
        let m = amount
        guard m > 0.001 else { return }
        let layout = layout ?? makeLayout(frame.geometry)
        self.layout = layout
        frame.body = morph(frame.body, toward: { layout.outline[$0] }, amount: m)
        // Each eye stretches into one gap of the barcode, from the top of the bars to the bottom.
        let halfHeight = (layout.bottom - layout.top) / 2 + 30, centerY = (layout.top + layout.bottom) / 2
        for e in frame.eyes.indices {
            let gap = layout.gaps[layout.eyeGaps[e]], count = frame.eyes[e].count
            frame.eyes[e] = morph(frame.eyes[e], toward: { j in
                Self.rectanglePoint(center: CGPoint(x: gap.x, y: centerY), halfWidth: gap.width / 2, halfHeight: halfHeight,
                                    angle: -.pi / 2 + 2 * .pi * Double(j) / Double(count))
            }, amount: min(1, m))
            frame.eyeCenters[e] = MoppoMascotGeometry.mix(frame.eyeCenters[e], CGPoint(x: gap.x, y: centerY), min(1, m))
        }
    }

    /// The other gaps open and split the block into bars.
    func extraHoles(_ frame: MascotFrame) -> Path? {
        let k = CGFloat(clamp01(stripes.value))
        guard let layout, amount > 0.001, k > 0.001 else { return nil }
        var path = Path()
        for (i, gap) in layout.gaps.enumerated() where !layout.eyeGaps.contains(i) {
            path.addRect(CGRect(x: gap.x - gap.width * k / 2, y: layout.top - 40,
                                width: gap.width * k, height: layout.bottom - layout.top + 80))
        }
        return path
    }

    func drawFront(_ frame: MascotFrame, in graphics: inout GraphicsContext) {
        guard let layout else { return }
        let shown = clamp01(stripes.value)
        if shown > 0.01 {
            // Digits under the bars, like on a real label.
            var text = graphics
            text.opacity = shown
            let digits = frame.bodyColored(Text(Tuning.digits)
                .font(.system(size: Tuning.height * 0.16, weight: .semibold, design: .monospaced)))
            text.draw(digits, at: CGPoint(x: layout.centerX, y: layout.bottom + 18), anchor: .top)
        }
        drawLaser(layout, in: &graphics)
    }

    /// The laser line across the barcode, with a glow and a thin bright core. It turns green for the beep.
    private func drawLaser(_ layout: Layout, in graphics: inout GraphicsContext) {
        let a = clamp01(line.value)
        guard a > 0.01 else { return }
        let k = clamp01(beep.value), from = Tuning.laserColor, to = Tuning.beepColor
        let color = Color(red: from.red + (to.red - from.red) * k, green: from.green + (to.green - from.green) * k,
                          blue: from.blue + (to.blue - from.blue) * k)
        let half = Tuning.width / 2 + 70, y = scanY, cx = layout.centerX
        func beam(_ reach: Double) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: cx - reach, y: y))
            path.addLine(to: CGPoint(x: cx + reach, y: y))
            return path
        }
        for (width, alpha) in [(34.0, 0.18), (14.0, 0.45), (6.0, 0.95)] {
            graphics.stroke(beam(half), with: .color(color.opacity(alpha * a)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
        graphics.stroke(beam(half * 0.92), with: .color(.white.opacity(0.7 * a)), lineWidth: 2)
    }

    private func makeLayout(_ geometry: MoppoMascotGeometry) -> Layout {
        let cx = geometry.centerX, w = Tuning.width / 2, h = Tuning.height / 2, cy = Tuning.centerY
        let x0 = cx - w, x1 = cx + w, y0 = cy - h, y1 = cy + h
        var dense: [CGPoint] = []
        func edge(_ a: CGPoint, _ b: CGPoint, _ count: Int) {
            for i in 0..<count { dense.append(MoppoMascotGeometry.mix(a, b, CGFloat(i) / CGFloat(count))) }
        }
        // Clockwise from the top center, like Moppo's outline.
        edge(CGPoint(x: cx, y: y0), CGPoint(x: x1, y: y0), 60)
        edge(CGPoint(x: x1, y: y0), CGPoint(x: x1, y: y1), 80)
        edge(CGPoint(x: x1, y: y1), CGPoint(x: x0, y: y1), 120)
        edge(CGPoint(x: x0, y: y1), CGPoint(x: x0, y: y0), 80)
        edge(CGPoint(x: x0, y: y0), CGPoint(x: cx, y: y0), 60)
        let unit = (x1 - x0) / CGFloat(Tuning.pattern.reduce(0, +))
        var gaps: [(x: CGFloat, width: CGFloat)] = []
        var x = x0
        for (i, modules) in Tuning.pattern.enumerated() {
            if i % 2 == 1 { gaps.append((x + CGFloat(modules) * unit / 2, CGFloat(modules) * unit)) }
            x += CGFloat(modules) * unit
        }
        // The eyes become the gaps nearest to where they are on Moppo's face.
        func nearest(_ share: CGFloat) -> Int {
            let target = x0 + share * (x1 - x0)
            return gaps.indices.min { abs(gaps[$0].x - target) < abs(gaps[$1].x - target) } ?? 0
        }
        return Layout(outline: geometry.outline(matching: dense), top: y0, bottom: y1, centerX: cx,
                      gaps: gaps, eyeGaps: [nearest(0.4), nearest(0.6)])
    }

    /// A point on a rectangle's outline for an angle, so a round eye can flow into a gap.
    private static func rectanglePoint(center: CGPoint, halfWidth: CGFloat, halfHeight: CGFloat, angle: Double) -> CGPoint {
        let c = cos(angle), s = sin(angle), k = 1 / max(abs(c), abs(s))
        return CGPoint(x: center.x + c * k * halfWidth, y: center.y + s * k * halfHeight)
    }
}
