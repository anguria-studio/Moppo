import SwiftUI

/// Runs Moppo's motion. The view keeps one instance and advances it once for each frame.
/// The beams are in `Beams/`, and the acts are in `Acts/`.
@MainActor
final class MoppoMascotMotion {
    typealias T = MascotTuning

    enum BeamPhase { case rest, turning, aim, charge, fire, sweep, off }

    let mode: MoppoMascotView.Mode

    init(mode: MoppoMascotView.Mode = .search) {
        self.mode = mode
        plannedActStart = MascotActScheduler.plan(for: mode, roll: .random(in: 0..<1), delay: .random(in: 0...1))
        // A deletion starts on the left side with the eyes lit, so the first pass begins at once.
        if mode == .destroying {
            facing = -1
            bodyTurn = Spring(value: -1)
            tailTurn = Spring(value: -1)
            rayAngle = 180 - T.destroyStartBelow
            eyeGlow = Spring(value: 1)
            phase = .charge
            phaseEnd = T.openingCharge
        }
    }

    static let gazeSpots: [(Double, Double)] = [
        (-1, 0), (1, 0), (-0.8, -0.8), (0.8, -0.8), (0, -1),
        (-0.7, 0.7), (0.7, 0.7), (0, 0), (0.2, 0.3), (-0.4, -0.2),
    ]

    var bodyTurn = Spring(value: 1), tailTurn = Spring(value: 1)
    var eyeX = Spring(value: 0), eyeY = Spring(value: 0)
    var headX = Spring(value: 0), headY = Spring(value: 0), headAngle = Spring(value: 0)
    var tailX = Spring(value: 0), tailY = Spring(value: 0), tailAngle = Spring(value: 0)

    // Moppo only rests facing right (1) or left (-1). It passes the front pose while it turns.
    var facing = 1.0
    var pendingFacing: Double?
    private var pendingAt = 0.0
    var gaze = (0.0, 0.0), micro = (0.0, 0.0)
    private var blinkElapsed: Double?
    private var pendingBlinkAt: Double?
    private(set) var time = 0.0
    var nextGaze = 0.0, nextBlink = 2.0
    private var nextMicro = 0.0, nextTurn = 4.0
    private var lastDate: Date?
    private var firstDate: Date?

    // Beams. elevation is in degrees below (positive) or above (negative) the horizon.
    // The horizontal side comes from the turn, so the beams follow Moppo when it turns around.
    var phase = BeamPhase.rest
    // The first shot waits a moment after the scan appears.
    var phaseStart = 0.0, phaseEnd = T.firstShotDelay
    var sweepFrom = 0.0, sweepTo = 0.0
    var elevation = 0.0
    var turnInSweep = false
    var nextShotBlink = 0.0
    var beamLength = Spring(value: 0), beamThickness = Spring(value: 0)
    var eyeGlow = Spring(value: 0), squash = Spring(value: 0)

    // Large deletion. rayAngle is the screen angle of the rays: 0 points right, 90 points down, 180 points left.
    var rayAngle = 180.0
    var destroyDirection = 1.0
    var shake = CGPoint.zero

    // Acts
    private(set) var act: (any MascotAct)?
    /// A shape that the screen asks Moppo to hold. Moppo turns back when the request ends.
    var requestedShape: MascotShape?
    private var controls = MascotControls()
    /// The operation time when the planned act can start. It is nil when this operation has no act left.
    private var plannedActStart: Double?
    // When an act ends, its squash and lids settle back from where the act left them.
    private var actSquash = Spring(value: 0), lids = Spring(value: 1)
    private var squashKick = 0.0

    var hasBeams: Bool {
        switch mode {
        case .scanning, .photoScanning, .fileDuplicateScanning, .destroying: true
        case .search, .hourglass: false
        }
    }

    func advance(to date: Date) {
        defer { lastDate = date }
        if firstDate == nil { firstDate = date }
        guard let lastDate else { return }
        let dt = min(0.05, max(0, date.timeIntervalSince(lastDate))) * T.speed
        let steps = max(1, Int((dt / 0.004).rounded(.up)))
        for _ in 0..<steps { update(dt / Double(steps), now: date) }
    }

