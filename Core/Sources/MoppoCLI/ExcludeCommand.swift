import Foundation
import MoppoCore
import MoppoPlans

/// Saves the same exclusions as Never Offer This Again in the app.
/// Exclusions only remove items from cleanup results. They never permit removal.
enum ExcludeCommand {
    typealias AddExclusions = @Sendable ([ExclusionRule]) throws -> [ExclusionRule]

    static func run(scanId: String, itemId: String, scans: ScanStore,
                    configuration: @Sendable () throws -> ScanConfiguration,
                    scanner: CommandLineInterface.Scanner,
                    progress: @escaping @Sendable (ScanProgress) -> Void,
                    add: AddExclusions) async throws -> Response {
        let report = try scans.load(scanId)
        guard let item = report.items.first(where: { $0.id == itemId }), let path = item.path,
              let category = CategoryID(rawValue: item.category) else {
            throw CLIError(66, "item_unavailable", "This item is not in the selected scan.")
        }
        var settings = try configuration()
        guard settings.enabledCategories.contains(category) else { throw PlanValidationError.categoryDisabled }
        // Model and Docker rules need identities from the current inventory, not only the row path.
        settings.enabledCategories = [category]
        let results = try await scanner(settings, progress)
        try Task.checkCancellation()
        func flatten(_ entry: FileEntry) -> [FileEntry] { [entry] + entry.children.flatMap(flatten) }
        let matches = results.categories.filter { $0.categoryID == category }
            .flatMap { $0.entries.flatMap(flatten) }
            .filter { ($0.url.isFileURL ? $0.url.path : $0.url.absoluteString) == path }
        guard !matches.isEmpty else { throw PlanValidationError.missingItem }
        guard matches.count == 1, let entry = matches.first else { throw PlanValidationError.changedTarget }
        let rules = ExclusionRule.rules(for: entry)
        guard !rules.isEmpty else {
            throw CLIError(65, "exclusion_unsupported", "Moppo cannot exclude this item. Protected items already stay outside cleanup.")
        }
        let added = try add(rules)
        return Response(status: added.isEmpty ? "already_excluded" : "excluded", scanId: scanId, itemId: itemId,
                        addedRules: added.count)
    }

    struct Response: Encodable {
        let schemaVersion = ScanReport.schemaVersion
        let command = "exclude"
        let status: String
        let scanId: String
        let itemId: String
        let addedRules: Int

        var text: String {
            ["Item: " + itemId, "Status: " + status, "Added rules: \(addedRules)",
             "Later scans skip this item. Plans saved before this change fail with exclusions_changed.",
             "Remove the rule in Moppo Settings > Exclusions."].joined(separator: "\n")
        }
    }
}
