import Foundation
import MoppoPlans
import MoppoCore
import MoppoScan

public struct CLIRequest: Sendable {
    public let command: String
    public let json: Bool
    public let includePaths: Bool
    public let scanId: String?
    public let itemId: String?
    public let category: CategoryID?
    public let offset: Int
    public let limit: Int

    public init(arguments: [String]) throws {
        var args = arguments
        let first = args.isEmpty ? "help" : args.removeFirst()
        let command = first == "--help" ? "help" : first == "--version" ? "version" : first
        guard ["help", "version", "scan", "items", "explain", "exclude"].contains(command) else {
            throw CLIError(64, "unknown_command", "Unknown command. Use moppo --help.")
        }
        if args == ["--help"] {
            self = try CLIRequest(arguments: ["help"])
            return
        }
        if command == "help", args.count == 1, ["scan", "items", "explain", "exclude", "version"].contains(args[0]) {
            args = []
        }
        let values: Set<String> = switch command {
        case "scan": ["--category"]
        case "items": ["--scan", "--category", "--offset", "--limit"]
        case "explain", "exclude": ["--scan", "--item"]
        default: []
        }
        let flags: Set<String> = ["scan", "items", "explain"].contains(command) ? ["--json", "--include-paths"] : ["--json"]
        let options = try CommandOptions.parse(args, flags: flags, values: values)
        self.command = command
        json = options.flags.contains("--json")
        includePaths = options.flags.contains("--include-paths")
        scanId = options.values["--scan"]
        itemId = options.values["--item"]
        if ["items", "explain", "exclude"].contains(command) {
            guard let scanId, ScanStore.validId(scanId, prefix: "scan_") else {
                throw CLIError.usage("Supply a scan identifier from moppo scan.")
            }
        }
        if command == "explain" || command == "exclude" {
            guard let itemId, ScanStore.validId(itemId, prefix: "item_") else {
                throw CLIError.usage("Supply an item identifier from moppo items.")
            }
        }
        category = options.values["--category"].flatMap(CategoryID.init(rawValue:))
        guard options.values["--category"] == nil || category != nil else {
            throw CLIError.usage("Unknown category. Use the category identifiers from moppo --help.")
        }
        guard let offset = Int(options.values["--offset"] ?? "0"), offset >= 0,
              let limit = Int(options.values["--limit"] ?? "100"), (1...500).contains(limit) else {
            throw CLIError.usage("Use an offset of zero or more and a limit from 1 to 500.")
        }
        self.offset = offset
        self.limit = limit
    }
}

public struct CLIError: Error, Sendable {
    public let exitCode: Int32
    public let code: String
    public let message: String
    /// The selected item that caused a plan validation error, when one item caused it.
    public private(set) var itemId: String?
    public init(_ exitCode: Int32, _ code: String, _ message: String) {
        self.exitCode = exitCode
        self.code = code
        self.message = message
    }

    func naming(_ itemId: String?) -> Self {
        guard let itemId else { return self }
        var copy = Self(exitCode, code, message + " Item: " + itemId + ".")
        copy.itemId = itemId
        return copy
    }
    static func usage(_ message: String) -> Self { Self(64, "invalid_arguments", message) }

    /// Agent sandboxes often block the private record folder. The message names that folder and no user path.
    static func storageFailure(_ record: String, then nextStep: String? = nil) -> Self {
        let message = ["Moppo could not save a private \(record) in ~/Library/Application Support/Moppo.",
                       "An agent sandbox can block writes to this folder.", nextStep]
        return Self(74, "storage_failure", message.compactMap { $0 }.joined(separator: " "))
    }

