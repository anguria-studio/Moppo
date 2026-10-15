import SwiftUI

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

    /// The vertical line through the middle of the front pose. Shapes that Moppo turns into are centered on it.
    var centerX: CGFloat { front.pivot.x }

    /// Blends the three poses. `turn` is 1 for right, 0 for front, and -1 for left.
    static func blend(_ right: CGPoint, _ front: CGPoint, _ left: CGPoint, turn: CGFloat) -> CGPoint {
        let (target, amount) = turn >= 0 ? (right, turn) : (left, -turn)
        return CGPoint(x: front.x + (target.x - front.x) * amount, y: front.y + (target.y - front.y) * amount)
    }

    /// Gives a closed outline the same number of points as Moppo's body.
    /// Point `i` of Moppo goes to the point at the same share of the outline's length, so a morph keeps its order.
    /// The outline must run clockwise from its top, as Moppo's body does.
    func outline(matching shape: [CGPoint]) -> [CGPoint] {
        let lengths = Self.cumulativeLengths(shape)
        let bodyLengths = Self.cumulativeLengths(right.body)
        let total = lengths[lengths.count - 1], bodyTotal = bodyLengths[bodyLengths.count - 1]
        var result: [CGPoint] = []
        result.reserveCapacity(right.body.count)
        var j = 0
        for i in right.body.indices {
            let target = bodyLengths[i] / bodyTotal * total
            while j < shape.count - 1, lengths[j + 1] < target { j += 1 }
            let span = lengths[j + 1] - lengths[j]
            let u = span > 0 ? (target - lengths[j]) / span : 0
            result.append(Self.mix(shape[j], shape[(j + 1) % shape.count], u))
        }
        return result
    }

    /// Resamples a closed outline to `count` points at even distances.
    static func resampled(_ shape: [CGPoint], count: Int) -> [CGPoint] {
        let lengths = cumulativeLengths(shape), total = lengths[lengths.count - 1]
        var result: [CGPoint] = []
        var j = 0
        for i in 0..<count {
            let target = total * CGFloat(i) / CGFloat(count)
            while j < shape.count - 1, lengths[j + 1] < target { j += 1 }
            let span = lengths[j + 1] - lengths[j]
            result.append(mix(shape[j], shape[(j + 1) % shape.count], span > 0 ? (target - lengths[j]) / span : 0))
        }
        return result
    }

    /// Adds points along the straight sides of a closed outline, about `step` units apart.
    static func filled(_ corners: [CGPoint], step: CGFloat = 6) -> [CGPoint] {
        var result: [CGPoint] = []
        for i in corners.indices {
            let a = corners[i], b = corners[(i + 1) % corners.count]
            let steps = max(1, Int((hypot(b.x - a.x, b.y - a.y) / step).rounded()))
            for s in 0..<steps { result.append(mix(a, b, CGFloat(s) / CGFloat(steps))) }
        }
        return result
    }

    /// Draws a closed outline with curves through the midpoints of the samples.
    static func ring(_ points: [CGPoint]) -> Path {
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

    static func mix(_ a: CGPoint, _ b: CGPoint, _ u: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
    }

    static func center(of points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(max(1, points.count)), y: sum.y / CGFloat(max(1, points.count)))
    }

    /// The distance along a closed outline to each point, plus the full length at the end.
    private static func cumulativeLengths(_ points: [CGPoint]) -> [CGFloat] {
        var lengths: [CGFloat] = [0]
        lengths.reserveCapacity(points.count + 1)
        for i in 1...points.count {
            let p = points[i % points.count], q = points[i - 1]
            lengths.append(lengths[i - 1] + hypot(p.x - q.x, p.y - q.y))
        }
        return lengths
    }
}

private final class BundleToken {}

struct Spring {
    var value: Double
    var velocity = 0.0

    mutating func step(toward target: Double, stiffness: Double, damping: Double, dt: Double) {
        let acceleration = stiffness * (target - value) - 2 * damping * stiffness.squareRoot() * velocity
        velocity += acceleration * dt
        value += velocity * dt
    }
}

/// Shared easing for timed moves.
enum MascotEasing {
    static func inOut(_ p: Double) -> Double {
        p < 0.5 ? 2 * p * p : 1 - pow(-2 * p + 2, 2) / 2
    }
}