    private func update(_ dt: Double, now: Date) {
        time += dt
        if act == nil, mode == .hourglass { act = HourglassAct(rig: self) }
        followRequestedShape()
        if act == nil { startPlannedAct(now: now) }
        if let act {
            controls = act.update(dt, rig: self)
            if let target = controls.gaze { gaze = (target.x, target.y) }
            micro = (0, 0)
            actSquash = Spring(value: controls.squash)
            lids = Spring(value: controls.lids)
            if act.isFinished { finishAct(now: now) }
        } else {
            controls = MascotControls()
            switch mode {
            case .search: updateSearch()
            case .scanning, .photoScanning, .fileDuplicateScanning: updateBeams(dt)
            case .destroying: updateDestroying(dt)
            case .hourglass: break
            }
        }
        actSquash.velocity += squashKick
        squashKick = 0
        if act == nil {
            actSquash.step(toward: 0, stiffness: 300, damping: 0.5, dt: dt)
            lids.step(toward: 1, stiffness: 200, damping: 0.6, dt: dt)
        }
        if hasBeams { stepBeamSprings(dt) }

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

        bodyTurn.step(toward: controls.facing ?? facing, stiffness: T.turnStiffness, damping: T.turnDamping, dt: dt)
        tailTurn.step(toward: bodyTurn.value, stiffness: T.turnTailStiffness, damping: T.turnTailDamping, dt: dt)
        eyeX.step(toward: gaze.0 + micro.0, stiffness: T.eyeStiffness, damping: 0.85, dt: dt)
        eyeY.step(toward: gaze.1 + micro.1, stiffness: T.eyeStiffness, damping: 0.85, dt: dt)
        let head = controls.head ?? (gaze.0 * T.headShift, gaze.1 * T.headShift * 0.5, gaze.0 * T.tilt)
        headX.step(toward: head.x, stiffness: T.headStiffness, damping: T.headDamping, dt: dt)
        headY.step(toward: head.y, stiffness: T.headStiffness, damping: T.headDamping, dt: dt)
        headAngle.step(toward: head.angle, stiffness: T.headStiffness, damping: T.headDamping, dt: dt)
        // The tails chase the head with a looser spring, so they trail behind and overshoot.
        tailX.step(toward: headX.value, stiffness: T.tailStiffness, damping: T.tailDamping, dt: dt)
        tailY.step(toward: headY.value, stiffness: T.tailStiffness, damping: T.tailDamping, dt: dt)
        tailAngle.step(toward: headAngle.value, stiffness: T.tailStiffness, damping: T.tailDamping, dt: dt)
    }

    func updateSearch() {
        if time >= nextTurn {
            turnAround()
            nextTurn = time + .random(in: T.turnMin...T.turnMax)
        }
        lookAround()
        if time >= nextMicro {
            micro = (.random(in: -1...1) * T.microSaccade, .random(in: -1...1) * T.microSaccade)
            nextMicro = time + .random(in: 0.15...0.5)
        }
    }

    func pickGaze() {
        var spot: (Double, Double)
        repeat {
            spot = Self.gazeSpots.randomElement() ?? (0, 0)
        } while hypot(spot.0 - gaze.0, spot.1 - gaze.1) < 0.6
        gaze = (spot.0 * .random(in: 0.8...1), spot.1 * .random(in: 0.8...1))
        if Double.random(in: 0..<1) < T.blinkOnMove { startBlink() }
    }

    func scheduleBlink() {
        startBlink()
        nextBlink = time + .random(in: (T.blinkEvery * 0.6)...(T.blinkEvery * 1.4))
    }

    // MARK: Acts

    /// The beams must be fully off before an act starts, so an act never mixes with the rays.
    /// An act also waits for a pause after the last shot, so it does not follow the beams at once.
    private var beamsAreOff: Bool {
        phase == .rest && eyeGlow.value < 0.02 && beamLength.value < 0.02 && beamThickness.value < 0.02
            && (!hasBeams || time - phaseStart >= T.pauseBeforeAct)
    }

    private func startPlannedAct(now: Date) {
        guard let start = plannedActStart, let firstDate, now.timeIntervalSince(firstDate) >= start,
              beamsAreOff, pendingFacing == nil, MascotActScheduler.allowsAct(at: now)
        else { return }
        // The operation gets one try.
        plannedActStart = nil
        guard let kind = MascotActScheduler.pick(
            from: MascotActScheduler.choices(for: mode), elapsed: now.timeIntervalSince(firstDate), roll: .random(in: 0..<1)
        ) else { return }
        play(kind)
    }

    private func followRequestedShape() {
        let sliders = act as? SettingsSlidersAct
        switch requestedShape {
        case .settings:
            if let sliders { sliders.hold(at: time) } else if act == nil { start(SettingsSlidersAct(rig: self)) }
        case nil:
            sliders?.release()
        }
    }

    /// Starts an act now, without the scheduler.
    func play(_ kind: MascotActKind) {
        guard act == nil else { return }
        start(kind.makeAct(rig: self))
    }

