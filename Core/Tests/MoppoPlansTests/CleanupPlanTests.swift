import Foundation
import Testing
import MoppoCore
@testable import MoppoPlans

struct CleanupPlanTests {
    private struct Fixture {
        let root: URL
        let scans: ScanStore
        let plans: PlanStore
        let history: RemovalLog
        let configuration = ScanConfiguration(enabledCategories: [.aiTools], excludedPatterns: ["*.keychain-db"])

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-plans-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            scans = ScanStore(directory: root.appendingPathComponent("scans"))
            plans = PlanStore(directory: root.appendingPathComponent("plans"))
            history = RemovalLog(directory: root.appendingPathComponent("history"))
        }

        func file(_ name: String, bytes: Int64 = 100) throws -> FileEntry {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("contents".utf8).write(to: url)
            return FileEntry(url: url, kind: .file, allocatedBytes: bytes)
        }

        func results(_ entries: [FileEntry], at date: Date = Date()) -> ScanResults {
            ScanResults(categories: [.init(categoryID: .aiTools, totalBytes: 100, entries: entries)],
                        startedAt: date, finishedAt: date)
        }

        func report(_ entries: [FileEntry], at date: Date = Date()) throws -> ScanReport {
            let report = ScanReport(results: results(entries, at: date), configuration: configuration)
            try scans.save(report, now: date)
            return report
        }

        func service(_ entries: [FileEntry], settings: ScanConfiguration? = nil) -> CleanupPlanService {
            let settings = settings ?? configuration
            let results = results(entries)
            return CleanupPlanService(scans: scans, plans: plans, configuration: { settings }, scanner: { _ in results })
        }

