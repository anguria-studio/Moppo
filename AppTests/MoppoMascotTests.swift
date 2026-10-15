import CoreGraphics
import Foundation
import SwiftUI
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

@Suite("Moppo acts")
struct MoppoMascotActTests {
    private typealias Scheduler = MascotActScheduler

    @Test("An operation gets an act only on a 3 in 4 roll, and never in the first 5 seconds")
    func planRules() {
        #expect(Scheduler.plan(for: .scanning, roll: 0.8, delay: 0) == nil)
        #expect(Scheduler.plan(for: .scanning, roll: 0.1, delay: 0) == Scheduler.firstDelay)
        #expect(Scheduler.plan(for: .scanning, roll: 0.1, delay: 1) == Scheduler.latestStart(for: .scanning))
        #expect(Scheduler.plan(for: .destroying, roll: 0, delay: 0) == nil)
        #expect(Scheduler.plan(for: .hourglass, roll: 0, delay: 0) == nil)
    }

    @Test("The yawn waits until the photo duplicate scan has run for 60 seconds")
    func yawnWaits() {
        let yawn = [Scheduler.Choice(kind: .yawn, minimumElapsed: 60)]
        #expect(Scheduler.pick(from: yawn, elapsed: 59, roll: 0) == nil)
        #expect(Scheduler.pick(from: yawn, elapsed: 60, roll: 0) == .yawn)
    }

    @Test("Each act draws and then gives Moppo back", arguments: MascotActKind.allCases)
    @MainActor
    func actFinishes(_ kind: MascotActKind) throws {
        let geometry = try #require(MoppoMascotGeometry.shared)
        let motion = MoppoMascotMotion(mode: .search)
        let renderer = ImageRenderer(content: Canvas { graphics, size in
            motion.draw(geometry, in: &graphics, size: size, fit: 0.25)
        }.frame(width: 120, height: 120))
        var date = Date(timeIntervalSinceReferenceDate: 0)
        motion.advance(to: date)
        motion.play(kind)
        #expect(motion.act != nil)
        for frame in 1...(60 * 30) where motion.act != nil {
            date += 1.0 / 60
            motion.advance(to: date)
            if frame.isMultiple(of: 15) { #expect(renderer.cgImage != nil) }
        }
        #expect(motion.act == nil)
    }
}
