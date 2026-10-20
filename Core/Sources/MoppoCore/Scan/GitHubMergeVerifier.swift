import Foundation

/// Reads merged pull requests through the installed GitHub CLI sign-in.
actor GitHubMergeVerifier {
    struct Repository: Hashable, Sendable {
        let owner: String
        let name: String
        var fullName: String { owner + "/" + name }

        init?(remoteURL: String) {
            let path: String
            if remoteURL.hasPrefix("git@github.com:") {
                path = String(remoteURL.dropFirst("git@github.com:".count))
            } else {
                guard let url = URLComponents(string: remoteURL), url.host?.lowercased() == "github.com",
                      ["https", "ssh"].contains(url.scheme), url.port == nil,
                      url.query == nil, url.fragment == nil else { return nil }
                path = String(url.path.drop(while: { $0 == "/" }))
            }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let owner = String(parts[0]), name = String(parts[1]).replacingOccurrences(of: #"\.git$"#, with: "", options: .regularExpression)
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
            guard [owner, name].allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
            self.owner = owner.lowercased()
            self.name = name.lowercased()
        }
    }

    struct Request: Hashable, Sendable {
        let repository: Repository
        let head: String
    }

    struct Proof: Equatable, Sendable {
        let number: Int
        let mergeCommit: String
        let baseBranch: String
    }

    enum Lookup: Equatable, Sendable {
        case verified(Proof)
        case unavailable(String)
    }

    struct Candidate: Equatable, Sendable {
        let request: Request
        let defaultRef: String
        let remote: String
        var baseBranch: String { String(defaultRef.dropFirst(("refs/remotes/" + remote + "/").count)) }
        var target: String { remote + "/" + baseBranch }
    }

    static let shared = GitHubMergeVerifier()
    private let fetch: @Sendable (Repository, [String], Duration) async throws -> Data
    private var cache: [Request: (result: Lookup, date: Date)] = [:]
    private var unavailable: (reason: String, until: Date)?
    private var repositoryFailures: [Repository: (reason: String, until: Date)] = [:]
    private var activeRepositories: Set<Repository> = []
    private var waiters: [(id: UUID, repository: Repository, continuation: CheckedContinuation<Void, Error>)] = []

    init(fetch: @escaping @Sendable (Repository, [String], Duration) async throws -> Data = GitHubMergeVerifier.fetch) {
        self.fetch = fetch
    }

    func lookup(_ requests: [Request]) async throws -> [Request: Lookup] {
        let groups = Dictionary(grouping: Set(requests), by: \.repository)
        return try await withThrowingTaskGroup(of: [Request: Lookup].self) { group in
            for (repository, requests) in groups {
                group.addTask { try await self.lookup(repository, requests: requests.sorted { $0.head < $1.head }) }
            }
            var results: [Request: Lookup] = [:]
            for try await result in group { results.merge(result, uniquingKeysWith: { _, new in new }) }
            return results
        }
    }

    private func lookup(_ repository: Repository, requests: [Request]) async throws -> [Request: Lookup] {
        try Task.checkCancellation()
        let cached = requests.compactMap { request in cachedResult(request).map { (request, $0) } }
        if cached.count == requests.count { return Dictionary(uniqueKeysWithValues: cached) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        do { try await acquire(repository) }
        catch ProcessError.timedOut {
            return Dictionary(uniqueKeysWithValues: requests.map { ($0, .unavailable("The GitHub merge check reached its time limit.")) })
        }
        defer { release(repository) }
        try Task.checkCancellation()
        var results: [Request: Lookup] = [:]
        var pending: [Request] = []
        for request in requests {
            if let cached = cachedResult(request) { results[request] = cached }
            else { pending.append(request) }
        }
        for start in stride(from: 0, to: pending.count, by: 20) {
            try Task.checkCancellation()
            let batch = Array(pending[start..<min(start + 20, pending.count)])
            let remaining = ContinuousClock.now.duration(to: deadline)
            let received: [Request: Lookup]
            if let unavailable, unavailable.until > Date() {
                received = Dictionary(uniqueKeysWithValues: batch.map { ($0, .unavailable(unavailable.reason)) })
            } else if let failure = repositoryFailures[repository], failure.until > Date() {
                received = Dictionary(uniqueKeysWithValues: batch.map { ($0, .unavailable(failure.reason)) })
            } else if remaining <= .zero {
                received = Dictionary(uniqueKeysWithValues: batch.map { ($0, .unavailable("The GitHub merge check reached its time limit.")) })
            } else {
                do {
                    let data = try await fetch(repository, batch.map(\.head), min(.seconds(5), remaining))
                    try Task.checkCancellation()
                    received = Self.parse(data, repository: repository, requests: batch)
                } catch is CancellationError { throw CancellationError() }
                catch {
                    try Task.checkCancellation()
                    let failure = Self.failureReason(error)
                    if failure.global { unavailable = (failure.reason, Date().addingTimeInterval(30)) }
                    else { repositoryFailures[repository] = (failure.reason, Date().addingTimeInterval(30)) }
                    received = Dictionary(uniqueKeysWithValues: batch.map { ($0, .unavailable(failure.reason)) })
                }
            }
            for (request, result) in received { cache[request] = (result, Date()) }
            results.merge(received, uniquingKeysWith: { _, new in new })
        }
        if cache.count > 2_048 {
            for entry in cache.sorted(by: { $0.value.date < $1.value.date }).prefix(cache.count - 2_048) {
                cache.removeValue(forKey: entry.key)
            }
        }
        repositoryFailures = repositoryFailures.filter { $0.value.until > Date() }
        ScanDiagnostics.current?.record("github_merge_lookup", details: [
            "repository": repository.fullName, "commits": "\(requests.count)",
            "cached_commits": "\(requests.count - pending.count)"
        ])
        return results
    }

    private func cachedResult(_ request: Request) -> Lookup? {
        guard let cached = cache[request] else { return nil }
        if case .verified = cached.result { return cached.result }
        return Date().timeIntervalSince(cached.date) < 30 ? cached.result : nil
    }

    /// Limits network work to two repositories. Requests for one repository share the cache.
    private func acquire(_ repository: Repository) async throws {
        try Task.checkCancellation()
        if activeRepositories.count < 2, !activeRepositories.contains(repository) {
            activeRepositories.insert(repository)
            return
        }
        let id = UUID()
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            expireWaiter(id)
        }
        defer { timeout.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, repository, continuation)) }
            }
        } onCancel: { _ = Task { await self.cancelWaiter(id) } }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func expireWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: ProcessError.timedOut("GitHub"))
    }

    private func release(_ repository: Repository) {
        activeRepositories.remove(repository)
        while activeRepositories.count < 2,
              let index = waiters.firstIndex(where: { !activeRepositories.contains($0.repository) }) {
            let waiter = waiters.remove(at: index)
            activeRepositories.insert(waiter.repository)
            waiter.continuation.resume()
        }
    }

    static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func fetch(_ repository: Repository, heads: [String], timeout: Duration) async throws -> Data {
        guard let executable = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"]
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ProcessError.executableMissing("GitHub CLI")
        }
        guard !heads.isEmpty, heads.count <= 20, heads.allSatisfy(isCommit) else { throw CocoaError(.fileReadCorruptFile) }
        let fields = heads.enumerated().map { index, head in
            """
            c\(index): object(oid:"\(head)") { ... on Commit { oid associatedPullRequests(first:20) {
              nodes { number state merged headRefOid baseRefName mergeCommit { oid } repository { nameWithOwner } }
              pageInfo { hasNextPage }
            } } }
            """
        }.joined(separator: "\n")
        let query = "query($owner:String!,$name:String!) { repository(owner:$owner,name:$name) { nameWithOwner defaultBranchRef { name } \(fields) } }"
        return try await ProcessRunner().run(executable,
            ["api", "graphql", "--hostname", "github.com", "-f", "query=" + query,
             "-f", "owner=" + repository.owner, "-f", "name=" + repository.name], timeout: timeout,
            environment: ["GH_PROMPT_DISABLED": "1", "GH_PAGER": "cat", "GH_DEBUG": "", "GH_FORCE_TTY": ""], allowsInput: false)
    }

    static func parse(_ data: Data, repository: Repository, requests: [Request]) -> [Request: Lookup] {
        let incomplete = Lookup.unavailable("GitHub returned incomplete merge data.")
        guard data.count <= 2 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], root["errors"] == nil,
              let payload = root["data"] as? [String: Any], let repo = payload["repository"] as? [String: Any],
              (repo["nameWithOwner"] as? String)?.lowercased() == repository.fullName,
              let defaultBranch = repo["defaultBranchRef"] as? [String: Any], let base = defaultBranch["name"] as? String else {
            return Dictionary(uniqueKeysWithValues: requests.map { ($0, incomplete) })
        }
        return Dictionary(uniqueKeysWithValues: requests.enumerated().map { index, request in
            if repo["c\(index)"] is NSNull {
                return (request, .unavailable("GitHub could not find this worktree commit. It may exist only on this Mac."))
            }
            guard let commit = repo["c\(index)"] as? [String: Any], commit["oid"] as? String == request.head,
                  let connection = commit["associatedPullRequests"] as? [String: Any],
                  let pulls = connection["nodes"] as? [[String: Any]] else { return (request, incomplete) }
            for pull in pulls {
                guard pull["state"] as? String == "MERGED", pull["merged"] as? Bool == true,
                      pull["headRefOid"] as? String == request.head, pull["baseRefName"] as? String == base,
                      let owner = pull["repository"] as? [String: Any],
                      (owner["nameWithOwner"] as? String)?.lowercased() == repository.fullName,
                      let number = pull["number"] as? Int, number > 0,
                      let merge = pull["mergeCommit"] as? [String: Any], let oid = merge["oid"] as? String,
                      isCommit(oid) else { continue }
                return (request, .verified(Proof(number: number, mergeCommit: oid, baseBranch: base)))
            }
            let page = connection["pageInfo"] as? [String: Any]
            return (request, page?["hasNextPage"] as? Bool == false
                ? .unavailable("No merged pull request matches this exact commit and the default branch.") : incomplete)
        })
    }

    private static func failureReason(_ error: Error) -> (reason: String, global: Bool) {
        if case ProcessError.executableMissing = error { return ("GitHub CLI is not installed. GitHub merge verification is unavailable.", true) }
        if case ProcessError.timedOut = error { return ("The GitHub merge check timed out.", true) }
        if case ProcessError.failed(_, _, let stderr) = error {
            let text = stderr.lowercased()
            if text.contains("rate limit") || text.contains("http 429") { return ("GitHub limited the request rate. Try again later.", true) }
            if text.contains("auth login") || text.contains("authentication") || text.contains("http 401") {
                return ("GitHub CLI needs an active sign-in.", true)
            }
            if text.contains("could not resolve to a repository") || text.contains("http 404") || text.contains("http 403") {
                return ("GitHub could not read this repository. Check your account access.", false)
            }
        }
        return ("GitHub merge verification is unavailable. Check your connection and account access.", true)
    }
}
