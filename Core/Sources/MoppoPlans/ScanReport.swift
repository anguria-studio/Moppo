import Foundation
import MoppoCore

public struct ScanReport: Codable, Sendable {
    public static let schemaVersion = 1
    public var schemaVersion = Self.schemaVersion
    public let scanId: String
    public let startedAt: Date
    public let finishedAt: Date
    public let expiresAt: Date
    var exclusionsRevision: String?
    public var categories: [Category]
    public var items: [Item]

    public struct Category: Codable, Sendable {
        public let id: String
        public let allocatedBytes: Int64
        public let status: Status
        public let unreadableCount: Int
        public var detail: String?
    }

    public enum Status: String, Codable, Sendable {
        case complete, partial, unavailable, notInstalled
    }

    public struct Item: Codable, Sendable {
        var evidence: PlanEvidence?
        public let id: String
        public let parentId: String?
        public let category: String
        public let kind: String
        public let allocatedBytes: Int64
        public let displayBytes: Int64
        public let measurementStatus: Status
        public let eligibility: String
        public let safeToRemove: Bool
        public let reason: String
        public let protection: String?
        public let recovery: String
        public var name: String?
        public var path: String?
        public var detail: String?
        /// Signs of work in the project around a dependency folder.
        public var projectActivity: ProjectActivityReport?

        public struct ProjectActivityReport: Codable, Sendable, Equatable {
            public let lastActivityAt: Date?
            public let gitIgnore: String
            /// Why the item is not safe to remove. Nil when nothing holds it.
            public let hold: String?

            init(_ activity: ProjectActivity) {
                lastActivityAt = activity.lastActivity
                gitIgnore = activity.gitIgnore.rawValue
                hold = activity.hold?.rawValue
            }
        }

        /// Keeps the reviewed identifier and classification with sizes from a fresh scan.
        /// `status` records the result of the fresh measurement of this item.
        func withMeasurements(of fresh: Item, status: Status) -> Item {
            Item(evidence: fresh.evidence, id: id, parentId: parentId, category: category, kind: kind,
                 allocatedBytes: fresh.allocatedBytes, displayBytes: fresh.displayBytes,
                 measurementStatus: status, eligibility: eligibility, safeToRemove: safeToRemove,
                 reason: reason, protection: protection, recovery: recovery, name: name, path: path, detail: detail,
                 projectActivity: projectActivity)
        }

        public func disclosed(includePaths: Bool) -> Self {
            var copy = self
            copy.evidence = nil
            if !includePaths { copy.name = nil; copy.path = nil; copy.detail = nil }
            return copy
        }
    }

    public var status: Status {
        if !categories.isEmpty && categories.allSatisfy({ $0.status == .unavailable }) { return .unavailable }
        return categories.contains { $0.status == .partial || $0.status == .unavailable } ? .partial : .complete
    }

    public init(results: ScanResults, configuration: ScanConfiguration? = nil) {
        exclusionsRevision = try? configuration?.exclusionsRevision
        scanId = "scan_" + UUID().uuidString.lowercased()
        startedAt = results.startedAt
        finishedAt = results.finishedAt
        expiresAt = results.finishedAt.addingTimeInterval(7 * 24 * 60 * 60)
        categories = results.categories.map { category in
            let status: Status
            var detail: String?
            switch category.availability {
            case .unavailable(let reason): status = .unavailable; detail = reason
            case .notInstalled: status = .notInstalled
            case .available, .empty: status = category.unreadableCount > 0 ? .partial : .complete
            }
            return Category(id: category.categoryID.rawValue, allocatedBytes: category.totalBytes,
                            status: status, unreadableCount: category.unreadableCount, detail: detail)
        }
        items = []
        for (category, summary) in zip(results.categories, categories) {
            func append(_ entry: FileEntry, parent: String?, requiresParent: Bool) {
                let id = "item_" + UUID().uuidString.lowercased()
                let eligibility: String
                if requiresParent { eligibility = "parent_review" }
                else if entry.isRemovalLocked { eligibility = "protected" }
                else if entry.kind == .appBundle || entry.removalAction != nil { eligibility = "app_review" }
                else { eligibility = "review_required" }
                let safe = parent == nil ? category.isCountedSafe(entry) : entry.regeneratesSafely
                let reason: String
                switch eligibility {
                case "protected": reason = "Moppo protects this item from ordinary cleanup."
                case "parent_review": reason = "Review this item with its parent."
                case "app_review": reason = "This item requires an application removal review."
                default:
                    if safe {
                        reason = "The scan identifies this item as safe to regenerate."
                    } else if entry.isRegenerable, let explanation = entry.projectActivity?.explanation {
                        reason = explanation
                    } else {
                        reason = "Review this item before removal. You may need its contents."
                    }
                }
                let recovery: String
                if entry.manualRemoval != nil { recovery = "external_tool" }
                else if entry.toolCommand != nil || entry.dockerImage != nil || entry.codexSession != nil {
                    recovery = "permanent"
                } else { recovery = "trash_if_supported" }
                items.append(Item(evidence: configuration == nil ? nil : PlanEvidence(entry), id: id, parentId: parent, category: summary.id, kind: entry.kind.rawValue,
                    allocatedBytes: entry.allocatedBytes, displayBytes: entry.displayBytes,
                    measurementStatus: summary.status, eligibility: eligibility,
                    safeToRemove: safe && !entry.isRemovalLocked && !requiresParent,
                    reason: reason, protection: entry.protectionReason?.rawValue, recovery: recovery,
                    name: entry.displayName, path: entry.url.isFileURL ? entry.url.path : entry.url.absoluteString,
                    detail: entry.protectionExplanation ?? entry.toolCommand?.lockReason
                        ?? entry.manualRemoval?.explanation ?? entry.safetyCaveat,
                    projectActivity: entry.projectActivity.map(Item.ProjectActivityReport.init)))
                for child in entry.children {
                    append(child, parent: id, requiresParent: requiresParent || entry.removesAsUnit
                        || entry.removalAction != nil)
                }
            }
            for entry in category.entries { append(entry, parent: nil, requiresParent: false) }
        }
    }

    public func disclosed(includePaths: Bool) -> Self {
        var copy = self
        copy.exclusionsRevision = nil
        if !includePaths {
            copy.categories = categories.map { var category = $0; category.detail = nil; return category }
        }
        copy.items = items.map { $0.disclosed(includePaths: includePaths) }
        return copy
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
