import SwiftUI

/// Shows Moppo at work. Moppo looks around, blinks, and turns between its left and right sides.
/// In the beam modes, Moppo also shoots rays from its eyes. The rays can extend past the frame of the view.
struct MoppoMascotView: View {
    enum Mode {
        /// Looks around without rays.
        case search
        /// Looks around and fires short sweeps of rays.
        case scanning
        /// Fires rays less often, for long scans such as the photo duplicate scan.
        case photoScanning
        /// Sweeps red rays in a half circle below itself while it turns from one side to the other.
        case destroying

        /// How long the first pass of a deletion takes, from the first frame to the end of the sweep.
        /// Deletions stay on screen at least this long, so the rays do not stop halfway.
        var firstPassDuration: Duration? {
            guard self == .destroying else { return nil }
            let seconds = (MascotTuning.openingCharge + MascotTuning.fireTime + MascotTuning.destroySweepTime)
                / MascotTuning.speed
            return .milliseconds(Int(seconds * 1000))
        }
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var motion: MoppoMascotMotion

    init(mode: Mode = .search) {
        _motion = State(initialValue: MoppoMascotMotion(mode: mode))
    }

    var body: some View {
        if !reduceMotion, let geometry = MoppoMascotGeometry.shared {
            GeometryReader { proxy in
                let overflow = MascotTuning.beamOverflow
                TimelineView(.animation) { context in
                    Canvas { graphics, size in
                        motion.advance(to: context.date)
                        motion.draw(geometry, in: &graphics, size: size, fit: 1 / overflow)
                    }
                }
                // Draw in a larger area than the layout frame, so the beams are not cut at the frame edge.
                .frame(width: proxy.size.width * overflow, height: proxy.size.height * overflow)
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
        } else {
            PageStateSymbol(name: "hourglass")
        }
    }
}

/// Tuned in the Moppo motion prototype. Lengths use the glyph coordinates of the logo path.
private enum MascotTuning {
    static let speed = 0.8
    // Look
    static let gazeX = 21.0, gazeY = 31.0
    static let holdMin = 0.7, holdMax = 1.4
    static let microSaccade = 0.11
    static let eyeSquash = 0.05
    static let eyeStiffness = 210.0
    // Blink
    static let blinkEvery = 2.2
    static let blinkOnMove = 0.25, blinkOnTurn = 0.55
    static let blinkDuration = 0.17
    // Body
    static let headShift = 60.0, tilt = 7.0
    static let headStiffness = 145.0, headDamping = 0.62
    // Mop tails
    static let tailStiffness = 200.0, tailDamping = 0.1
    static let drag = 0.25
    static let sway = 0.75, swayHz = 0.25, waveLength = 195.0, strandPhase = 0.8
    // Turning around
    static let turnMin = 3.5, turnMax = 7.0
    static let turnStiffness = 280.0, turnDamping = 0.85
    static let turnTailStiffness = 180.0, turnTailDamping = 0.7
    static let turnDrag = 0.8
    static let eyeLead = 0.14
    // Fraction of empty space around the glyph, so the tails stay inside the frame when they swing.
    static let padding = 1.2
    // Beams while scanning
    static let beamColor = Token.dynamic(
        light: NSColor(srgbRed: 1, green: 0xD0 / 255, blue: 0, alpha: 1),
        dark: NSColor(srgbRed: 0xF2 / 255, green: 0xB3 / 255, blue: 0, alpha: 1)
    )
    static let beamLength = 1500.0, beamStartWidth = 30.0, beamSpread = 0.2, beamOpacity = 1.0
    static let chargeTime = 0.3, fireTime = 0.21, sweepTime = 1.0, offTime = 0.25, restTime = 2.3
    static let sweepRange = 55.0, maxUp = 40.0, maxDown = 45.0
    static let recoil = 350.0, offSquash = 0.13
    static let turnBetweenShots = 0.4, turnWhileShooting = 0.4
    static let shotBlinkEvery = 1.1
    static let flashSize = 460.0, flashWindow = 0.85
    // Floor. The beams stop at an invisible floor below Moppo, so they do not cross the text under it.
    // A beam that reaches the floor lights an oval there. The floor is seen from above, so the oval is flat.
    static let floorY = 930.0, floorFlatness = 0.1
    static let poolGlowSize = 1.45, poolBrightness = 0.75, poolCore = 0.5
    // Rays during a large deletion
    static let destroyColor = Color(red: 0xFF / 255, green: 0x3B / 255, blue: 0x30 / 255)
    static let destroyLength = 1230.0, destroyStartWidth = 34.0
    static let destroyStartBelow = 12.0
    static let destroySweepTime = 2.6, destroyRest = 0.2
    static let destroyAlternates = true
    // Glyph units. At the 88 pt size, 30 units is about 3 pt.
    static let destroyShake = 30.0
    // Photo scan: a long rest between shots
    static let photoRest = 8.0
    // A deletion opens with the eyes already lit, so the rays fire almost at once.
    static let openingCharge = 0.12
    // The canvas is this many times the layout frame, so the beams have room.
    static let beamOverflow = 4.0
}

/// Matching outlines of Moppo facing right, front, and left. Point `i` is the same spot on the body in each pose.
struct MoppoMascotGeometry: Decodable {
    struct Pose: Decodable {
        let body: [CGPoint]
        let eyes: [[CGPoint]]
        let pivot: CGPoint

