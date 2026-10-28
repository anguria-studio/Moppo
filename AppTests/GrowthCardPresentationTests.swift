import SwiftUI
import Testing
@testable import MoppoCore

@Suite("Storage comparison presentation", .serialized)
@MainActor
struct GrowthCardPresentationTests {
    @Test("The button and menu name Last 7 days by its real start until a week of history exists",
          arguments: [false, true])
    func sevenDayLabels(hasShortHistory: Bool) {
        let start = Date.now.addingTimeInterval(-2 * 60)
        let card = GrowthCard(presentation: .insufficientHistory, baseline: .sevenDays,
                              sevenDayStart: hasShortHistory ? start : nil)
        let day = Calendar.current.isDateInToday(start) ? start.formatted(date: .omitted, time: .shortened)
            : start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        #expect(card.label(for: .sevenDays) == (hasShortHistory ? "Since \(day)" : "Last 7 days"))
        #expect(card.label(for: .lastCleanup) == "Since last cleanup")
    }

    @Test("Comparison states fit both appearances", arguments: [false, true])
    func layouts(dark: Bool) async throws {
        let date = Date.now
        let report = GrowthCard.Report(
            baselineDate: date, usedDeltaBytes: 0, classDeltas: [:], attributions: []
        )
        let cards: [(String, GrowthCard)] = [
            ("first-run", GrowthCard(presentation: .insufficientHistory, baseline: .sevenDays)),
            ("first-saved", GrowthCard(
                presentation: .insufficientHistory, baseline: .sevenDays, hasMeasurement: true, lastScanAt: date
            )),
            ("report-menu", GrowthCard(
                presentation: .report(report), baseline: .lastCleanup, baselineOptions: [.lastCleanup, .sevenDays],
                sevenDayStart: date.addingTimeInterval(-3 * 24 * 60 * 60)
            )),
            ("report-single-option", GrowthCard(
                presentation: .report(report), baseline: .lastCleanup, baselineOptions: [.lastCleanup]
            )),
            ("not-comparable", GrowthCard(presentation: .notComparable, baseline: .sevenDays))
        ]
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
