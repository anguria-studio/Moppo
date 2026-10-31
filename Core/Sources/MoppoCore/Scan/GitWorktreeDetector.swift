import Foundation

/// Finds linked Git worktrees, including worktrees in hidden folders.
enum GitWorktreeDetector {
    /// Finds an installed Git executable without invoking the macOS installer.
    static func executable() async throws -> String? {
        try Task.checkCancellation()
        let output = try? await ProcessRunner().run("/usr/bin/xcode-select", ["--print-path"], timeout: .seconds(2), allowsInput: false)
        var candidates: [String] = []
        if let output {
            let developer = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            candidates.append(developer + "/usr/bin/git")
        }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        try Task.checkCancellation()
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Updates Git metadata when a worktree moves to or from the Trash.
    static func move(_ source: URL, to destination: URL) async throws -> Bool {
        guard isWorktree(source), let executable = try await executable() else { return false }
        try await ProcessRunner().run(executable,
            ["-C", source.path, "worktree", "move", "--", source.path, destination.path],
            timeout: .seconds(15), environment: ["GIT_TERMINAL_PROMPT": "0"], allowsInput: false)
        return true
    }

    /// Includes missing and locked worktrees that still reserve their paths in Git.
    static func registeredPaths(for directory: URL) async throws -> Set<String> {
        guard let executable = try await executable() else { throw ProcessError.executableMissing("Git") }
        let output = try await ProcessRunner().run(executable,
            ["--no-optional-locks", "-C", directory.path, "worktree", "list", "--porcelain", "-z"],
            timeout: .seconds(5), environment: ["GIT_TERMINAL_PROMPT": "0"], allowsInput: false)
        return Set(String(decoding: output, as: UTF8.self).split(separator: "\0").compactMap { field in
            guard field.hasPrefix("worktree ") else { return nil }
            let url = URL(fileURLWithPath: String(field.dropFirst(9)))
            return url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent).path
        })
    }
    private static let opaqueNames: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "vendor", ".build", "build",
        "target", ".venv", "venv", "Pods", "Library", ".Trash"
    ]

    /// A linked worktree points to Git metadata under a `worktrees` folder.
    /// Missing metadata can remain after the main repository is removed.
    static func isWorktree(_ directory: URL) -> Bool { metadata(of: directory) != nil }

    /// Returns the Git metadata folder that the `.git` file of a linked worktree points to.
    static func metadata(of directory: URL) -> URL? {
        let marker = directory.appendingPathComponent(".git")
        guard let values = try? marker.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 16_384,
              let text = try? String(contentsOf: marker, encoding: .utf8),
              text.hasPrefix("gitdir: ") else { return nil }
        let path = String(text.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, !path.contains("\n") else { return nil }
        let metadata = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
        return metadata.deletingLastPathComponent().lastPathComponent == "worktrees" ? metadata : nil
    }

    /// Stops at each worktree so nested files are counted once.
    static func roots(under folder: URL, context: ScanContext, maxDepth: Int = 8) throws -> [URL] {
        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin("worktree_discovery", path: folder.path)
        defer { diagnostics?.end(span, outcome: Task.isCancelled ? "cancelled" : "completed") }
        var found: [URL] = []
        func walk(_ directory: URL, depth: Int) throws {
            diagnostics?.update(span, path: directory.path, details: ["depth": "\(depth)", "worktrees_found": "\(found.count)"])
            try Task.checkCancellation()
            guard !context.isWithinExclusion(directory),
                  let children = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else { return }
            for child in children.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                guard !context.isExcluded(child),
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                if isWorktree(child) {
                    found.append(child)
                } else if depth < maxDepth, !opaqueNames.contains(child.lastPathComponent),
                          !AppleMediaLibrary.contains(child, home: folder),
                          child.pathExtension != "app" {
                    try walk(child, depth: depth + 1)
                }
            }
        }
        try walk(folder, depth: 1)
        return found
    }

    struct CommitComparison {
        var status: FileEntry.GitWorktreePushStatus
        var reason: String?
        var mergedInto: String? = nil
        var mergeIssue = "Saved default-branch data does not confirm this merge."
        var mergeCandidate: GitHubMergeVerifier.Candidate?
    }

    /// Checks saved default branches before comparing the upstream or detached HEAD.
    static func pushStatus(of directory: URL, executable suppliedExecutable: String? = nil) async throws -> CommitComparison {
        let resolvedExecutable: String?
        if let suppliedExecutable { resolvedExecutable = suppliedExecutable }
        else { resolvedExecutable = try await executable() }
        guard let executable = resolvedExecutable else {
            return .init(status: .unknown, reason: "Git is not installed.", mergeIssue: "Git is not installed.")
        }
        func git(_ arguments: [String]) async throws -> String {
            try Task.checkCancellation()
            let data = try await ProcessRunner().run(
                executable,
                ["--no-optional-locks", "--no-lazy-fetch", "-C", directory.path] + arguments,
                timeout: .seconds(5), environment: ["GIT_TERMINAL_PROMPT": "0"], allowsInput: false
            )
            return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = CommitComparison(status: .unknown, reason: nil)
        do {
            guard try await git(["rev-parse", "--is-shallow-repository"]) == "false" else {
                result.mergeIssue = "Incomplete Git history prevents the commit comparison."
                result.reason = result.mergeIssue
                return result
            }
            let head = try await git(["rev-parse", "--verify", "HEAD"])
            let remotes = try await git(["for-each-ref", "--format=%(refname)%00%(symref)", "refs/remotes/"])
            guard !remotes.isEmpty else {
                result.mergeIssue = "No saved remote branches are available."
                result.reason = result.mergeIssue
                return result
            }
            let upstream: String?
            do { upstream = try await git(["rev-parse", "--symbolic-full-name", "@{upstream}"]) }
            catch is CancellationError { throw CancellationError() }
            catch { try Task.checkCancellation(); upstream = nil }
            let defaults = remotes.split(separator: "\n").compactMap { record -> (remote: String, ref: String)? in
                let fields = record.split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count == 2, fields[0].hasSuffix("/HEAD") else { return nil }
                let prefix = fields[0].dropLast(4)
                guard fields[1].hasPrefix(prefix), fields[1] != fields[0] else { return nil }
                if let upstream, !upstream.hasPrefix(prefix) { return nil }
                return (String(prefix.dropFirst("refs/remotes/".count).dropLast()), String(fields[1]))
            }
            if defaults.count == 1, let target = defaults.first {
                do {
                    _ = try await git(["merge-base", "--is-ancestor", head, target.ref])
                    result.status = .noUnpushedCommits
                    result.mergedInto = String(target.ref.dropFirst("refs/remotes/".count))
                    result.mergeIssue = ""
                    return result
                } catch ProcessError.failed(_, let status, _) where status == 1 { }
                do {
                    let remoteURL = try await git(["remote", "get-url", target.remote])
                    if let repository = GitHubMergeVerifier.Repository(remoteURL: remoteURL), GitHubMergeVerifier.isCommit(head) {
                        result.mergeCandidate = .init(request: .init(repository: repository, head: head),
                                                      defaultRef: target.ref, remote: target.remote)
                    } else {
                        result.mergeIssue = "Saved history does not confirm this merge. GitHub verification requires a supported github.com remote."
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { result.mergeIssue = "The saved remote URL could not be read." }
            } else {
                result.mergeIssue = "The saved remote default branch is missing or ambiguous."
            }
            let comparison: [String]
            if let upstream {
                guard upstream.hasPrefix("refs/remotes/") else {
                    result.reason = "The upstream is a local branch."
                    return result
                }
                comparison = [head, "^" + upstream, "--"]
            } else {
                let branch = try await git(["rev-parse", "--abbrev-ref", "HEAD"])
                guard branch == "HEAD" else {
                    result.reason = "The upstream branch is missing or was deleted."
                    return result
                }
                comparison = [head, "--not", "--remotes", "--"]
            }
            let output = try await git(["rev-list", "--count"] + comparison)
            guard let count = Int(output), count >= 0 else {
                result.reason = "Git did not return a valid commit count."
                return result
            }
            result.status = count == 0 ? .noUnpushedCommits : .unpushedCommits(count)
            return result
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            let reason = GitWorktreeReview.failureReason(error, tool: "Git")
            return .init(status: .unknown, reason: reason, mergeIssue: reason)
        }
    }

    /// Moves worktree bytes from the parent remainder into review rows.
    static func addingWorktrees(to entry: FileEntry, context: ScanContext,
                               prepared: WorktreeScan.Result? = nil) async throws -> FileEntry {
        guard entry.kind == .folder || entry.kind == .cache else { return entry }
        var result = entry
        func record(_ root: URL, outcome: String, bytes: Int64? = nil) {
            var details = ["path": root.path, "parent": entry.url.path, "outcome": outcome]
            if let bytes { details["allocated_bytes"] = "\(bytes)" }
            ScanDiagnostics.current?.record("worktree_row", details: details)
        }
        if isWorktree(entry.url) {
            let review: GitWorktreeReview
            if let prepared { review = prepared.reviews[entry.url.standardizedFileURL] ?? GitWorktreeReview() }
            else { review = try await GitWorktreeReviewService().review(entry.url) }
            result = applyingReview(review, to: result)
            record(entry.url, outcome: "shown", bytes: result.displayBytes)
            return result
        }
        let worktrees = try prepared?.roots ?? roots(under: entry.url, context: context)
        var splitGroups = Set<FileEntry.ID>()
        for root in worktrees {
            let owner = entry.children.first(where: {
                root.path == $0.url.path || root.path.hasPrefix($0.url.path + "/")
            })
            let measured: SizeMeasurement
            let review: GitWorktreeReview
            if let prepared {
                guard let cached = prepared.measurements[root.standardizedFileURL] else {
                    record(root, outcome: "missing_measurement")
                    continue
                }
                measured = cached
                review = prepared.reviews[root.standardizedFileURL] ?? GitWorktreeReview()
            } else {
                measured = try await context.measurer.measure(root)
                review = try await GitWorktreeReviewService().review(root)
            }
            guard !measured.containsProtectedPattern else {
                record(root, outcome: "protected")
                continue
            }
            result.kind = .folder
            result.isRegenerable = false
            if let index = result.children.firstIndex(where: { $0.url.path == root.path }) {
                result.children[index] = applyingReview(review, to: result.children[index])
                record(root, outcome: "shown", bytes: result.children[index].allocatedBytes)
                continue
            }
            let bytes: Int64
            if let owner, let index = result.children.firstIndex(where: { $0.id == owner.id }) {
                bytes = min(result.children[index].allocatedBytes, measured.allocatedBytes)
                result.children[index].allocatedBytes -= bytes
                if splitGroups.insert(owner.id).inserted {
                    // Remove these files only with the parent, after the worktree checks.
                    result.children[index].displayName += " · Other files"
                    result.children[index].kind = .folder
                    result.children[index].isRegenerable = false
                    result.children[index].safetyCaveat = nil
                    if owner.protectionReason == nil, !owner.isRemovalLocked {
                        result.children[index].protectionReason = .folderRemainder
                        result.children[index].protectionExplanation = "This row shows files outside the listed worktrees. Select the parent folder to include these files in its removal review."
                    } else if result.protectionReason == nil {
                        result.protectionReason = .inventory
                        result.protectionExplanation = "This folder contains protected files. Review its removable child items separately."
                    }
                }
            } else {
                bytes = min(result.allocatedBytes, measured.allocatedBytes)
                result.allocatedBytes -= bytes
            }
            record(root, outcome: "shown", bytes: bytes)
            result.children.append(applyingReview(review, to: FileEntry(
                url: root,
                kind: .folder,
                allocatedBytes: bytes,
                lastOpened: DocumentsFilesScanner.lastOpenedDate(for: root),
                protectionReason: owner?.protectionReason ?? (owner?.isRemovalLocked == true ? .inventory : nil),
                protectionExplanation: owner?.protectionExplanation,
                inUseBy: owner?.inUseBy
            )))
        }
        return result
    }

    private static func applyingReview(_ review: GitWorktreeReview, to entry: FileEntry) -> FileEntry {
        var result = entry
        if !result.isGitWorktree { result.parentDisplay += " · Git worktree" }
        result.kind = .folder
        result.isRegenerable = false
        result.safetyCaveat = "Git worktree"
        result.gitWorktreeReview = review
        return result
    }
}
