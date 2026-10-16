import SwiftUI
import Testing
@testable import MoppoCore

@Suite("Cleanup baseline presentation", .serialized)
@MainActor
struct GrowthCardPresentationTests {
    @Test("Cleanup guidance and actions fit both appearances", arguments: [false, true])
    func layouts(dark: Bool) async throws {
        for width in [788.0, 908.0] {
            let cards = VStack(spacing: 16) {
                ForEach(DashboardModel.CleanupMeasurementState.allCases, id: \.self) { state in
                    GrowthCard(
                        presentation: .insufficientHistory,
                        baseline: .sevenDays,
                        canCompareSinceCleanup: false,
                        cleanupMeasurementState: state
                    )
                }
                GrowthCard(
                    presentation: .report(.init(
                        baselineDate: .distantPast, usedDeltaBytes: 0, classDeltas: [:], attributions: []
                    )),
                    baseline: .lastCleanup,
                    cleanupBaselineDate: .distantPast
                )
                GrowthCard(
                    presentation: .insufficientHistory,
                    baseline: .lastCleanup,
                    cleanupMeasurementState: .failed,
                    cleanupBaselineDate: .distantPast
                )
            }
            .padding(24)
            .background(Token.pageBackground)
            let output = URL(fileURLWithPath: "/tmp/moppo-145-growth-\(Int(width))-\(dark ? "dark" : "light").png")
            let size = try await renderTestView(cards, width: width, dark: dark, output: output)
            #expect(abs(size.width - width) < 0.5)
            #expect(size.height < 2000)
        }
    }
}
