import Foundation

/// Decides when Moppo plays an act. Most scans show one act.
///
/// - An act never starts in the first 5 seconds of an operation.
/// - Each operation has a 3 in 4 chance to get an act, and it gets one act at most.
/// - An act starts only after the beams have been off for a pause. The motion checks this.
/// - After an act ends, no other act starts in the app for 30 seconds.
/// - With Reduce Motion on, Moppo does not move, so no act plays.
struct MascotActScheduler {
    struct Choice {
        let kind: MascotActKind
        var weight = 1.0
        /// The act can start only after the operation has run this long.
        var minimumElapsed = 0.0
    }

    static let firstDelay = 5.0
    static let chance = 0.75
    static let gap = 30.0

    /// When the last act ended, for the whole app. A new view for the same scan can plan a second act,
    /// so this keeps the acts apart.
    @MainActor static var lastActEnd: Date?

    @MainActor static func allowsAct(at now: Date) -> Bool {
        guard let lastActEnd else { return true }
        return now.timeIntervalSince(lastActEnd) >= gap
    }

    /// The acts that fit each screen.
    static func choices(for mode: MoppoMascotView.Mode) -> [Choice] {
        switch mode {
        case .scanning:
            [Choice(kind: .magnifyingLens), Choice(kind: .radarPing), Choice(kind: .peek),
             Choice(kind: .barcode), Choice(kind: .binoculars), Choice(kind: .sauronEye, weight: 1.0 / 3)]
        case .photoScanning:
            [Choice(kind: .duplicatesSplit), Choice(kind: .yawn, minimumElapsed: 60), Choice(kind: .binoculars),
             Choice(kind: .magnifyingLens), Choice(kind: .peek)]
        case .fileDuplicateScanning:
            [Choice(kind: .duplicatesSplit), Choice(kind: .peek)]
        case .search, .destroying, .hourglass:
            []
        }
    }

    /// The latest time, in seconds of the operation, when an act can be planned.
    /// Many scans are short, so the act comes early. The photo duplicate scan is long,
    /// so its act can come later, which leaves room for the yawn.
    static func latestStart(for mode: MoppoMascotView.Mode) -> Double {
        mode == .photoScanning ? 90 : 12
    }

    /// Plans the act of one operation. Returns the operation time when the act can start, or nil for no act.
    static func plan(for mode: MoppoMascotView.Mode, roll: Double, delay: Double) -> Double? {
        guard !choices(for: mode).isEmpty, roll < chance else { return nil }
        return firstDelay + (latestStart(for: mode) - firstDelay) * min(1, max(0, delay))
    }

    /// Picks one of the acts that fit the time the operation has run. Returns nil when no act fits.
    static func pick(from choices: [Choice], elapsed: Double, roll: Double) -> MascotActKind? {
        let open = choices.filter { elapsed >= $0.minimumElapsed }
        let total = open.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var remaining = min(1, max(0, roll)) * total
        for choice in open {
            if remaining < choice.weight { return choice.kind }
            remaining -= choice.weight
        }
        return open.last?.kind
    }
}