        private enum CodingKeys: String, CodingKey { case body, eyes, pivot }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            body = Self.points(try container.decode([CGFloat].self, forKey: .body))
            eyes = try container.decode([[CGFloat]].self, forKey: .eyes).map(Self.points)
            let pivot = try container.decode([CGFloat].self, forKey: .pivot)
            self.pivot = CGPoint(x: pivot[0], y: pivot[1])
        }

        private static func points(_ values: [CGFloat]) -> [CGPoint] {
            stride(from: 0, to: values.count - 1, by: 2).map { CGPoint(x: values[$0], y: values[$0 + 1]) }
        }
    }

    let right: Pose
    let front: Pose
    let left: Pose
    /// 0 on the head and 1 at the tail tips.
    let tailWeights: [CGFloat]
    let bounds: CGRect

    private enum CodingKeys: String, CodingKey { case right, front, left, tailWeights, bounds }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        right = try container.decode(Pose.self, forKey: .right)
        front = try container.decode(Pose.self, forKey: .front)
        left = try container.decode(Pose.self, forKey: .left)
        tailWeights = try container.decode([CGFloat].self, forKey: .tailWeights)
        let b = try container.decode([CGFloat].self, forKey: .bounds)
        bounds = CGRect(x: b[0], y: b[1], width: b[2], height: b[3])
    }

    var isConsistent: Bool {
        let poses = [right, front, left]
        return poses.allSatisfy { $0.body.count == tailWeights.count && $0.eyes.count == 2 }
            && poses.allSatisfy { $0.eyes[0].count == right.eyes[0].count && $0.eyes[1].count == right.eyes[1].count }
    }

    static let shared: MoppoMascotGeometry? = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "MoppoMascot", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let geometry = try? JSONDecoder().decode(MoppoMascotGeometry.self, from: data),
              geometry.isConsistent
        else { return nil }
        return geometry
    }()

    /// Blends the three poses. `turn` is 1 for right, 0 for front, and -1 for left.
    static func blend(_ right: CGPoint, _ front: CGPoint, _ left: CGPoint, turn: CGFloat) -> CGPoint {
        let (target, amount) = turn >= 0 ? (right, turn) : (left, -turn)
        return CGPoint(x: front.x + (target.x - front.x) * amount, y: front.y + (target.y - front.y) * amount)
    }
}

private final class BundleToken {}

private struct Spring {
    var value: Double
    var velocity = 0.0

    mutating func step(toward target: Double, stiffness: Double, damping: Double, dt: Double) {
        let acceleration = stiffness * (target - value) - 2 * damping * stiffness.squareRoot() * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }
}

/// Runs the search behavior. The view keeps one instance and advances it once for each frame.
@MainActor
final class MoppoMascotMotion {
    private typealias T = MascotTuning

    private enum BeamPhase { case rest, turning, aim, charge, fire, sweep, off }

    let mode: MoppoMascotView.Mode

    init(mode: MoppoMascotView.Mode = .search) {
        self.mode = mode
        // A deletion starts on the left side with the eyes lit, so the first pass begins at once.
        if mode == .destroying {
            facing = -1
            turn = Spring(value: -1)
            turnTail = Spring(value: -1)
            rayAngle = 180 - T.destroyStartBelow
            eyeGlow = Spring(value: 1)
            phase = .charge
            phaseEnd = T.openingCharge
        }
    }

