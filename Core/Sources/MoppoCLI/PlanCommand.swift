import Foundation
import MoppoCore
import MoppoPlans

struct PlanCommand {
    static func run(arguments: [String], scans: ScanStore, plans: PlanStore, outcomes: PlanOutcomeStore,
                    appLauncher: @escaping @Sendable (PlanHandoff) async throws -> Void,
                    authenticate: @escaping PlanRemoval.Authenticate,
                    execution: @Sendable (CleanupPlanService, PlanOutcomeStore) -> PlanExecutionService,
                    configuration: @escaping CleanupPlanService.Configuration,
                    scanner: @escaping CommandLineInterface.Scanner,
                    progress: @escaping @Sendable (ScanProgress) -> Void) async throws -> CLIResult {
        let commands = ["create", "inspect", "remove", "review", "outcomes", "invalidate"]
        if arguments == ["--help"] || commands.contains(where: { arguments == [$0, "--help"] }) {
            return CLIResult(output: Data((CommandLineInterface.help + "\n").utf8), exitCode: 0)
        }
        guard let command = arguments.first, commands.contains(command) else {
            throw CLIError.usage("Use moppo --help to see the plan commands.")
        }
        let required: Set<String> = switch command {
        case "create": ["--scan", "--revision", "--items"]
        case "remove", "invalidate": ["--plan", "--revision"]
        default: ["--plan"]
        }
        var flags: Set<String> = ["--json"]
        if command == "create" || command == "inspect" { flags.insert("--include-paths") }
        if command == "review" { flags.insert("--app") }
        let options = try CommandOptions.parse(Array(arguments.dropFirst()), flags: flags, values: required)
        guard Set(options.values.keys) == required else { throw CLIError.usage("A required plan option is missing. Use moppo --help.") }
        if let id = options.values["--scan"], !ScanStore.validId(id, prefix: "scan_") {
            throw CLIError.usage("Supply a scan identifier from moppo scan.")
        }
        if let id = options.values["--plan"], !ScanStore.validId(id, prefix: "plan_") {
            throw CLIError.usage("Supply a plan identifier from moppo plan create.")
        }
        if let revision = options.values["--revision"], !RecordDigest.isValid(revision) {
            throw CLIError.usage("Supply the exact revision from the scan or plan output.")
        }
        if command == "review", !options.flags.contains("--app") {
            throw CLIError(64, "app_option_required", "Use --app for app review. Use plan remove to remove the plan.")
        }
        let planId = options.values["--plan"] ?? ""
        let service = CleanupPlanService(scans: scans, plans: plans, configuration: configuration,
            scanner: { settings in try await scanner(settings, progress) })
        let response: Response
        var exitCode: Int32 = 0
        // Name the selected item when one item fails validation.
        do {
            switch command {
            case "remove":
                let outcome = try await PlanRemoval.run(planId: planId, revision: options.values["--revision"]!,
                    validation: service, outcomes: outcomes, authenticate: authenticate, execution: execution)
                response = Response(command: "plan remove", status: outcome.status.rawValue, planId: planId, outcomes: [outcome])
                exitCode = outcome.status == .completed ? 0 : outcome.status == .cancelled ? 130 : 3
            case "review":
                let plan = try plans.load(planId)
                guard try scans.loadWithRevision(plan.scanId).revision == plan.scanRevision else { throw PlanValidationError.scanChanged }
                let handoff = try PlanHandoff(planId: plan.planId, revision: RecordDigest.of(plan))
                try await appLauncher(handoff)
                response = Response(command: "plan review", status: "app_requested", planId: plan.planId, revision: handoff.revision)
            case "outcomes":
                let records = try outcomes.outcomes(planId: planId)
                response = Response(command: "plan outcomes", status: records.isEmpty ? "no_outcome" : "outcomes_available",
                                    planId: planId, outcomes: records)
            case "invalidate":
                try plans.invalidate(planId, revision: options.values["--revision"]!)
                response = Response(command: "plan invalidate", status: "invalidated", planId: planId)
            default:
                let review: PlanReview
                if command == "create" {
                    let ids = options.values["--items"]!.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                    review = try await service.create(scanId: options.values["--scan"]!,
                                                      scanRevision: options.values["--revision"]!, itemIds: ids)
                } else {
                    review = try await service.inspect(planId)
                }
                let paths = options.flags.contains("--include-paths")
                // Commands contain paths. The tool name alone does not.
                let commands = zip(review.items, review.entries).compactMap { item, entry -> PermanentCommand? in
                    guard item.recovery == "permanent", let tool = entry.toolCommand else { return nil }
                    return PermanentCommand(itemId: item.id,
                        tool: URL(fileURLWithPath: tool.executable ?? "").lastPathComponent,
                        command: paths ? tool.command : nil)
                }
                response = Response(command: "plan " + command, status: "review_required", planId: review.plan.planId,
                    revision: review.revision, scanId: review.plan.scanId, scanRevision: review.plan.scanRevision,
                    expiresAt: review.plan.expiresAt, items: review.items.map { $0.disclosed(includePaths: paths) },
                    permanentItems: review.permanentItemIds.sorted(), permanentCommands: commands,
                    scanAllocatedBytes: review.scanAllocatedBytes, pathsDisclosed: paths)
            }
        } catch let error as PlanValidationError {
            throw CLIError.from(error, removal: command == "remove").naming(service.lastFailedItemId)
        }
        let data = options.flags.contains("--json") ? try ScanReport.encoder().encode(response) : Data(response.text.utf8)
        return CLIResult(output: data + Data([10]), exitCode: exitCode)
    }

