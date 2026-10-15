import SwiftUI

/// Moppo looks down, drops into a hole, peeks out of a second hole at the side, ducks, and pops back up.
/// Below the hole level Moppo is hidden, so it seems to pass through the floor.
@MainActor
final class PeekAct: MascotAct {
    private enum Tuning {
        static let look = 0.4
        static let holeY = 790.0, holeHalfWidth = 330.0, holeFlatness = 0.05, holeTime = 0.3
        static let dropStiffness = 225.0
        static let sideDistance = 795.0, peekHeight = 180.0, peekTime = 1.8
        static let popStiffness = 325.0, popDamping = 0.4
        static let stretch = 0.05
    }

    private enum Phase { case look, open, sink, swap, peek, duck, back, pop, close, done }

    private var phase: MascotActPhase<Phase>
    private let side: Double
    private var offsetX = 0.0
    private var offsetY = Spring(value: 0), squash = Spring(value: 0)
    private var holeHere = Spring(value: 0), holeThere = Spring(value: 0)

    init(rig: MascotRig) {
        phase = MascotActPhase(.look, at: rig.time, duration: Tuning.look)
        side = Bool.random() ? -1 : 1
    }

    var isFinished: Bool { phase.current == .done }

    var hiddenBelow: CGFloat? {
        phase.current == .look || phase.current == .open || phase.current == .done ? nil : Tuning.holeY
    }

    func update(_ dt: Double, rig: MascotRig) -> MascotControls {
        let t = rig.time, current = phase.current
        // The top of Moppo is at Y -10. Sinking moves it below the hole, and peeking shows only the top part.
        let sunk = Tuning.holeY + 10 + 30, peeking = Tuning.holeY + 10 - Tuning.peekHeight
        let target: Double = switch current {
        case .look, .open, .pop, .close, .done: 0
        case .peek: peeking
        case .sink, .swap, .duck, .back: sunk
        }
        let isPopping = current == .pop || current == .close || current == .peek
        offsetY.step(toward: target, stiffness: isPopping ? Tuning.popStiffness : Tuning.dropStiffness,
                     damping: isPopping ? Tuning.popDamping : 1, dt: dt)
        let holeStiffness = 16 / (Tuning.holeTime * Tuning.holeTime)
        holeHere.step(toward: [.open, .sink, .back, .pop].contains(current) ? 1 : 0, stiffness: holeStiffness, damping: 0.9, dt: dt)
        holeThere.step(toward: [.swap, .peek, .duck].contains(current) ? 1 : 0, stiffness: holeStiffness, damping: 0.9, dt: dt)
        // Stretch while moving fast up or down.
        squash.step(toward: -min(1, abs(offsetY.velocity) / 2500) * Tuning.stretch, stiffness: 300, damping: 0.6, dt: dt)

        var gaze: (x: Double, y: Double)?
        switch current {
        case .look, .open: gaze = (0, 0.9)
        case .peek:
            let p = (t - phase.start) / Tuning.peekTime
            gaze = p < 0.15 ? (0, 0.2) : p < 0.45 ? (-0.9, -0.1) : p < 0.75 ? (0.9, -0.1) : (-side * 0.8, 0.3)
            if p > 0.45, p < 0.47 { rig.startBlink() }
        case .pop, .close: gaze = (0, 0)
        default: gaze = nil
        }

        if phase.isOver(at: t) {
            switch current {
            case .look: phase.set(.open, at: t, duration: Tuning.holeTime)
            case .open: phase.set(.sink, at: t, duration: 0.45)
            case .sink:
                offsetX = side * Tuning.sideDistance
                phase.set(.swap, at: t, duration: Tuning.holeTime + 0.1)
            case .swap: phase.set(.peek, at: t, duration: Tuning.peekTime)
            case .peek: phase.set(.duck, at: t, duration: 0.35)
            case .duck:
                offsetX = 0
                phase.set(.back, at: t, duration: Tuning.holeTime + 0.1)
            case .back: phase.set(.pop, at: t, duration: 0.55)
            case .pop: phase.set(.close, at: t, duration: Tuning.holeTime + 0.2)
            case .close, .done: phase.set(.done, at: t, duration: 0)
            }
        }
        return MascotControls(gaze: gaze, squash: squash.value, offset: CGPoint(x: offsetX, y: offsetY.value))
    }

    func drawBehind(_ frame: MascotFrame, in graphics: inout GraphicsContext) {
        // The hole under Moppo is centered on its outline at rest.
        let restX = MoppoMascotGeometry.center(of: frame.body).x - frame.offset.x
        let holes = [(restX, holeHere.value), (restX + side * Tuning.sideDistance, holeThere.value)]
        for (x, open) in holes {
            let o = clamp01(open)
            guard o > 0.01 else { continue }
            let radius = Tuning.holeHalfWidth * o
            let gradient = Gradient(stops: [
                .init(color: .black.opacity(0.92), location: 0),
                .init(color: .black.opacity(0.8), location: 0.75),
                .init(color: .black.opacity(0.25), location: 1),
            ])
            var hole = graphics
            hole.translateBy(x: x, y: Tuning.holeY)
            hole.scaleBy(x: radius, y: radius * Tuning.holeFlatness)
            hole.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                      with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: 1))
        }
    }
}