    /// Maps service errors to stable codes. Removal messages never claim that no files changed.
    static func from(_ error: any Error, removal: Bool) -> Self {
        switch error {
        case let error as CLIError: return error
        case let error as PlanExecutionError:
            let code: Int32 = error == .confirmationRequired ? 79 : error == .busy ? 75 : 65
            return Self(code, error.rawValue, "Plan removal cannot start (" + error.rawValue + "). Inspect saved outcomes before another attempt.")
        case is CancellationError:
            return Self(130, "cancelled", removal
                ? "The operation stopped. Inspect plan outcomes and Cleanup History before another attempt."
                : "The operation stopped. Moppo did not remove cleanup targets.")
        case let error as PlanValidationError:
            return Self(65, error.rawValue, "The plan cannot pass review (" + error.rawValue + "). Run a new scan and create a new plan.")
        case let error as RecordStoreError:
            switch error {
            case .expired: return Self(66, "expired", "The scan or plan has expired. Run a new scan.")
            case .incompatibleSchema: return Self(65, "incompatible_schema", "This record uses an unsupported schema. Run a new scan.")
            case .changed: return Self(65, "plan_changed", "The plan changed. Inspect the plan again.")
            case .invalidReport, .invalidId, .tooLarge: return Self(65, "invalid_record", "The scan or plan is invalid. Run a new scan.")
            case .writeFailed:
                return storageFailure("record", then: "Inspect plan outcomes and Cleanup History before another attempt.")
            case .unavailable: return Self(66, "record_unavailable", "The scan or plan is missing or inaccessible.")
            }
        case is ScanConfiguration.ConfigurationError:
            return Self(78, "invalid_settings", "Scan settings are invalid. Review the app's categories and exclusions.")
        default:
            return removal
                ? Self(70, "removal_failed", "Removal did not finish. Inspect plan outcomes and Cleanup History before another attempt.")
                : Self(70, "scan_failed", "The scan failed. Moppo did not remove cleanup targets.")
        }
    }
}

public struct CLIResult: Sendable {
    public let output: Data
    public let exitCode: Int32
}

public enum CommandLineInterface {
    public static let help = """
    Moppo: inspect storage and remove reviewed cleanup plans.

    moppo scan [--category ID] [--json] [--include-paths]
    moppo items --scan ID [--category ID] [--offset N] [--limit N] [--json] [--include-paths]
    moppo explain --scan ID --item ID [--json] [--include-paths]
    moppo exclude --scan ID --item ID [--json]
    moppo plan create --scan ID --revision HASH --items ID[,ID...] [--json] [--include-paths]
    moppo plan inspect --plan ID [--json] [--include-paths]
    moppo plan remove --plan ID --revision HASH [--json]
    moppo plan review --plan ID --app [--json]
    moppo plan outcomes --plan ID [--json]
    moppo plan invalidate --plan ID --revision HASH [--json]
    moppo --help
    moppo --version [--json]

    Categories: documentsAndFiles, applications, applicationLeftovers, aiTools,
                hiddenSystemData, systemCaches, packageManagers, xcode, docker

    Scans honor the app's enabled categories and exclusions.
    --category restricts the scan; it does not enable a disabled category.
    --include-paths discloses names, paths, and detailed explanations to the caller.
    Agents can send this output to their providers.
    Reports stay local for seven days. Moppo keeps the ten newest reports and the reports that saved plans use.
    Item pages default to 100 entries, with a maximum of 500.
    exclude saves the same rules as Never Offer This Again in the app. Later scans skip the item.
    Remove these rules in Moppo Settings > Exclusions.
    Parent and child sizes overlap. Do not add item sizes to calculate a total.
    Scanned bytes are not verified recoverable space.
    Plan creation, inspection, and removal run a fresh scan. Plans expire after one day. At most twenty plans remain.

    plan remove removes only the plan revision that you supply.
    It moves ordinary items to Trash without a prompt. Put Back in Cleanup History can restore them.
    Permanent removals require the Mac user to authenticate with Touch ID or the login password.
    Exit codes: 0 complete, 2 partial scan, 3 incomplete removal, 64 invalid arguments, 65 invalid record or plan,
                66 missing or expired record, 69 app unavailable, 70 operation failure, 74 storage failure, 75 removal busy,
                77 unavailable scan, 78 invalid settings, 79 authentication required, 130 cancelled.
    """