    /// The tool that removes a permanent item. `command` requires `--include-paths`.
    private struct PermanentCommand: Encodable {
        let itemId: String
        let tool: String
        let command: String?
    }

    private struct Response: Encodable {
        let schemaVersion = CleanupPlan.schemaVersion
        let command: String
        let status: String
        let planId: String
        var outcomes: [PlanOutcome] = []
        var revision: String? = nil
        var scanId: String? = nil
        var scanRevision: String? = nil
        var expiresAt: Date? = nil
        var items: [ScanReport.Item] = []
        /// Present only in plan creation and inspection.
        var permanentItems: [String]? = nil
        var permanentCommands: [PermanentCommand]? = nil
        var scanAllocatedBytes: Int64? = nil
        let recoverableSpace = "unverified"
        var pathsDisclosed = false

        var text: String {
            var lines = ["Plan: " + planId, "Status: " + status]
            if let revision { lines.append("Revision: " + revision) }
            if let expiresAt { lines.append("Expires: " + expiresAt.ISO8601Format()) }
            if let scanAllocatedBytes { lines.append("Scanned bytes: " + String(scanAllocatedBytes)) }
            for item in items {
                lines.append(item.id + "  \(item.allocatedBytes) bytes  " + item.reason + " Recovery: " + item.recovery + ".")
                if let path = item.path { lines.append("  " + TerminalText.field(path)) }
            }
            for outcome in outcomes {
                lines.append(outcome.runId + ": " + outcome.status.rawValue)
                if let reason = outcome.reason { lines.append("Reason: " + reason) }
                for item in outcome.items {
                    lines.append(item.itemId + ": " + item.status.rawValue + " (" + (item.reason ?? "completed") + ")")
                    lines.append("Trash moves: \(item.trashedCount). Permanent removals: \(item.deletedCount). Private bytes: \(item.privateBytes).")
                }
            }
            switch command {
            case "plan review":
                lines.append("Moppo must validate the plan and ask for confirmation. This command did not authorize removal.")
            case "plan outcomes", "plan remove":
                lines.append("A started record without a final result has an unknown outcome. Check Cleanup History.")
            case "plan invalidate": break
            default:
                if let permanentItems, !permanentItems.isEmpty {
                    lines.append("Permanent items: " + permanentItems.joined(separator: ", ") + ". Put Back cannot restore them.")
                }
                for command in permanentCommands ?? [] {
                    lines.append(command.itemId + " runs " + TerminalText.field(command.tool)
                        + (command.command.map { ": " + TerminalText.field($0) } ?? ". Use --include-paths to show the command."))
                }
                lines.append("To remove this revision: moppo plan remove --plan " + planId + " --revision " + (revision ?? ""))
                lines.append("Recoverable space is unverified.")
            }
            return TerminalText.lines(lines.joined(separator: "\n"))
        }
    }
}