    private static let gazeSpots: [(Double, Double)] = [
        (-1, 0), (1, 0), (-0.8, -0.8), (0.8, -0.8), (0, -1),
        (-0.7, 0.7), (0.7, 0.7), (0, 0), (0.2, 0.3), (-0.4, -0.2),
    ]

    private var turn = Spring(value: 1), turnTail = Spring(value: 1)
    private var eyeX = Spring(value: 0), eyeY = Spring(value: 0)
    private var headX = Spring(value: 0), headY = Spring(value: 0), headAngle = Spring(value: 0)
    private var tailX = Spring(value: 0), tailY = Spring(value: 0), tailAngle = Spring(value: 0)

    // Moppo only rests facing right (1) or left (-1). It passes the front pose while it turns.
    private var facing = 1.0
    private var pendingFacing: Double?
    private var pendingAt = 0.0
    private var gaze = (0.0, 0.0), micro = (0.0, 0.0)
    private var blinkElapsed: Double?
    private var pendingBlinkAt: Double?
    private var time = 0.0
    private var nextGaze = 0.0, nextBlink = 2.0, nextMicro = 0.0, nextTurn = 4.0
    private var lastDate: Date?

    // Beams. elevation is in degrees below (positive) or above (negative) the horizon.
    // The horizontal side comes from the turn, so the beams follow Moppo when it turns around.
    private var phase = BeamPhase.rest
    private var phaseStart = 0.0, phaseEnd = 0.5
    private var sweepFrom = 0.0, sweepTo = 0.0
    private var elevation = 0.0
    private var turnInSweep = false
    private var nextShotBlink = 0.0
    private var beamLength = Spring(value: 0), beamThickness = Spring(value: 0)
    private var eyeGlow = Spring(value: 0), squash = Spring(value: 0)

    // Large deletion. rayAngle is the screen angle of the rays: 0 points right, 90 points down, 180 points left.
    private var rayAngle = 180.0
    private var destroyDirection = 1.0
    private var shake = CGPoint.zero

    func advance(to date: Date) {
        defer { lastDate = date }
        guard let lastDate else { return }
        let dt = min(0.05, max(0, date.timeIntervalSince(lastDate))) * T.speed
        let steps = max(1, Int((dt / 0.004).rounded(.up)))
        for _ in 0..<steps { update(dt / Double(steps)) }
    }

    private func update(_ dt: Double) {
        time += dt
        switch mode {
        case .search: updateSearch()
        case .scanning, .photoScanning: updateBeams(dt)
        case .destroying: updateDestroying(dt)
        }
        if let pending = pendingFacing, time >= pendingAt {
            facing = pending
            pendingFacing = nil
        }
        if let at = pendingBlinkAt, time >= at {
            startBlink()
            pendingBlinkAt = nil
        }
        if let elapsed = blinkElapsed {
            blinkElapsed = elapsed + dt > T.blinkDuration ? nil : elapsed + dt
        }

        turn.step(toward: facing, stiffness: T.turnStiffness, damping: T.turnDamping, dt: dt)
        turnTail.step(toward: turn.value, stiffness: T.turnTailStiffness, damping: T.turnTailDamping, dt: dt)
        eyeX.step(toward: gaze.0 + micro.0, stiffness: T.eyeStiffness, damping: 0.85, dt: dt)
        eyeY.step(toward: gaze.1 + micro.1, stiffness: T.eyeStiffness, damping: 0.85, dt: dt)
        headX.step(toward: gaze.0 * T.headShift, stiffness: T.headStiffness, damping: T.headDamping, dt: dt)
        headY.step(toward: gaze.1 * T.headShift * 0.5, stiffness: T.headStiffness, damping: T.headDamping, dt: dt)
        headAngle.step(toward: gaze.0 * T.tilt, stiffness: T.headStiffness, damping: T.headDamping, dt: dt)
        // The tails chase the head with a looser spring, so they trail behind and overshoot.
        tailX.step(toward: headX.value, stiffness: T.tailStiffness, damping: T.tailDamping, dt: dt)
        tailY.step(toward: headY.value, stiffness: T.tailStiffness, damping: T.tailDamping, dt: dt)
        tailAngle.step(toward: headAngle.value, stiffness: T.tailStiffness, damping: T.tailDamping, dt: dt)
    }

