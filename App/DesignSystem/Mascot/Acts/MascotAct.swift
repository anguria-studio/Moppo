import SwiftUI

/// The acts that Moppo can play during a scan. The hourglass is not in this list, because it is a mode.
enum MascotActKind: CaseIterable, Sendable {
    case sauronEye, magnifyingLens, radarPing, peek, barcode, binoculars, yawn, duplicatesSplit

    @MainActor
    func makeAct(rig: MascotRig) -> any MascotAct {
        switch self {
        case .sauronEye: SauronEyeAct(rig: rig)
        case .magnifyingLens: MagnifyingLensAct(rig: rig)
        case .radarPing: RadarPingAct(rig: rig)
        case .peek: PeekAct(rig: rig)
        case .barcode: BarcodeAct(rig: rig)
        case .binoculars: BinocularsAct(rig: rig)
        case .yawn: YawnAct(rig: rig)
        case .duplicatesSplit: DuplicatesSplitAct(rig: rig)
        }
    }
}

/// The parts of Moppo's motion that an act can read and use.
@MainActor
protocol MascotRig: AnyObject {
    /// Motion time in seconds. It runs a little slower than the clock.
    var time: Double { get }
    /// 1 when Moppo faces right and -1 when it faces left.
    var facing: Double { get }
    /// The current turn: 1 for right, 0 for front, and -1 for left.
    var turn: Double { get }
    func startBlink()
    func turnAround()
    /// Picks new gazes and blinks on Moppo's own schedule.
    func lookAround()
    /// Adds a push to the head and to the squash.
    func kick(headY: Double, squash: Double)
}

/// What an act sets for one step. A value of nil keeps Moppo's own behavior.
struct MascotControls {
    var gaze: (x: Double, y: Double)?
    /// The side that Moppo turns toward.
    var facing: Double?
    var head: (x: Double, y: Double, angle: Double)?
    /// Positive values flatten Moppo, and negative values stretch it.
    var squash = 0.0
    /// Moves all of Moppo.
    var offset = CGPoint.zero
    /// How open the eyes are, on top of the blinks.
    var lids = 1.0
    /// Lights the eyes in the beam color.
    var eyeGlow = 0.0
}

/// Moppo's outline and eyes for one frame, after the pose, the turn, and the bend.
/// An act can change the outline and the eyes, and draw from these values.
struct MascotFrame {
    let geometry: MoppoMascotGeometry
    let time: Double
    let turn: Double
    let pivot: CGPoint
    var body: [CGPoint]
    var eyes: [[CGPoint]]
    var eyeCenters: [CGPoint]
    /// The blink and the lids together.
    let openness: Double
    /// The blink alone.
    let blink: Double
    /// The eye springs, from -1 to 1.
    let gaze: CGPoint
    let head: CGPoint
    let headAngle: Double
    let offset: CGPoint
    let bodyFill: GraphicsContext.Shading
    let isLight: Bool

    /// The color for text in Moppo's body color.
    func bodyColored(_ text: Text) -> Text {
        isLight ? text.foregroundStyle(MascotFrame.lightBody) : text
    }

    static let lightBody = Color(white: 0x2B / 255)
}

/// One copy of Moppo, for an act that draws Moppo more than once.
struct MascotCopy {
    let turn: Double
    let offsetX: CGFloat
    /// Makes the eyes look in this direction, from -1 to 1.
    let eyeX: Double?
}

/// A short scene that Moppo plays. The motion asks the act for controls each step and calls the drawing hooks.
/// The drawing order is: behind Moppo, the body, the eye holes, the eye fills, and the front.
@MainActor
protocol MascotAct: AnyObject {
    var isFinished: Bool { get }
    func update(_ dt: Double, rig: MascotRig) -> MascotControls
    /// Changes the outline and the eyes, for an act that turns Moppo into another shape.
    func shape(_ frame: inout MascotFrame)
    func drawBehind(_ frame: MascotFrame, in graphics: inout GraphicsContext)
    /// Draws on the body, before the eye holes are cut.
    func drawOnBody(_ frame: MascotFrame, body: Path, in graphics: inout GraphicsContext)
    /// More holes to cut with the eyes.
    func extraHoles(_ frame: MascotFrame) -> Path?
    /// Draws in the eye holes, after they are cut.
    func drawInEyes(_ frame: MascotFrame, eyes: Path, in graphics: inout GraphicsContext)
    func drawFront(_ frame: MascotFrame, in graphics: inout GraphicsContext)
    /// Hides Moppo below this level. The beams are not hidden.
    var hiddenBelow: CGFloat? { get }
    /// Draws something else in place of Moppo. Returns false to draw Moppo.
    func drawInstead(_ frame: MascotFrame, in graphics: inout GraphicsContext) -> Bool
    /// The copies of Moppo to draw, or nil for one Moppo.
    var copies: [MascotCopy]? { get }
}

extension MascotAct {
    func shape(_ frame: inout MascotFrame) {}
    func drawBehind(_ frame: MascotFrame, in graphics: inout GraphicsContext) {}
    func drawOnBody(_ frame: MascotFrame, body: Path, in graphics: inout GraphicsContext) {}
    func extraHoles(_ frame: MascotFrame) -> Path? { nil }
    func drawInEyes(_ frame: MascotFrame, eyes: Path, in graphics: inout GraphicsContext) {}
    func drawFront(_ frame: MascotFrame, in graphics: inout GraphicsContext) {}
    var hiddenBelow: CGFloat? { nil }
    func drawInstead(_ frame: MascotFrame, in graphics: inout GraphicsContext) -> Bool { false }
    var copies: [MascotCopy]? { nil }
}

/// The current phase of an act and when it ends.
struct MascotActPhase<Phase: Equatable> {
    private(set) var current: Phase
    private(set) var start: Double
    var end: Double

    init(_ phase: Phase, at time: Double, duration: Double) {
        current = phase
        start = time
        end = time + duration
    }

    mutating func set(_ phase: Phase, at time: Double, duration: Double) {
        self = MascotActPhase(phase, at: time, duration: duration)
    }

    func isOver(at time: Double) -> Bool { time >= end }

    func progress(at time: Double) -> Double {
        min(1, (time - start) / max(0.05, end - start))
    }
}

/// Moves each point of a shape toward a target shape. `amount` 0 keeps the shape, and 1 gives the target.
func morph(_ points: [CGPoint], toward target: (Int) -> CGPoint, amount: CGFloat) -> [CGPoint] {
    points.indices.map { MoppoMascotGeometry.mix(points[$0], target($0), amount) }
}

/// A round eye of `count` points, clockwise from the top.
func roundEye(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, count: Int) -> [CGPoint] {
    (0..<count).map {
        let a = -CGFloat.pi / 2 + 2 * .pi * CGFloat($0) / CGFloat(count)
        return CGPoint(x: center.x + radiusX * cos(a), y: center.y + radiusY * sin(a))
    }
}

/// An arc of an ellipse, from angle `from` to angle `to`.
func ellipseArc(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, from: Double, to: Double) -> Path {
    var path = Path()
    let steps = 32
    for i in 0...steps {
        let a = from + (to - from) * Double(i) / Double(steps)
        let point = CGPoint(x: center.x + radiusX * cos(a), y: center.y + radiusY * sin(a))
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

func clamp01(_ value: Double) -> Double { min(1, max(0, value)) }
