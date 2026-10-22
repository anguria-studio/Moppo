import SwiftUI

/// Shows Moppo at work. Moppo looks around, blinks, and turns between its left and right sides.
/// In the beam modes, Moppo also shoots rays from its eyes. The rays can extend past the frame of the view.
/// During some scans, Moppo can play a short act. `MascotActScheduler` sets when an act can start.
struct MoppoMascotView: View {
    enum Mode {
        /// Looks around without rays.
        case search
        /// Looks around and fires short sweeps of rays, during the Cleanup scan.
        case scanning
        /// Fires rays less often, during the photo duplicate scan.
        case photoScanning
        /// Fires rays less often, during the file duplicate scan.
        case fileDuplicateScanning
        /// Sweeps red rays in a half circle below itself while it turns from one side to the other.
        case destroying
        /// Turns into an hourglass, and the sand runs until the operation ends.
        case hourglass

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
    private let shape: MascotShape?

    /// While `shape` is set, Moppo holds that shape. When it changes to nil, Moppo turns back.
    init(mode: Mode = .search, shape: MascotShape? = nil) {
        _motion = State(initialValue: MoppoMascotMotion(mode: mode))
        self.shape = shape
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
            .onChange(of: shape, initial: true) { motion.requestedShape = shape }
        } else {
            PageStateSymbol(name: "hourglass")
        }
    }
}

/// A shape that a screen can ask Moppo to hold.
enum MascotShape: Equatable {
    /// The settings icon: three tracks with knobs that slide.
    case settings
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

#Preview("Moppo hourglass") {
    MoppoMascotView(mode: .hourglass)
        .frame(width: PageStateMetrics.iconAreaSize, height: PageStateMetrics.iconAreaSize)
        .foregroundStyle(.tertiary)
        .padding(40)
}