    private func start(_ next: any MascotAct) {
        blinkElapsed = nil
        pendingBlinkAt = nil
        gaze = (0, 0)
        micro = (0, 0)
        act = next
    }

    private func finishAct(now: Date) {
        MascotActScheduler.lastActEnd = now
        act = nil
        controls = MascotControls()
        nextGaze = time + 0.3
        nextBlink = time + 1
        nextTurn = time + .random(in: T.turnMin...T.turnMax)
        // A full rest follows the act, so the beams do not fire while Moppo settles.
        if hasBeams, mode != .destroying { setPhase(.rest, duration: restDuration) }
    }

    func startBlink() {
        if blinkElapsed == nil { blinkElapsed = 0 }
    }

    func turnAround() {
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

    var blinkOpenness: Double {
        guard let elapsed = blinkElapsed else { return 1 }
        let p = elapsed / T.blinkDuration
        if p < 0.35 { return 1 - p / 0.35 * 0.94 }
        if p < 0.5 { return 0.06 }
        return 0.06 + (p - 0.5) / 0.5 * 0.94
    }

    // MARK: Drawing

    /// `fit` is the share of the canvas that holds Moppo. The rest is room for the beams and the acts.
    func draw(_ geometry: MoppoMascotGeometry, in graphics: inout GraphicsContext, size: CGSize, fit: CGFloat = 1) {
        let bounds = geometry.bounds
        let scale = min(size.width * fit / (bounds.width * T.padding), size.height * fit / (bounds.height * T.padding))
        graphics.translateBy(x: size.width / 2 - bounds.midX * scale, y: size.height / 2 - bounds.midY * scale)
        graphics.scaleBy(x: scale, y: scale)

        if let copies = act?.copies {
            for copy in copies {
                drawMoppo(geometry, in: &graphics, turn: copy.turn, tailTurn: copy.turn,
                          extraOffset: CGPoint(x: copy.offsetX, y: 0), eyeX: copy.eyeX)
            }
        } else {
            drawMoppo(geometry, in: &graphics, turn: bodyTurn.value, tailTurn: tailTurn.value, extraOffset: .zero, eyeX: nil)
        }
    }

    private func drawMoppo(_ geometry: MoppoMascotGeometry, in graphics: inout GraphicsContext,
                           turn: Double, tailTurn: Double, extraOffset: CGPoint, eyeX overrideEyeX: Double?) {
        var frame = makeFrame(geometry, turn: turn, tailTurn: tailTurn, extraOffset: extraOffset,
                              eyeX: overrideEyeX ?? eyeX.value, environment: graphics.environment)
        if act?.drawInstead(frame, in: &graphics) == true { return }
        act?.shape(&frame)

        let beams = hasBeams ? beamShapes(eyeCenters: frame.eyeCenters, openness: frame.openness) : []
        // The lit floor goes behind Moppo, so the tails cover it where they overlap.
        drawFloorLight(of: beams, in: &graphics)
        act?.drawBehind(frame, in: &graphics)

        let body = MoppoMascotGeometry.ring(frame.body)
        var eyes = Path()
        for eye in frame.eyes { eyes.addPath(MoppoMascotGeometry.ring(eye)) }
        var holes = eyes
        if let extra = act?.extraHoles(frame) { holes.addPath(extra) }

        var bodyContext = graphics
        if let level = act?.hiddenBelow {
            bodyContext.clip(to: Path(CGRect(x: -100_000, y: -100_000, width: 200_000, height: 100_000 + level)))
        }
        // The eyes are holes, so they show whatever is behind Moppo.
        bodyContext.drawLayer { layer in
            layer.fill(body, with: frame.bodyFill)
            act?.drawOnBody(frame, body: body, in: &layer)
            layer.blendMode = .destinationOut
            layer.fill(holes, with: .color(.black))
        }
        act?.drawInEyes(frame, eyes: eyes, in: &bodyContext)
        act?.drawFront(frame, in: &graphics)

        let glow = clamp01(max(eyeGlow.value, controls.eyeGlow))
        if glow > 0.01 { graphics.fill(eyes, with: .color(beamColor.opacity(glow))) }
        if !beams.isEmpty { drawBeams(beams, in: &graphics, eyeCenters: frame.eyeCenters, openness: frame.openness) }
    }

    private func makeFrame(_ geometry: MoppoMascotGeometry, turn headTurn: Double, tailTurn: Double,
                           extraOffset: CGPoint, eyeX gazeX: Double, environment: EnvironmentValues) -> MascotFrame {
        let (right, front, left) = (geometry.right, geometry.front, geometry.left)
        let pivot = MoppoMascotGeometry.blend(right.pivot, front.pivot, left.pivot, turn: headTurn)
        let offset = CGPoint(x: controls.offset.x + extraOffset.x, y: controls.offset.y + extraOffset.y)

        var body: [CGPoint] = []
        body.reserveCapacity(right.body.count)
        for i in right.body.indices {
            let weight = geometry.tailWeights[i]
            let pointTurn = headTurn + (tailTurn - headTurn) * T.turnDrag * weight
            let posed = MoppoMascotGeometry.blend(right.body[i], front.body[i], left.body[i], turn: pointTurn)
            body.append(deform(posed, weight: weight, pivot: pivot, offset: offset))
        }

        let blink = blinkOpenness
        let openness = blink * max(0.03, lids.value)
        let gazeOffset = CGPoint(x: gazeX * T.gazeX, y: eyeY.value * T.gazeY)
        var eyes: [[CGPoint]] = []
        var eyeCenters: [CGPoint] = []
        for e in 0..<2 {
            let eye = right.eyes[e].indices.map {
                MoppoMascotGeometry.blend(right.eyes[e][$0], front.eyes[e][$0], left.eyes[e][$0], turn: headTurn)
            }
            let c = MoppoMascotGeometry.center(of: eye)
            // The eye on the far side of the gaze narrows a little, which reads as turning.
            let side = e == 0 ? -1.0 : 1.0
            let squash = 1 - T.eyeSquash * max(0, -side * gazeX) - T.eyeSquash * 0.4 * abs(gazeX)
            eyes.append(eye.map { p in
                deform(CGPoint(x: c.x + (p.x - c.x) * squash + gazeOffset.x,
                               y: c.y + (p.y - c.y) * openness + gazeOffset.y),
                       weight: 0, pivot: pivot, offset: offset)
            })
            eyeCenters.append(deform(CGPoint(x: c.x + gazeOffset.x, y: c.y + gazeOffset.y),
                                     weight: 0, pivot: pivot, offset: offset))
        }

        let isLight = environment.colorScheme == .light
        return MascotFrame(
            geometry: geometry, time: time, turn: headTurn, pivot: pivot, body: body, eyes: eyes,
            eyeCenters: eyeCenters, openness: openness, blink: blink, gaze: CGPoint(x: gazeX, y: eyeY.value),
            head: CGPoint(x: headX.value, y: headY.value), headAngle: headAngle.value, offset: offset,
            bodyFill: isLight ? .color(MascotFrame.lightBody) : .foreground, isLight: isLight
        )
    }

    /// Bends the posed shape. Points near the head follow the head, and points near the tips lag and sway.
    private func deform(_ p: CGPoint, weight w: CGFloat, pivot: CGPoint, offset: CGPoint) -> CGPoint {
        // Powering down the beams flattens the body a little. Some acts also squash or stretch it.
        let flatten = squash.value + actSquash.value
        let dx = (p.x - pivot.x) * (1 + flatten * 0.6), dy = (p.y - pivot.y) * (1 - flatten)
        let radius = hypot(dx, dy), theta = atan2(dy, dx)
        let wave = T.sway * .pi / 180 * w
            * sin(2 * .pi * T.swayHz * time - radius / T.waveLength * 2 * .pi + theta * T.strandPhase)
        let angle = (headAngle.value + (tailAngle.value - headAngle.value) * T.drag * w) * .pi / 180 + wave
        // While firing in a deletion, the whole body shakes. The tail tips shake a little less.
        let offsetX = headX.value + (tailX.value - headX.value) * T.drag * w + shake.x * (1 - 0.5 * w) + offset.x
        let offsetY = headY.value + (tailY.value - headY.value) * T.drag * w + shake.y * (1 - 0.5 * w) + offset.y
        let c = cos(angle), s = sin(angle)
        return CGPoint(x: pivot.x + dx * c - dy * s + offsetX, y: pivot.y + dx * s + dy * c + offsetY)
    }
}

extension MoppoMascotMotion: MascotRig {
    var turn: Double { bodyTurn.value }

    func lookAround() {
        if time >= nextGaze {
            pickGaze()
            nextGaze = time + .random(in: T.holdMin...T.holdMax)
        }
        if time >= nextBlink {
            scheduleBlink()
            // A quick second blink now and then.
            if Double.random(in: 0..<1) < 0.18 { nextBlink = time + T.blinkDuration + 0.12 }
        }
    }

    func kick(headY push: Double, squash: Double) {
        headY.velocity += push
        squashKick += squash
    }
}