    private func updateSearch() {
        if time >= nextTurn {
            turnAround()
            nextTurn = time + .random(in: T.turnMin...T.turnMax)
        }
        if time >= nextGaze {
            pickGaze()
            nextGaze = time + .random(in: T.holdMin...T.holdMax)
        }
        if time >= nextBlink {
            startBlink()
            nextBlink = time + .random(in: (T.blinkEvery * 0.6)...(T.blinkEvery * 1.4))
            // A quick second blink now and then.
            if Double.random(in: 0..<1) < 0.18 { nextBlink = time + T.blinkDuration + 0.12 }
        }
        if time >= nextMicro {
            micro = (.random(in: -1...1) * T.microSaccade, .random(in: -1...1) * T.microSaccade)
            nextMicro = time + .random(in: 0.15...0.5)
        }
    }

    // MARK: Beams

    private func updateBeams(_ dt: Double) {
        stepBeamPhase()
        let isFiring = phase == .charge || phase == .fire || phase == .sweep || phase == .off
        if isFiring {
            let direction = beamDirection().direction
            gaze = (Double(direction.x) * 0.9, Double(direction.y) * 0.9)
            micro = (0, 0)
        } else if mode == .photoScanning, phase == .rest {
            // During the long rests of a photo scan, Moppo searches without rays.
            updateSearch()
        } else if phase == .rest, time >= nextGaze {
            pickGaze()
            nextGaze = time + .random(in: T.holdMin...T.holdMax)
        }
        if !isFiring, time >= nextBlink {
            startBlink()
            nextBlink = time + .random(in: (T.blinkEvery * 0.6)...(T.blinkEvery * 1.4))
        }
        // Blinks while shooting cut the beams for a moment.
        if phase == .sweep, time >= nextShotBlink {
            startBlink()
            nextShotBlink = time + .random(in: (T.shotBlinkEvery * 0.5)...(T.shotBlinkEvery * 1.5))
        }

        if phase == .sweep {
            elevation = clampElevation(sweepFrom + (sweepTo - sweepFrom) * Self.easeInOut(phaseProgress))
        }
        stepBeamSprings(dt)
    }

    private var phaseProgress: Double {
        min(1, (time - phaseStart) / max(0.001, phaseEnd - phaseStart))
    }

    private static func easeInOut(_ p: Double) -> Double {
        p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
    }

