import SwiftUI

/// Tuned in the Moppo motion prototype. Lengths use the glyph coordinates of the logo path.
/// Each act keeps its own values in its file.
enum MascotTuning {
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
    static let chargeTime = 0.3, fireTime = 0.21, sweepTime = 1.0, offTime = 0.25
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
    // A few seconds of rest follow each pass, so a long deletion does not fire again and again.
    static let destroySweepTime = 2.6, destroyRest = 3.0
    static let destroyAlternates = true
    // Glyph units. At the 88 pt size, 30 units is about 3 pt.
    static let destroyShake = 30.0
    // The rest between shots. Moppo searches without rays while it rests.
    // The Cleanup scan fires a little more often than the duplicate scans.
    static let scanRest = 5.5, duplicateScanRest = 8.0
    static let firstShotDelay = 1.6
    // An act starts only after the beams have been off for this long.
    static let pauseBeforeAct = 2.0
    // A deletion opens with the eyes already lit, so the rays fire almost at once.
    static let openingCharge = 0.12
    // The canvas is this many times the layout frame, so the beams and the acts have room.
    static let beamOverflow = 4.0
    // Glass in the lens and the hourglass
    static let glassTint = 0.09, glint = 0.75
}
