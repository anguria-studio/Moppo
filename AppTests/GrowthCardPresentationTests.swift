import SwiftUI
import Testing
@testable import MoppoCore

@Suite("Storage comparison presentation", .serialized)
@MainActor
struct GrowthCardPresentationTests {
    @Test("Comparison states and recovery actions fit both appearances", arguments: [false, true])
    func layouts(dark: Bool) async throws {
        let date = Date.now
        let measurement = GrowthCard.Measurement(date: date, usedBytes: 218_840_000_000)
        let report = GrowthCard.Report(
            baselineDate: date, usedDeltaBytes: 0, classDeltas: [:], attributions: []
        )
        var cards: [(String, GrowthCard)] = [
            ("first-run", GrowthCard(
                presentation: .insufficientHistory, baseline: .sevenDays, canCompareSinceCleanup: false
            )),
            ("first-saved", GrowthCard(
                presentation: .insufficientHistory, baseline: .sevenDays,
                latestMeasurement: measurement, lastScanAt: date, canCompareSinceCleanup: false
            )),
            ("cleanup-saved", GrowthCard(
                presentation: .report(report), baseline: .lastCleanup,
                latestMeasurement: measurement, cleanupBaselineDate: date
            )),
            ("cleanup-refreshing", GrowthCard(
                presentation: .report(report), baseline: .lastCleanup,
                latestMeasurement: measurement, cleanupBaselineDate: date, isRefreshing: true
            )),
            ("report", GrowthCard(
                presentation: .report(report), baseline: .lastCleanup,
                cleanupBaselineDate: date, hasLaterCleanupMeasurement: true
            )),
            ("not-comparable", GrowthCard(presentation: .notComparable, baseline: .sevenDays))
        ]
        cards += DashboardModel.CleanupMeasurementState.allCases.map { state in
            (state.rawValue, GrowthCard(
                presentation: .insufficientHistory, baseline: .sevenDays,
                canCompareSinceCleanup: false, cleanupMeasurementState: state
            ))
        }
        cards.append(("failed-with-baseline", GrowthCard(
            presentation: .insufficientHistory, baseline: .lastCleanup,
            cleanupMeasurementState: .failed, cleanupBaselineDate: date
        )))
        for width in [500.0, 788.0, 908.0] {
            for (name, card) in cards {
                let size = try await renderTestView(
                    card.padding(24).background(Token.pageBackground), width: width, dark: dark
                )
                #expect(abs(size.width - width) < 0.5, "\(name) at \(Int(width)) points")
                #expect(size.height < 500, "\(name) at \(Int(width)) points")
            }
        }
    }
}