        func create(_ report: ScanReport, using service: CleanupPlanService, ids: [String]? = nil,
                    now: Date = Date()) async throws -> PlanReview {
            try await service.create(scanId: report.scanId, scanRevision: RecordDigest.of(report),
                                     itemIds: ids ?? [report.items[0].id], now: now)
        }
    }

    @Test func proposalLifecycleAndRestrictedStorage() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("private-model")
        let report = try f.report([entry])
        let service = f.service([entry])
        let proposal = try await f.create(report, using: service)
        let review = try await service.inspect(proposal.plan.planId)
        #expect(review.plan.scanRevision == (try RecordDigest.of(report)))
        #expect(review.entries == [entry])
        #expect(review.expectedIdentities[entry.id] == FileIdentity.of(entry.url))
        #expect(review.items[0].id == report.items[0].id)
        #expect(review.scanAllocatedBytes == 100)
        #expect(review.verifiedRecoverableBytes == nil)
        #expect(try await service.revalidate(review).revision == review.revision)
        let file = f.plans.directory.appendingPathComponent(review.plan.planId + ".json")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: f.plans.directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(!String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("private-model"))
        #expect(throws: RecordStoreError.changed) {
            try f.plans.invalidate(review.plan.planId, revision: String(repeating: "0", count: 64))
        }
        try f.plans.invalidate(review.plan.planId, revision: review.revision)
        await #expect(throws: RecordStoreError.unavailable) { try await service.revalidate(review) }
        #expect(try Data(contentsOf: entry.url) == Data("contents".utf8))
    }

    @Test func invalidSelectionAndLegacyEvidence() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("model")
        let report = try f.report([entry])
        let service = f.service([entry])
        await #expect(throws: PlanValidationError.invalidSelection) {
            try await f.create(report, using: service, ids: [report.items[0].id, report.items[0].id])
        }
        await #expect(throws: PlanValidationError.unknownItem) {
            try await f.create(report, using: service, ids: ["item_" + UUID().uuidString])
        }
        await #expect(throws: PlanValidationError.scanChanged) {
            try await service.create(scanId: report.scanId, scanRevision: String(repeating: "0", count: 64), itemIds: [report.items[0].id])
        }
        let legacy = ScanReport(results: f.results([entry]))
        try f.scans.save(legacy)
        await #expect(throws: PlanValidationError.evidenceUnavailable) { try await f.create(legacy, using: service) }
    }

    @Test(arguments: [FileEntry.ProtectionReason.userData, .running, .inventory, .folderRemainder])
    func protectedChildrenStayProtected(reason: FileEntry.ProtectionReason) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var parent = try f.file("manifest")
        var child = try f.file("blob")
        child.protectionReason = reason
        parent.children = [child]
        parent.removesAsUnit = true
        let report = try f.report([parent])
        await #expect(throws: PlanValidationError.protectedItem) { try await f.create(report, using: f.service([parent])) }
    }

    @Test func exclusionsApplyAtCreationReviewAndInsideTrees() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("cache/file")
        let report = try f.report([entry])
        let review = try await f.create(report, using: f.service([entry]))
        var settings = f.configuration
        settings.excludedPaths = [entry.url.path]
        await #expect(throws: PlanValidationError.exclusionsChanged) {
            try await f.create(report, using: f.service([entry], settings: settings))
        }
        await #expect(throws: PlanValidationError.exclusionsChanged) {
            try await f.service([entry], settings: settings).revalidate(review)
        }
        var disabled = f.configuration
        disabled.enabledCategories = []
        await #expect(throws: PlanValidationError.categoryDisabled) {
            try await f.service([entry], settings: disabled).inspect(review.plan.planId)
        }
        _ = try f.file("cache/credentials.keychain-db")
        let folder = FileEntry(url: entry.url.deletingLastPathComponent(), kind: .folder, allocatedBytes: 200)
        let nestedReport = try f.report([folder])
        await #expect(throws: PlanValidationError.excludedItem) {
            try await f.create(nestedReport, using: f.service([folder]))
        }
        let direct = ScanReport(results: f.results([entry]), configuration: settings)
        try f.scans.save(direct)
        await #expect(throws: PlanValidationError.excludedItem) {
            try await f.create(direct, using: f.service([entry], settings: settings))
        }
    }

    enum TargetChange: CaseIterable { case replaced, modified, missing, symlink }
    @Test(arguments: TargetChange.allCases)
    func changedTargetsFailReview(change: TargetChange) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("target")
        let report = try f.report([entry])
        let review = try await f.create(report, using: f.service([entry]))
        let expected: PlanValidationError
        switch change {
        case .replaced:
            try FileManager.default.moveItem(at: entry.url, to: f.root.appendingPathComponent("original"))
            try Data("contents".utf8).write(to: entry.url)
            expected = .changedTarget
        case .modified:
            try Data("modified".utf8).write(to: entry.url)
            expected = .changedTarget
        case .missing:
            try FileManager.default.removeItem(at: entry.url)
            expected = .missingItem
        case .symlink:
            let destination = try f.file("destination")
            try FileManager.default.removeItem(at: entry.url)
            try FileManager.default.createSymbolicLink(at: entry.url, withDestinationURL: destination.url)
            expected = .unsupportedTarget
        }
        await #expect(throws: expected) {
            try await f.service(change == .missing ? [] : [entry]).revalidate(review)
        }
    }

    @Test func overlapAndSharedModelStorage() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let child = try f.file("cache/child", bytes: 100)
        let folder = FileEntry(url: child.url.deletingLastPathComponent(), kind: .folder, allocatedBytes: 100, children: [child])
        let report = try f.report([folder])
        await #expect(throws: PlanValidationError.overlappingItems) {
            try await f.create(report, using: f.service([folder]), ids: report.items.map(\.id))
        }
        let parentReview = try await f.create(report, using: f.service([folder]))
        #expect(parentReview.scanAllocatedBytes == nil)
        var first = try f.file("first", bytes: 10)
        var second = try f.file("second", bytes: 20)
        let blob = try f.file("shared-blob", bytes: 1000)
        first.children = [blob]
        first.removesAsUnit = true
        second.children = [blob]
        second.removesAsUnit = true
        let shared = try f.report([first, second])
        let ids = shared.items.filter { $0.parentId == nil }.map(\.id)
        let proposal = try await f.create(shared, using: f.service([first, second]), ids: ids)
        #expect(proposal.scanAllocatedBytes == 1030)
        await #expect(throws: PlanValidationError.invalidSelection) {
            try await f.create(shared, using: f.service([first, second]), ids: [shared.items[1].id])
        }
        // Another model now owns the blob. The fresh inventory must invalidate the proposal.
        first.children = []
        await #expect(throws: PlanValidationError.changedTarget) {
            try await f.service([first, second]).revalidate(proposal)
        }
    }

    @Test func duplicateTargetsAcrossCategoriesFailReview() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("target")
        let settings = ScanConfiguration(enabledCategories: [.aiTools, .xcode])
        let results = ScanResults(categories: [
            .init(categoryID: .aiTools, totalBytes: 100, entries: [entry]),
            .init(categoryID: .xcode, totalBytes: 100, entries: [entry])
        ], startedAt: Date(), finishedAt: Date())
        let report = ScanReport(results: results, configuration: settings)
        try f.scans.save(report)
        let service = CleanupPlanService(scans: f.scans, plans: f.plans, configuration: { settings }, scanner: { _ in results })
        await #expect(throws: PlanValidationError.overlappingItems) {
            try await f.create(report, using: service, ids: report.items.map(\.id))
        }
    }

    @Test func hardLinksCountOnce() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try f.file("first", bytes: 4096)
        let link = f.root.appendingPathComponent("second")
        try FileManager.default.linkItem(at: first.url, to: link)
        let second = FileEntry(url: link, kind: .file, allocatedBytes: 4096)
        let report = try f.report([first, second])
        let review = try await f.create(report, using: f.service([first, second]), ids: report.items.map(\.id))
        #expect(review.scanAllocatedBytes == 4096)
    }

    @Test func diskTamperingCannotReplaceReviewedSelection() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let first = try f.file("first")
        let second = try f.file("second")
        let report = try f.report([first, second])
        let service = f.service([first, second])
        let review = try await f.create(report, using: service)
        let file = f.plans.directory.appendingPathComponent(review.plan.planId + ".json")
        var object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        object["item_ids"] = [report.items[1].id]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        await #expect(throws: PlanValidationError.planChanged) { try await service.revalidate(review) }
        object["command"] = "rm -rf /"
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(throws: RecordStoreError.invalidReport) { try f.plans.load(review.plan.planId) }
        object.removeValue(forKey: "command")
        object["item_ids"] = [report.items[0].id, report.items[0].id]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(throws: RecordStoreError.invalidReport) { try f.plans.load(review.plan.planId) }
        object["schema_version"] = 99
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        #expect(throws: RecordStoreError.incompatibleSchema) { try f.plans.load(review.plan.planId) }
        var changed = report
        changed.items[0].path = "/arbitrary-target"
        let scanFile = f.scans.directory.appendingPathComponent(report.scanId + ".json")
        try ScanReport.encoder().encode(changed).write(to: scanFile)
        await #expect(throws: PlanValidationError.scanChanged) { try await f.create(report, using: service) }
        await #expect(throws: PlanValidationError.missingItem) { try await f.create(changed, using: service) }
        #expect(try Data(contentsOf: first.url) == Data("contents".utf8))
    }

    @Test func retentionExpiryAndImmutableIdentifiers() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("target")
        let now = Date()
        let report = try f.report([entry], at: now)
        let revision = try RecordDigest.of(report)
        var saved: [CleanupPlan] = []
        for index in 0..<22 {
            let date = now.addingTimeInterval(Double(index))
            let plan = CleanupPlan(scan: report, revision: revision, itemIds: [report.items[0].id], now: date)
            try f.plans.save(plan, now: date)
            saved.append(plan)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.plans.directory.path).count == 20)
        #expect(throws: RecordStoreError.unavailable) { try f.plans.load(saved[0].planId, now: now.addingTimeInterval(22)) }
        let last = try #require(saved.last)
        #expect(throws: RecordStoreError.writeFailed) { try f.plans.save(last, now: now.addingTimeInterval(22)) }
        #expect(throws: RecordStoreError.expired) { try f.plans.load(last.planId, now: now.addingTimeInterval(86423)) }
        #expect(throws: RecordStoreError.expired) { try f.scans.load(report.scanId, now: now.addingTimeInterval(7 * 86400 + 1)) }
    }

    @Test func invalidationDuringReviewAndCancellation() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("target")
        let report = try f.report([entry])
        let review = try await f.create(report, using: f.service([entry]))
        let plans = f.plans
        let results = f.results([entry])
        let settings = f.configuration
        let service = CleanupPlanService(scans: f.scans, plans: plans, configuration: { settings }, scanner: { _ in
            try plans.invalidate(review.plan.planId, revision: review.revision)
            return results
        })
        await #expect(throws: RecordStoreError.unavailable) { try await service.inspect(review.plan.planId) }
        let cancelled = CleanupPlanService(scans: f.scans, plans: plans, configuration: { settings }, scanner: { _ in
            throw CancellationError()
        })
        await #expect(throws: CancellationError.self) { try await f.create(report, using: cancelled) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: plans.directory.path).isEmpty)
    }

    @Test func handoffRejectsPathsCommandsAndUnknownFields() throws {
        let handoff = try PlanHandoff(planId: "plan_" + UUID().uuidString.lowercased(), revision: String(repeating: "a", count: 64))
        #expect(try PlanHandoff(url: handoff.url) == handoff)
        #expect(try PlanHandoff(launchArguments: handoff.launchArguments) == handoff)
        #expect(throws: RecordStoreError.invalidId) { try PlanHandoff(launchArguments: handoff.launchArguments + ["--yes"]) }
        for value in [handoff.url.absoluteString + "&command=rm", handoff.url.absoluteString + "&plan=other",
                      handoff.url.absoluteString + "#fragment", "moppo://plan-review/file", "file:///tmp/plan.json"] {
            #expect(throws: (any Error).self) { try PlanHandoff(url: URL(string: value)!) }
        }
    }

    @Test func executionRequiresConfirmationAndRejectsConcurrentOrStalePlans() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("target")
        let review = try await f.create(f.report([entry]), using: f.service([entry]))
        let outcomes = PlanOutcomeStore(directory: f.root.appendingPathComponent("outcomes"))
        let lock = f.root.appendingPathComponent("execution")
        let executor = PlanExecutionService(validation: f.service([entry]), outcomes: outcomes, lockDirectory: lock, history: f.history,
            remove: { _, _, _ in Issue.record("An unconfirmed or stale plan reached removal."); return CleanupOutcome() })
        await #expect(throws: PlanExecutionError.confirmationRequired) {
            try await executor.execute(review, confirmed: false, permanentItemIds: [])
        }
        let lease = try PlanExecutionLease(directory: lock)
        await #expect(throws: PlanExecutionError.busy) {
            try await executor.execute(review, confirmed: true, permanentItemIds: [])
        }
        withExtendedLifetime(lease) {}
        #expect(try outcomes.outcomes(planId: review.plan.planId).isEmpty)
        try Data("changed".utf8).write(to: entry.url)
        let staleExecutor = PlanExecutionService(validation: f.service([entry]), outcomes: outcomes,
            lockDirectory: f.root.appendingPathComponent("another-lock"), history: f.history, remove: { _, _, _ in
                Issue.record("A changed target reached removal."); return CleanupOutcome()
            })
        await #expect(throws: PlanValidationError.changedTarget) {
            try await staleExecutor.execute(review, confirmed: true, permanentItemIds: [])
        }
    }

    @Test func executionRechecksRemainingItemsAndPersistsPrivateOutcomes() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entries = try [f.file("private-first"), f.file("private-second")]
        let service = f.service(entries)
        let report = try f.report(entries)
        let review = try await f.create(report, using: service, ids: report.items.map(\.id))
        let outcomes = PlanOutcomeStore(directory: f.root.appendingPathComponent("outcomes"))
        let executor = PlanExecutionService(validation: service, outcomes: outcomes,
            lockDirectory: f.root.appendingPathComponent("execution"), history: f.history, remove: { entry, identities, commands in
                #expect(identities[entry.id] == FileIdentity.of(entry.url))
                #expect(commands.isEmpty)
                try FileManager.default.removeItem(at: entry.url)
                return CleanupOutcome(removedBytes: 4096, removedCount: 1, trashedCount: 1)
            })
        let result = try await executor.execute(review, confirmed: true, permanentItemIds: [])
        #expect(result.status == .completed)
        #expect(result.items.count == 2)
        #expect(result.items.allSatisfy { $0.status == .trashed })
        let records = try outcomes.outcomes(planId: review.plan.planId)
        #expect(records.count == 1)
        #expect(records[0].status == .completed)
        let json = String(decoding: try ScanReport.encoder().encode(records), as: UTF8.self)
        #expect(!json.contains("private-first"))
        #expect(!json.contains(f.root.path))
        await #expect(throws: PlanExecutionError.alreadyAttempted) {
            try await executor.execute(review, confirmed: true, permanentItemIds: [])
        }
        try f.plans.invalidate(review.plan.planId, revision: review.revision)
        #expect(try outcomes.outcomes(planId: review.plan.planId).count == 1)
    }

    @Test func removalThrowHasUnknownOutcomeAndFinalWriteFailureRetainsStart() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("target")
        let service = f.service([entry])
        let report = try f.report([entry])
        let review = try await f.create(report, using: service)
        let outcomes = PlanOutcomeStore(directory: f.root.appendingPathComponent("outcomes"))
        let executor = PlanExecutionService(validation: service, outcomes: outcomes,
            lockDirectory: f.root.appendingPathComponent("execution"), history: f.history, remove: { _, _, _ in throw CancellationError() })
        let result = try await executor.execute(review, confirmed: true, permanentItemIds: [])
        #expect(result.status == .partial)
        #expect(result.items[0].status == .unknown)
        #expect(result.items[0].reason == "outcome_unknown")
        let second = try await f.create(report, using: service)
        let broken = PlanExecutionService(validation: service, outcomes: outcomes,
            lockDirectory: f.root.appendingPathComponent("execution"), history: f.history, remove: { _, _, _ in
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outcomes.directory.path)
                return CleanupOutcome(removedCount: 1, trashedCount: 1)
            })
        await #expect(throws: RecordStoreError.writeFailed) {
            try await broken.execute(second, confirmed: true, permanentItemIds: [])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outcomes.directory.path)
        #expect(try outcomes.outcomes(planId: second.plan.planId).first?.status == .started)
    }

    @Test func cancellationFinishesCurrentItemAndStopsRemainingItems() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entries = try [f.file("first"), f.file("second")]
        let report = try f.report(entries)
        let review = try await f.create(report, using: f.service(entries), ids: report.items.map(\.id))
        let started = AsyncStream<Void>.makeStream()
        let finish = AsyncStream<Void>.makeStream()
        let executor = PlanExecutionService(validation: f.service(entries),
            outcomes: PlanOutcomeStore(directory: f.root.appendingPathComponent("outcomes")),
            lockDirectory: f.root.appendingPathComponent("execution"), history: f.history, remove: { _, _, _ in
                started.continuation.yield(())
                for await _ in finish.stream { break }
                #expect(!Task.isCancelled)
                return CleanupOutcome(removedCount: 1, trashedCount: 1)
            })
        let task = Task { try await executor.execute(review, confirmed: true, permanentItemIds: []) }
        for await _ in started.stream { break }
        task.cancel()
        finish.continuation.yield(())
        finish.continuation.finish()
        let result = try await task.value
        #expect(result.status == .partial)
        #expect(result.items.map(\.status) == [.trashed, .cancelled])
        started.continuation.finish()
    }


    @Test func permanentExecutionRequiresSeparateConsentAndExactReviewedCommand() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let cache = f.root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let tool = try f.file("tool").url
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let original = FileEntry(url: cache, kind: .cache, allocatedBytes: 0,
            removalMethod: .toolCommand(.goModuleCache(at: cache, executable: tool.path)))
        let report = try f.report([original])
        let review = try await f.create(report, using: f.service([original]))
        let outcomes = PlanOutcomeStore(directory: f.root.appendingPathComponent("outcomes"))
        let executor = PlanExecutionService(validation: f.service([original]), outcomes: outcomes,
            lockDirectory: f.root.appendingPathComponent("execution"), history: f.history, remove: { _, _, _ in
                Issue.record("Permanent removal did not have separate consent."); return CleanupOutcome()
            })
        await #expect(throws: PlanExecutionError.confirmationRequired) {
            try await executor.execute(review, confirmed: true, permanentItemIds: [])
        }
        try Data("replacement tool".utf8).write(to: tool)
        let changed = FileEntry(url: cache, kind: .cache, allocatedBytes: 0,
            removalMethod: .toolCommand(.goModuleCache(at: cache, executable: tool.path)))
        let replacedTool = PlanExecutionService(validation: f.service([changed]), outcomes: outcomes,
            lockDirectory: f.root.appendingPathComponent("execution"), history: f.history, remove: { _, _, _ in
                Issue.record("The removal tool changed after review."); return CleanupOutcome()
            })
        let result = try await replacedTool.execute(review, confirmed: true, permanentItemIds: review.permanentItemIds)
        #expect(result.items.first?.status == .skipped)
        let log = f.history
        #expect(log.recentEntries().first?.disposition == .skipped)
        let history = CleanupHistoryService(log: log).summary()
        #expect(history.items.first?.state == .skipped)
        #expect(history.removedCount == 0)
        #expect(history.failedCount == 0)
        #expect(result.items.first?.reason == "changed_target")
    }


    @Test func specializedPermanentHistoryRequiresItsExistingAppReview() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        var entry = try f.file("history")
        entry.codexSession = CodexSessionReview(codexHome: f.root, threadID: "session", members: [])
        let review = try await f.create(f.report([entry]), using: f.service([entry]))
        #expect(throws: PlanValidationError.unsupportedTarget) { try PlanExecutionService.checkSupported(review) }
    }

    @Test func directoryContentChangesKeepPlanAndShowFreshSizes() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let cache = f.root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let original = FileEntry(url: cache, kind: .cache, allocatedBytes: 100)
        let review = try await f.create(f.report([original]), using: f.service([original]))
        try Data("new cache file".utf8).write(to: cache.appendingPathComponent("added"))
        let grown = FileEntry(url: cache, kind: .cache, allocatedBytes: 300)
        let current = try await f.service([grown]).revalidate(review)
        #expect(current.items[0].id == review.items[0].id)
        #expect(current.items[0].allocatedBytes == 300)
        #expect(current.scanAllocatedBytes == 300)
    }

    @Test func remainingItemsAreRecheckedWithoutAnotherScan() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entries = try [f.file("first"), f.file("second")]
        let report = try f.report(entries)
        let review = try await f.create(report, using: f.service(entries), ids: report.items.map(\.id))
        let scans = ScanCounter()
        let results = f.results(entries)
        let settings = f.configuration
        let counted = CleanupPlanService(scans: f.scans, plans: f.plans, configuration: { settings }, scanner: { _ in
            scans.increment()
            return results
        })
        let executor = PlanExecutionService(validation: counted,
            outcomes: PlanOutcomeStore(directory: f.root.appendingPathComponent("outcomes")),
            lockDirectory: f.root.appendingPathComponent("execution"), history: f.history, remove: { entry, _, _ in
                // Plans sort items by identifier. Change whichever item is still waiting.
                let waiting = entries.first { $0.url != entry.url }!
                try Data("changed".utf8).write(to: waiting.url)
                return CleanupOutcome(removedCount: 1, trashedCount: 1)
            })
        let result = try await executor.execute(review, confirmed: true, permanentItemIds: [])
        #expect(scans.count == 1)
        #expect(result.items.map(\.status) == [.trashed, .skipped])
        #expect(result.items[1].reason == "changed_target")
    }

    @Test func partialCategoriesAllowFullyReadableItems() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let cache = f.root.appendingPathComponent("readable")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: cache.appendingPathComponent("file"))
        let locked = f.root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.appendingPathComponent("inner").path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.appendingPathComponent("inner").path) }
        let entries = [FileEntry(url: cache, kind: .cache, allocatedBytes: 100),
                       FileEntry(url: locked, kind: .cache, allocatedBytes: 100)]
        // Another folder in the category was unreadable, so the scan marks every item partial.
        let results = ScanResults(categories: [.init(categoryID: .aiTools, totalBytes: 200, entries: entries, unreadableCount: 1)],
                                  startedAt: Date(), finishedAt: Date())
        let report = ScanReport(results: results, configuration: f.configuration)
        try f.scans.save(report)
        #expect(report.items.allSatisfy { $0.measurementStatus == .partial })
        let settings = f.configuration
        let service = CleanupPlanService(scans: f.scans, plans: f.plans, configuration: { settings }, scanner: { _ in results })
        let review = try await f.create(report, using: service, ids: [report.items[0].id])
        #expect(review.items[0].measurementStatus == .complete)
        await #expect(throws: PlanValidationError.incompleteScan) {
            try await f.create(report, using: service, ids: [report.items[1].id])
        }
    }

    @Test func scansThatPlansUseSurvivePruning() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let entry = try f.file("target")
        let now = Date()
        let report = try f.report([entry], at: now.addingTimeInterval(-60))
        _ = try await f.create(report, using: f.service([entry]), now: now)
        for index in 0..<11 {
            let newer = ScanReport(results: f.results([entry], at: now.addingTimeInterval(Double(index))),
                                   configuration: f.configuration)
            try f.scans.save(newer, now: now, keeping: f.plans.referencedScanIds(now: now))
        }
        #expect(try f.scans.load(report.scanId, now: now).scanId == report.scanId)
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.scans.directory.path).count == 11)
    }
}

private final class ScanCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}
