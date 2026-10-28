import Foundation

/// A handoff opens a review. Its URL cannot authorize removal.
public struct PlanHandoff: Sendable, Equatable {
    public let planId: String
    public let revision: String

    public init(planId: String, revision: String) throws {
        guard ScanStore.validId(planId, prefix: "plan_"), RecordDigest.isValid(revision) else {
            throw RecordStoreError.invalidId
        }
        self.planId = planId
        self.revision = revision
    }

    public var launchArguments: [String] { ["--review-plan", planId, revision] }

    public init(launchArguments: [String]) throws {
        guard launchArguments.count == 3, launchArguments[0] == "--review-plan" else {
            throw RecordStoreError.invalidId
        }
        try self.init(planId: launchArguments[1], revision: launchArguments[2])
    }

    public init(url: URL) throws {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "moppo", parts.host == "plan-review", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let query = parts.queryItems, query.count == 2,
              Set(query.map(\.name)) == ["plan", "revision"],
              let planId = query.first(where: { $0.name == "plan" })?.value,
              let revision = query.first(where: { $0.name == "revision" })?.value else {
            throw RecordStoreError.invalidId
        }
        try self.init(planId: planId, revision: revision)
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = "moppo"
        parts.host = "plan-review"
        parts.queryItems = [.init(name: "plan", value: planId), .init(name: "revision", value: revision)]
        return parts.url!
    }
}
