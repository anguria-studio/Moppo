import SwiftUI

/// One beam from one eye. When the beam reaches the floor, `floor` is the oval it lights there.
struct BeamShape {
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

/// Draws the beams, the rays, and the light where they reach the floor.
extension MoppoMascotMotion {
    func beamShapes(eyeCenters: [CGPoint], openness: Double) -> [BeamShape] {
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

    func drawFloorLight(of beams: [BeamShape], in graphics: inout GraphicsContext) {
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

    func drawBeams(_ beams: [BeamShape], in graphics: inout GraphicsContext, eyeCenters: [CGPoint], openness: Double) {
        let isDestroying = mode == .destroying
        let color = beamColor
        let startWidth = isDestroying ? T.destroyStartWidth : T.beamStartWidth
        let thickness = CGFloat(max(0, beamThickness.value) * openness)

        // Facing the viewer mid turn, each beam blooms into a soft disc over its eye.
        let facingViewer = max(0, 1 - abs(bodyTurn.value) / T.flashWindow) * min(1, max(0, beamLength.value)) * Double(thickness)
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
}