    public typealias Scanner = @Sendable (ScanConfiguration, @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResults

    public static func scan(_ configuration: ScanConfiguration,
                            progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> ScanResults {
        try await ScanEnvironment.scan(configuration, progress: progress)
    }

    public static func run(
        arguments: [String],
        store: ScanStore = ScanStore(),
        planStore: PlanStore = PlanStore(),
        outcomeStore: PlanOutcomeStore = PlanOutcomeStore(),
        appLauncher: @escaping @Sendable (PlanHandoff) async throws -> Void = { try await PlanAppLauncher.open($0) },
        authenticate: @escaping @Sendable (String) async throws -> Bool = { try await OwnerAuthentication.authenticate($0) },
        addExclusions: @escaping @Sendable ([ExclusionRule]) throws -> [ExclusionRule] = { try ScanConfiguration.addExclusions($0) },
        planExecution: @escaping @Sendable (CleanupPlanService, PlanOutcomeStore) -> PlanExecutionService = {
            PlanExecutionService(validation: $0, outcomes: $1)
        },
        configuration: @escaping @Sendable () throws -> ScanConfiguration = { try ScanConfiguration.current() },
        scanner: @escaping Scanner = scan,
        version: String = "development",
        progress: @escaping @Sendable (ScanProgress) -> Void = { _ in }
    ) async -> CLIResult {
        do {
            if arguments.first == "plan" {
                return try await PlanCommand.run(arguments: Array(arguments.dropFirst()), scans: store,
                    plans: planStore, outcomes: outcomeStore, appLauncher: appLauncher, authenticate: authenticate,
                    execution: planExecution, configuration: configuration, scanner: scanner, progress: progress)
            }
            let request = try CLIRequest(arguments: arguments)
            try Task.checkCancellation()
            if request.command == "help" {
                return try result(Info(command: "help", text: help), text: help, json: request.json)
            }
            if request.command == "version" {
                return try result(Info(command: "version", text: version), text: "Moppo " + version, json: request.json)
            }
            if request.command == "exclude" {
                let response = try await ExcludeCommand.run(scanId: request.scanId!, itemId: request.itemId!, scans: store,
                    configuration: configuration, scanner: scanner, progress: progress, add: addExclusions)
                return try result(response, text: response.text, json: request.json)
            }
            let report: ScanReport
            let revision: String
            if request.command == "scan" {
                var settings: ScanConfiguration
                do { settings = try configuration() }
                catch { throw CLIError(78, "invalid_settings", "Scan settings are invalid. Review the app's categories and exclusions.") }
                if let category = request.category {
                    guard settings.enabledCategories.contains(category) else {
                        throw CLIError.usage("Moppo settings disable this category.")
                    }
                    settings.enabledCategories = [category]
                }
                do { try store.checkWritable() } catch { throw CLIError.storageFailure("scan report") }
                let scanned = try await scanner(settings, progress)
                try Task.checkCancellation()
                report = ScanReport(results: scanned, configuration: settings)
                revision = try RecordDigest.of(report)
                do { try store.save(report, keeping: planStore.referencedScanIds()) }
                catch { throw CLIError.storageFailure("scan report") }
            } else {
                do { (report, revision) = try store.loadWithRevision(request.scanId!) }
                catch RecordStoreError.incompatibleSchema {
                    throw CLIError(65, "incompatible_schema", "This report uses an unsupported schema. Run a new scan.")
                } catch RecordStoreError.invalidReport {
                    throw CLIError(65, "invalid_report", "This report is invalid. Run a new scan.")
                } catch {
                    throw CLIError(66, "report_unavailable", "This report is missing, expired, or inaccessible. Run a new scan.")
                }
            }
            try Task.checkCancellation()
            let disclosed = report.disclosed(includePaths: request.includePaths)
            let matching = disclosed.items.filter {
                (request.category == nil || $0.category == request.category?.rawValue)
                    && (request.itemId == nil || $0.id == request.itemId)
            }
            if request.command == "explain", matching.isEmpty {
                throw CLIError(66, "item_unavailable", "This item is not in the selected scan.")
            }
            let page = request.command == "scan" ? [] : Array(matching.dropFirst(request.offset).prefix(request.limit))
            let next = request.command != "scan" && request.offset < matching.count
                && page.count < matching.count - request.offset ? request.offset + page.count : nil
            let response = ReportResponse(command: request.command, scanId: report.scanId, revision: revision, status: report.status,
                startedAt: report.startedAt, finishedAt: report.finishedAt, expiresAt: report.expiresAt,
                categories: disclosed.categories, totalItems: matching.count, items: page, nextOffset: next,
                pathsDisclosed: request.includePaths)
            let code: Int32 = request.command == "scan"
                ? (report.status == .unavailable ? 77 : report.status == .partial ? 2 : 0) : 0
            return try result(response, text: response.text, json: request.json, code: code)
        } catch {
            let failure = CLIError.from(error, removal: arguments.starts(with: ["plan", "remove"]))
            if arguments.contains("--json"), let data = try? ScanReport.encoder().encode(Failure(error: failure)) {
                return CLIResult(output: data + Data([10]), exitCode: failure.exitCode)
            }
            return CLIResult(output: Data(("error: " + failure.message + "\n").utf8), exitCode: failure.exitCode)
        }
    }

    private struct Info: Encodable {
        let schemaVersion = ScanReport.schemaVersion
        let command: String
        let text: String
    }

    private struct Failure: Encodable {
        let schemaVersion = ScanReport.schemaVersion
        let error: Detail
        struct Detail: Encodable { let code: String; let message: String; let itemId: String? }
        init(error: CLIError) { self.error = Detail(code: error.code, message: error.message, itemId: error.itemId) }
    }

    private struct ReportResponse: Encodable {
        let schemaVersion = ScanReport.schemaVersion
        let command: String
        let scanId: String
        let revision: String
        let status: ScanReport.Status
        let startedAt: Date
        let finishedAt: Date
        let expiresAt: Date
        let categories: [ScanReport.Category]
        let totalItems: Int
        let items: [ScanReport.Item]
        let nextOffset: Int?
        let pathsDisclosed: Bool

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, command, scanId, revision, status, startedAt, finishedAt, expiresAt
            case categories, totalItems, items, nextOffset, pathsDisclosed
        }

        /// `next_offset` is `null` on the last page. Clients do not need to treat a missing key as the end.
        func encode(to encoder: any Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(schemaVersion, forKey: .schemaVersion)
            try values.encode(command, forKey: .command)
            try values.encode(scanId, forKey: .scanId)
            try values.encode(revision, forKey: .revision)
            try values.encode(status, forKey: .status)
            try values.encode(startedAt, forKey: .startedAt)
            try values.encode(finishedAt, forKey: .finishedAt)
            try values.encode(expiresAt, forKey: .expiresAt)
            try values.encode(categories, forKey: .categories)
            try values.encode(totalItems, forKey: .totalItems)
            try values.encode(items, forKey: .items)
            try values.encode(nextOffset, forKey: .nextOffset)
            try values.encode(pathsDisclosed, forKey: .pathsDisclosed)
        }

        var text: String {
            var lines = ["Scan: " + scanId, "Revision: " + revision, "Status: " + status.rawValue, "Items: " + String(totalItems)]
            if command == "scan" {
                lines += categories.map { "\($0.id): \($0.allocatedBytes) bytes (\($0.status.rawValue))" }
                lines.append("List items with: moppo items --scan " + scanId)
            } else {
                lines += items.map {
                    var line = "\($0.id)  \($0.displayBytes) bytes  \($0.eligibility)"
                    line += "\n  \($0.category) / \($0.kind) / \($0.measurementStatus.rawValue)"
                    line += "\n  \($0.reason) Recovery: \($0.recovery)."
                    if let parent = $0.parentId { line += "\n  Parent: " + parent }
                    if let protection = $0.protection { line += "\n  Protection: " + protection }
                    if let name = $0.name { line += "\n  " + TerminalText.field(name) }
                    if let path = $0.path { line += "\n  " + TerminalText.field(path) }
                    if let detail = $0.detail { line += "\n  " + TerminalText.field(detail) }
                    return line
                }
                if let nextOffset { lines.append("Next page: --offset " + String(nextOffset)) }
            }
            return TerminalText.lines(lines.joined(separator: "\n"))
        }
    }

    private static func result<T: Encodable>(_ value: T, text: String, json: Bool, code: Int32 = 0) throws -> CLIResult {
        let data = json ? try ScanReport.encoder().encode(value) : Data(text.utf8)
        return CLIResult(output: data + Data([10]), exitCode: code)
    }
}
