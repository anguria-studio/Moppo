import CoreGraphics
import Testing

@Suite("Moppo mascot geometry")
struct MoppoMascotTests {
    @Test("The bundled poses load with matching points")
    func posesMatch() throws {
        let geometry = try #require(MoppoMascotGeometry.shared)
        #expect(geometry.isConsistent)
        #expect(geometry.right.body.count == 1088)
        #expect(geometry.tailWeights.allSatisfy { (0...1).contains($0) })
    }

    @Test("Turn values 1, 0, and -1 give the right, front, and left poses")
    func blendEndpoints() {
        let right = CGPoint(x: 10, y: 0), front = CGPoint(x: 0, y: 5), left = CGPoint(x: -10, y: 0)
        #expect(MoppoMascotGeometry.blend(right, front, left, turn: 1) == right)
        #expect(MoppoMascotGeometry.blend(right, front, left, turn: 0) == front)
        #expect(MoppoMascotGeometry.blend(right, front, left, turn: -1) == left)
        #expect(MoppoMascotGeometry.blend(right, front, left, turn: 0.5) == CGPoint(x: 5, y: 2.5))
    }
}
