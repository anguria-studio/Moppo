import Darwin
import Foundation
import Testing
import MoppoPlans
import MoppoCore
import MoppoScan
@testable import MoppoCLI

struct CLITests {
    private func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("moppo-cli-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func results(at date: Date = Date(), unreadable: Int = 0) -> ScanResults {
        let children = (0..<3).map { index in
            FileEntry(url: URL(fileURLWithPath: "/private/secret/project/child\(index)"),
                      kind: .cache, allocatedBytes: 100, isRegenerable: true)
        }
        let entry = FileEntry(url: URL(fileURLWithPath: "/private/secret/project"), kind: .folder,
                              allocatedBytes: 400, protectionReason: .userData,
                              protectionExplanation: "Keep /private/secret/project.", children: children)
        return ScanResults(categories: [.init(categoryID: .xcode, totalBytes: 400, entries: [entry],
                                              unreadableCount: unreadable)],
                           startedAt: date, finishedAt: date)
    }

    private func object(_ result: CLIResult) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: result.output) as? [String: Any])
    }

    @Test func scanPagesAndDisclosure() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(directory: root.appendingPathComponent("reports"))
        let fixture = results(unreadable: 1)
        let scan = await CommandLineInterface.run(arguments: ["scan", "--json"], store: store,
            configuration: { ScanConfiguration(enabledCategories: [.xcode]) },
            scanner: { configuration, _ in
                #expect(configuration.enabledCategories == [.xcode])
                return fixture
            })
        #expect(scan.exitCode == 2)
        let summary = try object(scan)
        #expect(summary["schema_version"] as? Int == 1)
        #expect(summary["status"] as? String == "partial")
        #expect((summary["items"] as? [Any])?.isEmpty == true)
        let scanId = try #require(summary["scan_id"] as? String)
        let page = await CommandLineInterface.run(
            arguments: ["items", "--scan", scanId, "--limit", "2", "--json"], store: store)
        #expect(page.exitCode == 0)
        let data = try object(page)
        #expect(data["next_offset"] as? Int == 2)
        let rows = try #require(data["items"] as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows[0]["eligibility"] as? String == "protected")
        #expect(rows[0]["measurement_status"] as? String == "partial")
        #expect(!String(decoding: page.output, as: UTF8.self).contains("secret"))
        let itemId = try #require(rows[0]["id"] as? String)
        let detail = await CommandLineInterface.run(
            arguments: ["explain", "--scan", scanId, "--item", itemId, "--json", "--include-paths"], store: store)
        #expect(detail.exitCode == 0)
        #expect(String(decoding: detail.output, as: UTF8.self).contains("/private/secret/project"))
        let stored = try store.load(scanId)
        #expect(stored.items[1].parentId == stored.items[0].id)
        #expect(stored.items[0].id != fixture.categories[0].entries[0].id)
        let last = await CommandLineInterface.run(
            arguments: ["items", "--scan", scanId, "--offset", "3", "--limit", "2", "--json"], store: store)
        #expect(try object(last)["next_offset"] is NSNull)
    }

    @Test func planCommandsBindRevisionsAndKeepMetadataPrivate() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("private-model")
        try Data("keep".utf8).write(to: target)
        let entry = FileEntry(url: target, kind: .file, allocatedBytes: 4096)
        let results = ScanResults(categories: [.init(categoryID: .aiTools, totalBytes: 4096, entries: [entry])],
                                  startedAt: Date(), finishedAt: Date())
        let scans = ScanStore(directory: root.appendingPathComponent("scans"))
        let plans = PlanStore(directory: root.appendingPathComponent("plans"))
        func run(_ arguments: [String]) async -> CLIResult {
            await CommandLineInterface.run(arguments: arguments + ["--json"], store: scans, planStore: plans,
                configuration: { ScanConfiguration(enabledCategories: [.aiTools]) }, scanner: { _, _ in results })
        }
        let scan = try object(await run(["scan"]))
        let scanId = try #require(scan["scan_id"] as? String)
        let revision = try #require(scan["revision"] as? String)
        let itemId = try scans.load(scanId).items[0].id
        let created = await run(["plan", "create", "--scan", scanId, "--revision", revision, "--items", itemId])
        #expect(created.exitCode == 0)
        let data = try object(created)
        let planId = try #require(data["plan_id"] as? String)
        let planRevision = try #require(data["revision"] as? String)
        #expect(data["status"] as? String == "review_required")
        #expect(data["recoverable_space"] as? String == "unverified")
        #expect(!String(decoding: created.output, as: UTF8.self).contains("private-model"))
        #expect(!String(decoding: created.output, as: UTF8.self).contains("evidence"))
        let inspect = await run(["plan", "inspect", "--plan", planId, "--include-paths"])
        #expect(inspect.exitCode == 0)
        #expect(String(decoding: inspect.output, as: UTF8.self).contains("private-model"))
        #expect(!String(decoding: inspect.output, as: UTF8.self).contains("evidence"))
        let outcomes = PlanOutcomeStore(directory: root.appendingPathComponent("outcomes"))
        let launched = await CommandLineInterface.run(arguments: ["plan", "review", "--plan", planId, "--app", "--json"],
            store: scans, planStore: plans, appLauncher: { handoff in
                #expect(handoff.planId == planId)
                #expect(handoff.revision == planRevision)
            }, scanner: { _, _ in Issue.record("CLI app review must not start a scan."); throw CancellationError() })
        #expect(launched.exitCode == 0)
        #expect(try object(launched)["status"] as? String == "app_requested")
        let failedLaunch = await CommandLineInterface.run(arguments: ["plan", "review", "--plan", planId, "--app", "--json"],
            store: scans, planStore: plans, appLauncher: { _ in throw CLIError(69, "app_unavailable", "Moppo is not installed.") })
        #expect(failedLaunch.exitCode == 69)
        let handoff = try PlanHandoff(planId: planId, revision: planRevision)
        _ = try outcomes.recordReview(handoff, status: .cancelled, reason: "review_cancelled")
        let invalidated = await run(["plan", "invalidate", "--plan", planId, "--revision", planRevision])
        #expect(invalidated.exitCode == 0)
        #expect(try object(invalidated)["status"] as? String == "invalidated")
        #expect(await run(["plan", "inspect", "--plan", planId]).exitCode == 66)
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        let savedOutcome = await CommandLineInterface.run(arguments: ["plan", "outcomes", "--plan", planId, "--json"],
            store: scans, planStore: plans, outcomeStore: outcomes)
        #expect(savedOutcome.exitCode == 0)
        #expect(try object(savedOutcome)["status"] as? String == "outcomes_available")
        #expect(String(decoding: savedOutcome.output, as: UTF8.self).contains("review_cancelled"))
        #expect(!String(decoding: savedOutcome.output, as: UTF8.self).contains("private-model"))
        let unavailable = await CommandLineInterface.run(arguments: ["plan", "review", "--plan", planId, "--app", "--json"],
            store: scans, planStore: plans, appLauncher: { _ in Issue.record("An unavailable plan reached the app launcher.") })
        #expect(unavailable.exitCode == 66)
    }


    private final class Prompts: @unchecked Sendable {
        private let lock = NSLock()
        private var reasons: [String] = []
        func record(_ reason: String) { lock.withLock { reasons.append(reason) } }
        var all: [String] { lock.withLock { reasons } }
    }

    @Test(arguments: ["wrong-revision", "stale", "busy", "success", "partial", "unknown", "write-failure",
                      "permanent-reject", "permanent-unavailable", "permanent-cancel", "permanent-success"])
    func planRemoval(scenario: String) async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("private-model")
        let permanent = scenario.hasPrefix("permanent-")
        var entry: FileEntry
        if permanent {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            let tool = root.appendingPathComponent("tool")
            try Data("tool fixture".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
            entry = FileEntry(url: target, kind: .cache, allocatedBytes: 0,
                removalMethod: .toolCommand(.goModuleCache(at: target, executable: tool.path)))
        } else {
            try Data("keep".utf8).write(to: target)
            entry = FileEntry(url: target, kind: .file, allocatedBytes: 4096)
        }
        let fixture = ScanResults(categories: [.init(categoryID: .aiTools, totalBytes: 4096, entries: [entry])],
                                  startedAt: Date(), finishedAt: Date())
        let settings = ScanConfiguration(enabledCategories: [.aiTools])
        let scans = ScanStore(directory: root.appendingPathComponent("scans"))
        let plans = PlanStore(directory: root.appendingPathComponent("plans"))
        let outcomes = PlanOutcomeStore(directory: root.appendingPathComponent("outcomes"))
        let lock = root.appendingPathComponent("execution")
        let report = ScanReport(results: fixture, configuration: settings)
        try scans.save(report)
        let validation = CleanupPlanService(scans: scans, plans: plans, configuration: { settings }, scanner: { _ in fixture })
        let review = try await validation.create(scanId: report.scanId, scanRevision: RecordDigest.of(report), itemIds: [report.items[0].id])
        if scenario == "stale" { try Data("changed target contents".utf8).write(to: target) }
        let revision = scenario == "wrong-revision" ? String(repeating: "0", count: 64) : review.revision
        if permanent {
            func inspect(_ extra: [String]) async throws -> [String: Any] {
                let result = await CommandLineInterface.run(
                    arguments: ["plan", "inspect", "--plan", review.plan.planId, "--json"] + extra,
                    store: scans, planStore: plans, configuration: { settings }, scanner: { _, _ in fixture })
                return try #require((try object(result)["permanent_commands"] as? [[String: Any]])?.first)
            }
            let hidden = try await inspect([])
            #expect(hidden["tool"] as? String == "tool")
            #expect(hidden["command"] == nil)
            #expect((try await inspect(["--include-paths"])["command"] as? String)?.contains("-modcache") == true)
        }
        let prompts = Prompts()
        let held = scenario == "busy" ? try PlanExecutionLease(directory: lock) : nil
        defer { withExtendedLifetime(held) {} }
        let result = await CommandLineInterface.run(
            arguments: ["plan", "remove", "--plan", review.plan.planId, "--revision", revision, "--json"],
            store: scans, planStore: plans, outcomeStore: outcomes,
            appLauncher: { _ in Issue.record("Plan removal opened the app.") },
            authenticate: { reason in
                prompts.record(reason)
                switch scenario {
                case "permanent-reject": return false
                case "permanent-unavailable": throw OwnerAuthentication.unavailable
                case "permanent-cancel": throw CancellationError()
                default: return true
                }
            }, planExecution: { service, outcomes in
                PlanExecutionService(validation: service, outcomes: outcomes, lockDirectory: lock,
                    history: RemovalLog(directory: root.appendingPathComponent("history")), remove: { current, identities, commands in
                        #expect(["success", "partial", "unknown", "write-failure", "permanent-success"].contains(scenario))
                        #expect(identities[current.id] == FileIdentity.of(target))
                        #expect((commands[current.id] != nil) == permanent)
                        if scenario == "unknown" { throw CancellationError() }
                        if scenario == "write-failure" {
                            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: outcomes.directory.path)
                        }
                        return scenario == "partial" ? CleanupOutcome(failed: [target.path])
                            : CleanupOutcome(removedCount: 1, trashedCount: permanent ? 0 : 1, deletedCount: permanent ? 1 : 0)
                    })
            }, configuration: { settings }, scanner: { _, _ in fixture })
        let expected: Int32 = switch scenario {
        case "wrong-revision", "stale": 65
        case "busy": 75
        case "success", "permanent-success": 0
        case "partial", "unknown": 3
        case "write-failure": 74
        case "permanent-unavailable": 79
        default: 130
        }
        if scenario == "write-failure" {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: outcomes.directory.path)
            #expect(try outcomes.outcomes(planId: review.plan.planId).first?.status == .started)
            #expect(!String(decoding: result.output, as: UTF8.self).contains("did not remove"))
        }
        #expect(result.exitCode == expected)
        #expect(!String(decoding: result.output, as: UTF8.self).contains(root.path))
        #expect(!String(decoding: result.output, as: UTF8.self).contains("permanent_items"))
        #expect(FileManager.default.fileExists(atPath: target.path))
        // Only permanent removal asks the Mac user to authenticate.
        #expect(prompts.all == (permanent ? ["permanently remove 1 item from a saved cleanup plan"] : []))
        if expected == 0 || expected == 3 || expected == 130 {
            let stored = try outcomes.outcomes(planId: review.plan.planId)
            #expect(stored.count == 1)
            #expect(stored[0].status.rawValue == (try object(result)["status"] as? String))
            if expected == 130 { #expect(stored[0].items.isEmpty) }
        }
        if scenario == "wrong-revision" {
            #expect(try outcomes.outcomes(planId: review.plan.planId).isEmpty)
        }
    }

    @Test(arguments: [
        ["plan", "remove", "--plan", "plan_00000000-0000-0000-0000-000000000000"],
        ["plan", "remove", "--plan", "plan_00000000-0000-0000-0000-000000000000", "--revision", "bad"],
        ["plan", "remove", "--plan", "plan_00000000-0000-0000-0000-000000000000",
         "--revision", String(repeating: "0", count: 64), "--yes"],
        ["plan", "remove", "--plan", "plan_00000000-0000-0000-0000-000000000000",
         "--revision", String(repeating: "0", count: 64), "--include-paths"],
        ["plan", "create", "--path", "/tmp/target"], ["plan", "create", "--command", "rm"],
        ["plan", "create", "--unlock"], ["plan", "inspect", "--plan", "../invalid"],
        ["plan", "invalidate", "--plan", "plan_00000000-0000-0000-0000-000000000000", "--revision", "bad"],
        ["plan", "review", "--plan", "plan_00000000-0000-0000-0000-000000000000"],
        ["plan", "review", "--plan", "plan_00000000-0000-0000-0000-000000000000", "--app", "--yes"],
        ["clean"], ["scan", "--yes"], ["scan", "--category", "unknown"],
        ["scan", "--limit", "3"], ["items"], ["items", "--scan", "../secrets"],
        ["scan", "--json", "--json"], ["scan", "--category"], ["version", "--include-paths"],
        ["items", "--scan", "scan_00000000-0000-0000-0000-000000000000", "--limit", "501"],
        ["items", "--scan", "scan_00000000-0000-0000-0000-000000000000", "--offset", "-1"]
    ])
    func malformedArguments(arguments: [String]) async throws {
        let result = await CommandLineInterface.run(arguments: arguments + ["--json"],
            scanner: { _, _ in Issue.record("Invalid arguments started a scan."); throw CancellationError() })
        #expect(result.exitCode == 64)
        #expect(try object(result)["error"] != nil)
    }

    @Test func textOutputReplacesControlCharacters() {
        #expect(TerminalText.field("a\n\u{1b}[31m\u{9b}\u{202e}b") == "a??[31m??b")
        #expect(TerminalText.lines("a\nb\u{1b}") == "a\nb?")
    }

    @Test func excludeSavesAppRulesAndInvalidatesPlans() async throws {
        let suite = "moppo-cli-exclude." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("model-cache")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let keep = root.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: keep)
        var locked = FileEntry(url: keep, kind: .file, allocatedBytes: 10)
        locked.protectionReason = .running
        let entries = [FileEntry(url: target, kind: .cache, allocatedBytes: 4096), locked]
        let results = ScanResults(categories: [.init(categoryID: .aiTools, totalBytes: 4106, entries: entries)],
                                  startedAt: Date(), finishedAt: Date())
        let scans = ScanStore(directory: root.appendingPathComponent("scans"))
        let plans = PlanStore(directory: root.appendingPathComponent("plans"))
        func run(_ arguments: [String]) async -> CLIResult {
            await CommandLineInterface.run(arguments: arguments + ["--json"], store: scans, planStore: plans,
                addExclusions: { try ScanConfiguration.addExclusions($0, to: UserDefaults(suiteName: suite)!) },
                configuration: { try ScanConfiguration(defaults: UserDefaults(suiteName: suite)!) },
                scanner: { _, _ in results })
        }
        let scan = try object(await run(["scan", "--category", "aiTools"]))
        let scanId = try #require(scan["scan_id"] as? String)
        let revision = try #require(scan["revision"] as? String)
        let items = try scans.load(scanId).items
        let plan = try object(await run(["plan", "create", "--scan", scanId, "--revision", revision, "--items", items[0].id]))
        let planId = try #require(plan["plan_id"] as? String)

        let excluded = await run(["exclude", "--scan", scanId, "--item", items[0].id])
        #expect(excluded.exitCode == 0)
        #expect(try object(excluded)["status"] as? String == "excluded")
        #expect(try object(excluded)["added_rules"] as? Int == 1)
        #expect(!String(decoding: excluded.output, as: UTF8.self).contains(root.path))
        #expect(try ScanConfiguration(defaults: defaults).excludedPaths.contains(target.path))
        #expect(try object(await run(["exclude", "--scan", scanId, "--item", items[0].id]))["status"] as? String
            == "already_excluded")
        let protected = await run(["exclude", "--scan", scanId, "--item", items[1].id])
        #expect(protected.exitCode == 65)
        #expect((try object(protected)["error"] as? [String: Any])?["code"] as? String == "exclusion_unsupported")
        let stale = await run(["plan", "inspect", "--plan", planId])
        #expect(stale.exitCode == 65)
        #expect((try object(stale)["error"] as? [String: Any])?["code"] as? String == "exclusions_changed")
        #expect(FileManager.default.fileExists(atPath: target.path))
    }

    @Test func configurationAndContextPreserveExclusions() async throws {
        let suite = "moppo-cli-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        defaults.set(["xcode": false], forKey: ScanConfiguration.categoriesKey)
        let docker = "docker://images/first/sha256:" + String(repeating: "a", count: 64)
        defaults.set(try JSONEncoder().encode([ExclusionRule.folder(root), .pattern("*.private"),
                                               ExclusionRule(kind: .item, value: docker)]),
                     forKey: ScanConfiguration.exclusionsKey)
        let settings = try ScanConfiguration(defaults: defaults)
        #expect(settings.excludedPaths.contains(docker))
        #expect(!settings.enabledCategories.contains(.xcode))
        #expect(settings.enabledCategories.contains(.aiTools))
        #expect(settings.excludedPatterns.contains("*.keychain-db"))
        #expect(settings.excludedPatterns.contains("*.private"))
        var restricted = settings
        restricted.enabledCategories = []
        let context = try await ScanEnvironment.context(configuration: restricted)
        #expect(context.isExcluded(root.appendingPathComponent("child")) == true)
        #expect(ScanContext(excludedPaths: ["/"]).isExcluded(root))
        #expect(context.isExcluded(URL(fileURLWithPath: "/tmp/item.private")))
        let disabled = await CommandLineInterface.run(arguments: ["scan", "--category", "xcode", "--json"],
            configuration: { settings },
            scanner: { _, _ in Issue.record("A disabled category started a scan."); throw CancellationError() })
        #expect(disabled.exitCode == 64)
        defaults.set(["xcode": false, "docker": "invalid"], forKey: ScanConfiguration.categoriesKey)
        #expect(throws: (any Error).self) { try ScanConfiguration.readCategories(from: defaults) }
        #expect(try ScanConfiguration.readCategories(from: defaults, strict: false)[.xcode] == false)
        defaults.removeObject(forKey: ScanConfiguration.categoriesKey)
        defaults.set(Data("invalid".utf8), forKey: ScanConfiguration.exclusionsKey)
        #expect(throws: (any Error).self) { try ScanConfiguration(defaults: defaults) }
    }

    @Test func configurationFailureAndUnavailableScan() async throws {
        let bad = await CommandLineInterface.run(arguments: ["scan", "--json"],
            configuration: { throw ScanConfiguration.ConfigurationError.invalidExclusions })
        #expect(bad.exitCode == 78)
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let unavailable = await CommandLineInterface.run(arguments: ["scan", "--json"],
            store: ScanStore(directory: root.appendingPathComponent("reports")),
            configuration: { ScanConfiguration() },
            scanner: { _, _ in
                ScanResults(categories: [.unavailable(.xcode, reason: "/private/secret is unreadable")],
                            startedAt: Date(), finishedAt: Date())
            })
        #expect(unavailable.exitCode == 77)
        #expect(!String(decoding: unavailable.output, as: UTF8.self).contains("secret"))
    }

    @Test func blockedReportFolderFailsBeforeTheScan() async throws {
        let root = try temporary()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        let result = await CommandLineInterface.run(arguments: ["scan", "--json"],
            store: ScanStore(directory: root.appendingPathComponent("reports")),
            configuration: { ScanConfiguration() },
            scanner: { _, _ in
                Issue.record("The scan started without a writable report folder.")
                return results()
            })
        #expect(result.exitCode == 74)
        let error = try #require(try object(result)["error"] as? [String: Any])
        #expect(error["code"] as? String == "storage_failure")
        #expect((error["message"] as? String)?.contains("agent sandbox") == true)
        #expect(!String(decoding: result.output, as: UTF8.self).contains(root.path))
    }

    @Test func cancellationDoesNotSaveResults() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("reports")
        let started = AsyncStream<Void>.makeStream()
        let task = Task {
            await CommandLineInterface.run(arguments: ["scan", "--json"], store: ScanStore(directory: directory),
                configuration: { ScanConfiguration() },
                scanner: { _, _ in
                    started.continuation.yield(())
                    started.continuation.finish()
                    try await Task.sleep(for: .seconds(60))
                    throw CancellationError()
                })
        }
        for await _ in started.stream { break }
        task.cancel()
        #expect(await task.value.exitCode == 130)
        let saved = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!saved.contains { $0.hasSuffix(".json") })
    }

    @Test func privateStorageRejectsLinksAndUnsupportedSchemas() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(directory: root.appendingPathComponent("reports"))
        let report = ScanReport(results: results())
        try store.save(report)
        let file = store.directory.appendingPathComponent(report.scanId + ".json")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try FileManager.default.attributesOfItem(atPath: store.directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(throws: (any Error).self) { try store.save(report) }
        var modified = report
        modified.schemaVersion = 99
        try ScanReport.encoder().encode(modified).write(to: file)
        #expect(throws: ScanStore.StoreError.incompatibleSchema) { try store.load(report.scanId) }
        try FileManager.default.removeItem(at: file)
        let target = root.appendingPathComponent("target")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        #expect(throws: (any Error).self) { try store.load(report.scanId) }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))
        let linkedStore = ScanStore(directory: root.appendingPathComponent("linked"))
        try FileManager.default.createSymbolicLink(at: linkedStore.directory, withDestinationURL: store.directory)
        #expect(throws: (any Error).self) { try linkedStore.save(ScanReport(results: results())) }
    }

    @Test func retentionAndExpiry() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ScanStore(directory: root.appendingPathComponent("reports"))
        let now = Date()
        let old = ScanReport(results: results(at: now.addingTimeInterval(-8 * 24 * 60 * 60)))
        try store.save(old, now: old.finishedAt)
        #expect(throws: ScanStore.StoreError.expired) { try store.load(old.scanId, now: now) }
        var reports: [ScanReport] = []
        for index in 0..<12 {
            let report = ScanReport(results: results(at: now.addingTimeInterval(Double(index - 12))))
            try store.save(report, now: now)
            reports.append(report)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).count == 10)
        #expect(throws: (any Error).self) { try store.load(reports[0].scanId, now: now) }
        #expect(try store.load(reports[11].scanId, now: now).scanId == reports[11].scanId)
    }
}