    private func stepBeamSprings(_ dt: Double) {
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
            // Firing pushes the head back, away from the beams.
            let direction = beamDirection().direction
            headX.velocity -= Double(direction.x) * T.recoil
            headY.velocity -= Double(direction.y) * T.recoil * 0.5
        case .fire:
            setPhase(.sweep, duration: T.sweepTime)
            turnInSweep = Double.random(in: 0..<1) < T.turnWhileShooting
            nextShotBlink = time + .random(in: (T.shotBlinkEvery * 0.5)...(T.shotBlinkEvery * 1.5))
        case .sweep:
            setPhase(.off, duration: T.offTime)
        case .off:
            let rest = mode == .photoScanning ? T.photoRest * Double.random(in: 0.7...1.3) : T.restTime
            setPhase(.rest, duration: rest)
        }
    }

    private func setPhase(_ next: BeamPhase, duration: Double) {
        phase = next
        phaseStart = time
        phaseEnd = time + duration
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
    private func beamDirection() -> (direction: CGPoint, reach: CGFloat) {
        if mode == .destroying {
            let a = rayAngle * .pi / 180
            return (CGPoint(x: cos(a), y: sin(a)), 1)
        }
        let e = elevation * .pi / 180
        let side = min(1, max(-1, turn.value))
        let x = side * cos(e), y = sin(e)
        let length = hypot(x, y)
        guard length > 0 else { return (CGPoint(x: 0, y: 1), 0.2) }
        return (CGPoint(x: x / length, y: y / length), CGFloat(max(0.2, length)))
    }

    // MARK: Large deletion

    /// One pass: face the start side, charge, fire, then sweep a half circle below Moppo to the other side.
    /// The ray angle drives the turn, so Moppo faces the viewer when the rays point straight down.
    private func updateDestroying(_ dt: Double) {
        stepDestroyPhase()
        let isFiring = phase == .charge || phase == .fire || phase == .sweep || phase == .off
        if isFiring || phase == .aim {
            let direction = beamDirection().direction
            gaze = (Double(direction.x) * 0.9, Double(direction.y) * 0.9)
            micro = (0, 0)
        }
        // Moppo does not blink during a large deletion, so the rays stay on.
        let isOn = phase == .fire || phase == .sweep
        shake = isOn
            ? CGPoint(x: CGFloat(Double.random(in: -1...1) * T.destroyShake),
                      y: CGFloat(Double.random(in: -1...1) * T.destroyShake))
            : .zero
        stepBeamSprings(dt)
    }

    private func stepDestroyPhase() {
        let from = destroyDirection > 0 ? 180 - T.destroyStartBelow : T.destroyStartBelow
        let to = 180 - from
        if phase == .sweep {
            rayAngle = from + (to - from) * Self.easeInOut(phaseProgress)
            facing = cos(rayAngle * .pi / 180)
        }
        guard time >= phaseEnd else { return }
        switch phase {
        case .rest, .turning:
            let startFacing: Double = cos(from * .pi / 180) < 0 ? -1 : 1
            rayAngle = from
            pendingFacing = nil
            if facing == startFacing {
                // Moppo already faces the side where the next pass starts, so it fires again at once.
                setPhase(.charge, duration: T.openingCharge)
            } else {
                facing = startFacing
                setPhase(.aim, duration: 0.45)
            }
        case .aim:
            setPhase(.charge, duration: T.chargeTime)
        case .charge:
            setPhase(.fire, duration: T.fireTime)
            let direction = beamDirection().direction
            headX.velocity -= Double(direction.x) * T.recoil
            headY.velocity -= Double(direction.y) * T.recoil * 0.5
        case .fire:
            setPhase(.sweep, duration: T.destroySweepTime)
        case .sweep:
            facing = facing < 0 ? -1 : 1
            setPhase(.off, duration: T.offTime)
        case .off:
            if T.destroyAlternates { destroyDirection = -destroyDirection }
            setPhase(.rest, duration: T.destroyRest)
        }
    }

    private func pickGaze() {
        var spot: (Double, Double)
        repeat {
            spot = Self.gazeSpots.randomElement() ?? (0, 0)
        } while hypot(spot.0 - gaze.0, spot.1 - gaze.1) < 0.6
        gaze = (spot.0 * .random(in: 0.8...1), spot.1 * .random(in: 0.8...1))
        if Double.random(in: 0..<1) < T.blinkOnMove { startBlink() }
    }

    private func turnAround() {
        guard pendingFacing == nil else { return }
        let next = -facing
        // The eyes look toward the new side first. Then the body turns.
        gaze = (next * 0.9, .random(in: -0.3...0.2))
        micro = (0, 0)
        pendingFacing = next
        pendingAt = time + T.eyeLead
        nextGaze = time + T.eyeLead + .random(in: T.holdMin...T.holdMax) + 0.4
        if Double.random(in: 0..<1) < T.blinkOnTurn { pendingBlinkAt = time + T.eyeLead * 0.5 }
    }

    private func startBlink() {
        if blinkElapsed == nil { blinkElapsed = 0 }
    }

    private var eyeOpenness: Double {
        guard let elapsed = blinkElapsed else { return 1 }
        let p = elapsed / T.blinkDuration
        if p < 0.35 { return 1 - p / 0.35 * 0.94 }
        if p < 0.5 { return 0.06 }
        return 0.06 + (p - 0.5) / 0.5 * 0.94
    }

    // MARK: Drawing

    /// `fit` is the share of the canvas that holds Moppo. The rest is room for the beams.
    func draw(_ geometry: MoppoMascotGeometry, in graphics: inout GraphicsContext, size: CGSize, fit: CGFloat = 1) {
        let bounds = geometry.bounds
        let scale = min(size.width * fit / (bounds.width * T.padding), size.height * fit / (bounds.height * T.padding))
        graphics.translateBy(x: size.width / 2 - bounds.midX * scale, y: size.height / 2 - bounds.midY * scale)
        graphics.scaleBy(x: scale, y: scale)

        let (right, front, left) = (geometry.right, geometry.front, geometry.left)
        let headTurn = turn.value, tailTurn = turnTail.value
        let pivot = MoppoMascotGeometry.blend(right.pivot, front.pivot, left.pivot, turn: headTurn)

        var body: [CGPoint] = []
        body.reserveCapacity(right.body.count)
        for i in right.body.indices {
            let weight = geometry.tailWeights[i]
            let pointTurn = headTurn + (tailTurn - headTurn) * T.turnDrag * weight
            let posed = MoppoMascotGeometry.blend(right.body[i], front.body[i], left.body[i], turn: pointTurn)
            body.append(deform(posed, weight: weight, pivot: pivot))
        }

        let openness = eyeOpenness
        let gazeOffset = CGPoint(x: eyeX.value * T.gazeX, y: eyeY.value * T.gazeY)
        var eyes = Path()
        var eyeCenters: [CGPoint] = []
        for e in 0..<2 {
            let eye = right.eyes[e].indices.map {
                MoppoMascotGeometry.blend(right.eyes[e][$0], front.eyes[e][$0], left.eyes[e][$0], turn: headTurn)
            }
            let center = eye.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let c = CGPoint(x: center.x / CGFloat(eye.count), y: center.y / CGFloat(eye.count))
            // The eye on the far side of the gaze narrows a little, which reads as turning.
            let side = e == 0 ? -1.0 : 1.0
            let squash = 1 - T.eyeSquash * max(0, -side * eyeX.value) - T.eyeSquash * 0.4 * abs(eyeX.value)
            let moved = eye.map { p in
                deform(CGPoint(x: c.x + (p.x - c.x) * squash + gazeOffset.x,
                               y: c.y + (p.y - c.y) * openness + gazeOffset.y),
                       weight: 0, pivot: pivot)
            }
            eyes.addPath(Self.smoothRing(moved))
            eyeCenters.append(deform(CGPoint(x: c.x + gazeOffset.x, y: c.y + gazeOffset.y), weight: 0, pivot: pivot))
        }

        let beams = mode == .search ? [] : beamShapes(eyeCenters: eyeCenters, openness: openness)
        // The lit floor goes behind Moppo, so the tails cover it where they overlap.
        drawFloorLight(of: beams, in: &graphics)
        // The eyes are holes, so they show whatever is behind Moppo.
        graphics.drawLayer { layer in
            let bodyFill: GraphicsContext.Shading = layer.environment.colorScheme == .light
                ? .color(Color(white: 0x2B / 255)) : .foreground
            layer.fill(Self.smoothRing(body), with: bodyFill)
            layer.blendMode = .destinationOut
            layer.fill(eyes, with: .color(.black))
        }
        if mode != .search { drawBeams(beams, in: &graphics, eyes: eyes, eyeCenters: eyeCenters, openness: openness) }
    }

    private var beamColor: Color { mode == .destroying ? T.destroyColor : T.beamColor }

    /// One beam from one eye. When the beam reaches the floor, `floor` is the oval it lights there.
    private struct BeamShape {
        struct FloorSpot {
            let center: CGPoint
            let radiusX: CGFloat, radiusY: CGFloat
            let light: Double
        }

        let origin: CGPoint
        let fadeEnd: CGPoint
        let end: CGPoint
        let startHalfWidth: CGFloat, endHalfWidth: CGFloat
        let normal: CGPoint
        let floor: FloorSpot?
    }

    private func beamShapes(eyeCenters: [CGPoint], openness: Double) -> [BeamShape] {
        let isDestroying = mode == .destroying
        let thickness = CGFloat(max(0, beamThickness.value) * openness)
        let length = CGFloat((isDestroying ? T.destroyLength : T.beamLength) * max(0, beamLength.value))
        guard length > 1, thickness > 0.005 else { return [] }
        let (direction, reach) = beamDirection()
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let spread = CGFloat(T.beamSpread) * thickness
        let startHalfWidth = CGFloat(isDestroying ? T.destroyStartWidth : T.beamStartWidth) * thickness / 2
        let reachLength = length * reach
        let floorY = CGFloat(T.floorY)

        return eyeCenters.map { o in
            let fadeEnd = CGPoint(x: o.x + direction.x * reachLength, y: o.y + direction.y * reachLength)
            var drawn = reachLength
            var spot: BeamShape.FloorSpot?
            let toFloor = direction.y > 0.02 ? (floorY - o.y) / direction.y : -1
            // Every downward beam reaches the floor. Past the beam's length its light has faded out,
            // so a far spot fades in as the angle gets steeper instead of appearing at once.
            if toFloor > 0, toFloor < reachLength * 3 {
                drawn = reachLength * 3
                let farHalfWidth = startHalfWidth + drawn * spread
                let far = CGPoint(x: o.x + direction.x * drawn, y: o.y + direction.y * drawn)
                // The oval's ends are where the two edges of the beam meet the floor.
                func edgeX(_ side: CGFloat) -> CGFloat {
                    let start = CGPoint(x: o.x + normal.x * startHalfWidth * side, y: o.y + normal.y * startHalfWidth * side)
                    let tip = CGPoint(x: far.x + normal.x * farHalfWidth * side, y: far.y + normal.y * farHalfWidth * side)
                    guard tip.y > floorY, tip.y > start.y else { return tip.x }
                    let u = max(0, (floorY - start.y) / (tip.y - start.y))
                    return start.x + (tip.x - start.x) * u
                }
                let x1 = edgeX(1), x2 = edgeX(-1)
                let across = startHalfWidth + min(toFloor, reachLength) * spread
                // The beam fades along its length, so a far floor gets less light. Light at an angle also spreads out.
                let light = T.poolBrightness * max(0, 1 - Double(toFloor / reachLength))
                    * min(1, Double(direction.y) * 1.4) * Double(thickness)
                spot = BeamShape.FloorSpot(center: CGPoint(x: (x1 + x2) / 2, y: floorY), radiusX: max(1, abs(x2 - x1) / 2),
                                           radiusY: across * CGFloat(T.floorFlatness), light: light)
            }
            let end = CGPoint(x: o.x + direction.x * drawn, y: o.y + direction.y * drawn)
            return BeamShape(origin: o, fadeEnd: fadeEnd, end: end, startHalfWidth: startHalfWidth,
                             endHalfWidth: startHalfWidth + drawn * spread, normal: normal, floor: spot)
        }
    }

    private func drawFloorLight(of beams: [BeamShape], in graphics: inout GraphicsContext) {
        let color = beamColor
        let core = T.poolCore
        for beam in beams {
            guard let spot = beam.floor else { continue }
            let light = min(1, max(0, spot.light))
            guard light > 0.01 else { continue }
            // A hot, paler core that fades to the beam color at the edge.
            let gradient = Gradient(stops: [
                .init(color: Color(red: 1, green: (150 + 80 * core) / 255, blue: 140 * core / 255)
                    .opacity(light * (0.4 + 0.6 * core)), location: 0),
                .init(color: color.opacity(light * 0.75), location: 0.35),
                .init(color: color.opacity(0), location: 1),
            ])
            var pool = graphics
            pool.translateBy(x: spot.center.x, y: spot.center.y)
            pool.scaleBy(x: spot.radiusX * CGFloat(T.poolGlowSize), y: spot.radiusY * CGFloat(T.poolGlowSize))
            pool.fill(Path(ellipseIn: CGRect(x: -1, y: -1, width: 2, height: 2)),
                      with: .radialGradient(gradient, center: .zero, startRadius: 0, endRadius: 1))
        }
    }

    private func drawBeams(_ beams: [BeamShape], in graphics: inout GraphicsContext,
                           eyes: Path, eyeCenters: [CGPoint], openness: Double) {
        let isDestroying = mode == .destroying
        let color = beamColor
        let startWidth = isDestroying ? T.destroyStartWidth : T.beamStartWidth
        let glow = min(1, max(0, eyeGlow.value))
        if glow > 0.01 { graphics.fill(eyes, with: .color(color.opacity(glow))) }

        let thickness = CGFloat(max(0, beamThickness.value) * openness)
        guard !beams.isEmpty else { return }

        // Facing the viewer mid turn, each beam blooms into a soft disc over its eye.
        let facingViewer = max(0, 1 - abs(turn.value) / T.flashWindow) * min(1, max(0, beamLength.value)) * Double(thickness)
        if !isDestroying, T.flashSize > 0, facingViewer > 0.01 {
            let f = facingViewer * facingViewer * (3 - 2 * facingViewer)
            let radius = CGFloat(startWidth / 2 + T.flashSize * f)
            let gradient = Gradient(stops: [
                .init(color: color.opacity(T.beamOpacity * f), location: 0),
                .init(color: color.opacity(T.beamOpacity * f * 0.6), location: 0.55),
                .init(color: color.opacity(0), location: 1),
            ])
            for o in eyeCenters {
                let disc = Path(ellipseIn: CGRect(x: o.x - radius, y: o.y - radius, width: radius * 2, height: radius * 2))
                graphics.fill(disc, with: .radialGradient(gradient, center: o, startRadius: 0, endRadius: radius))
            }
        }

        let fade = Gradient(colors: [color.opacity(T.beamOpacity), color.opacity(0)])
        for shape in beams {
            let (o, end, n) = (shape.origin, shape.end, shape.normal)
            let (w0, w1) = (shape.startHalfWidth, shape.endHalfWidth)
            var beam = Path()
            beam.move(to: CGPoint(x: o.x + n.x * w0, y: o.y + n.y * w0))
            beam.addLine(to: CGPoint(x: end.x + n.x * w1, y: end.y + n.y * w1))
            beam.addLine(to: CGPoint(x: end.x - n.x * w1, y: end.y - n.y * w1))
            beam.addLine(to: CGPoint(x: o.x - n.x * w0, y: o.y - n.y * w0))
            beam.closeSubpath()
            beam.addEllipse(in: CGRect(x: o.x - w0, y: o.y - w0, width: w0 * 2, height: w0 * 2))
            var context = graphics
            // The beam keeps its straight shape. The floor hides it below the floor line, except inside the lit oval,
            // so the beam's foot follows the oval's rim.
            if let spot = shape.floor { context.clip(to: Self.floorClip(spot)) }
            context.fill(beam, with: .linearGradient(fade, startPoint: o, endPoint: shape.fadeEnd))
        }
    }

    /// Everything above the floor line, plus the lit oval. Both outlines run in the same direction,
    /// so together they make one region.
    private static func floorClip(_ spot: BeamShape.FloorSpot) -> Path {
        var path = Path()
        let top: CGFloat = -100_000, side: CGFloat = 100_000, floor = spot.center.y
        path.move(to: CGPoint(x: -side, y: top))
        path.addLine(to: CGPoint(x: side, y: top))
        path.addLine(to: CGPoint(x: side, y: floor))
        path.addLine(to: CGPoint(x: -side, y: floor))
        path.closeSubpath()
        let steps = 64
        for i in 0..<steps {
            let angle = Double(i) / Double(steps) * 2 * .pi
            let point = CGPoint(x: spot.center.x + spot.radiusX * CGFloat(cos(angle)),
                                y: floor + spot.radiusY * CGFloat(sin(angle)))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    /// Bends the posed shape. Points near the head follow the head, and points near the tips lag and sway.
    private func deform(_ p: CGPoint, weight w: CGFloat, pivot: CGPoint) -> CGPoint {
        // Powering down the beams flattens the body a little.
        let dx = (p.x - pivot.x) * (1 + squash.value * 0.6), dy = (p.y - pivot.y) * (1 - squash.value)
        let radius = hypot(dx, dy), theta = atan2(dy, dx)
        let wave = T.sway * .pi / 180 * w
            * sin(2 * .pi * T.swayHz * time - radius / T.waveLength * 2 * .pi + theta * T.strandPhase)
        let angle = (headAngle.value + (tailAngle.value - headAngle.value) * T.drag * w) * .pi / 180 + wave
        // While firing in a deletion, the whole body shakes. The tail tips shake a little less.
        let offsetX = headX.value + (tailX.value - headX.value) * T.drag * w + shake.x * (1 - 0.5 * w)
        let offsetY = headY.value + (tailY.value - headY.value) * T.drag * w + shake.y * (1 - 0.5 * w)
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: pivot.x + dx * c - dy * s + offsetX, y: pivot.y + dx * s + dy * c + offsetY)
    }

    /// Draws a closed outline with curves through the midpoints of the samples.
    private static func smoothRing(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for i in points.indices {
            let p = points[i], q = points[(i + 1) % points.count]
            path.addQuadCurve(to: CGPoint(x: (p.x + q.x) / 2, y: (p.y + q.y) / 2), control: p)
        }
        path.closeSubpath()
        return path
    }
}

#Preview("Moppo destroying") {
    MoppoMascotView(mode: .destroying)
        .frame(width: PageStateMetrics.iconAreaSize, height: PageStateMetrics.iconAreaSize)
        .foregroundStyle(.tertiary)
        .padding(120)
}

#Preview("Moppo scanning") {
    MoppoMascotView(mode: .scanning)
        .frame(width: PageStateMetrics.iconAreaSize, height: PageStateMetrics.iconAreaSize)
        .foregroundStyle(.tertiary)
        .padding(40)
}
