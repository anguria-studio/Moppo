import Foundation
import Testing
@testable import MoppoCore

@Suite("Apple Intelligence growth")
struct AppleIntelligenceGrowthTests {
    private func snapshot(
        _ bytes: Int64,
        coverage: AppleIntelligenceStorage.Coverage = .complete,
        version: Int = 27
    ) -> StorageSnapshot {
        GrowthFixture.snapshot(
            used: 10_000_000_000 + bytes,
            named: [.macOSSystem: 10_000_000_000, .appleIntelligence: bytes],
            appleIntelligence: AppleIntelligenceStorage(
                allocatedBytes: bytes, coverage: coverage, macOSMajorVersion: version
            )
        )
    }

    @Test("Model increases and decreases use the existing threshold", arguments: [100_000_000, -100_000_000, 99_999_999])
    func significantChange(_ change: Int) throws {
        let baseline = snapshot(1_000_000_000)
        let latest = snapshot(1_000_000_000 + Int64(change))
        let report = try #require(StorageGrowth.compare(baseline: baseline, latest: latest).report)
        if abs(change) < StorageGrowth.defaultMinimumAttributionBytes {
            #expect(report.attributions.isEmpty)
        } else {
            let row = try #require(report.attributions.first)
            #expect(report.attributions.count == 1)
            #expect(row.segment == .appleIntelligence)
            #expect(row.deltaBytes == Int64(change))
            #expect(row.kind == (change > 0 ? .grew : .shrank))
            #expect(!row.isRevealable)
        }
        #expect(report.classDeltas.values.reduce(0, +) == report.usedDeltaBytes)
    }

    @Test("Incomplete model measurements cannot create a growth claim", arguments: [AppleIntelligenceStorage.Coverage.partial, .unavailable, .unsupported])
    func incompleteComparison(_ coverage: AppleIntelligenceStorage.Coverage) throws {
        let complete = snapshot(2_000_000_000)
        let incomplete = snapshot(0, coverage: coverage)
        for (baseline, latest) in [(complete, incomplete), (incomplete, complete)] {
            let report = try #require(StorageGrowth.compare(baseline: baseline, latest: latest).report)
            #expect(report.attributions.isEmpty)
            #expect(report.segmentDeltas[.appleIntelligence] == nil)
            #expect(report.classDeltas.values.reduce(0, +) == report.usedDeltaBytes)
        }
    }

    @Test("Models that appear or disappear still produce measured changes")
    func emptyStoreTransitions() throws {
        let empty = snapshot(0)
        let populated = snapshot(1_000_000_000)
        #expect(!empty.breakdown.legendEntries.contains { $0.id == .appleIntelligence })
        for (baseline, latest, change) in [(empty, populated, Int64(1_000_000_000)), (populated, empty, Int64(-1_000_000_000))] {
            let report = try #require(StorageGrowth.compare(baseline: baseline, latest: latest).report)
            let row = try #require(report.attributions.first)
            #expect(report.attributions.count == 1)
            #expect(row.segment == .appleIntelligence)
            #expect(row.deltaBytes == change)
            #expect(!row.isRevealable)
        }
    }

    @Test("A macOS version change needs a new comparison")
    func changedVersion() {
        #expect(StorageGrowth.compare(baseline: snapshot(1_000_000_000, version: 26), latest: snapshot(2_000_000_000))
            == .notComparable(reason: "The macOS version changed."))
    }

    @Test("Older history cannot invent model growth")
    func olderHistory() {
        let older = GrowthFixture.snapshot(used: 10_000_000_000, contract: GrowthFixture.contract(version: 1))
        #expect(StorageGrowth.compare(baseline: older, latest: snapshot(1_000_000_000))
            == .notComparable(reason: "The measurement rules changed."))
    }

    @Test("System root changes exclude the model bytes")
    func snapshotAvoidsDuplicateAttribution() throws {
        func capture(_ bytes: Int64) throws -> StorageSnapshot {
            let source = snapshot(bytes)
            let measurement = StorageMeasurement(
                home: URL(fileURLWithPath: GrowthFixture.home), volume: source.volume,
                breakdown: source.breakdown, rawSegments: source.rawSegments, homeTree: [:],
                rootMeasurements: [AppleIntelligenceStorage.systemRoot: SizeMeasurement(allocatedBytes: 500_000_000 + bytes)],
                nodeDepth: 4
            )
            return try #require(SnapshotCapture.snapshot(from: measurement, trigger: .manual, identity: { _ in nil }))
        }
        let before = try capture(1_000_000_000)
        let after = try capture(2_000_000_000)
        #expect(after.nodes.first?.allocatedBytes == 500_000_000)
        let report = try #require(StorageGrowth.compare(baseline: before, latest: after).report)
        #expect(report.attributions.count == 1)
        #expect(report.attributions.first?.segment == .appleIntelligence)
        #expect(report.attributions.first?.deltaBytes == 1_000_000_000)
    }

    @Test("The seven-day view can use new history after a rule change")
    func compatibleBaseline() throws {
        let older = GrowthFixture.snapshot(
            at: GrowthFixture.noon.addingTimeInterval(-8 * 86_400), used: 10_000_000_000,
            contract: GrowthFixture.contract(version: 1)
        )
        let baseline = GrowthFixture.snapshot(at: GrowthFixture.noon.addingTimeInterval(-3600), used: 10_000_000_000)
        let latest = GrowthFixture.snapshot(used: 11_000_000_000)
        let report = try #require(StorageGrowth.comparison(.sevenDays, in: [latest, baseline, older]).report)
        #expect(report.baseline.id == baseline.id)
        #expect(report.usedDeltaBytes == 1_000_000_000)
    }
}
