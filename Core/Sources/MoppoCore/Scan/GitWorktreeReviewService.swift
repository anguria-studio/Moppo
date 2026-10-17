import Foundation

/// Checks a worktree without fetching remote data or installing Git.
public struct GitWorktreeReviewService: Sendable {
    private let gitExecutable: @Sendable () async throws -> String?
    public init() { gitExecutable = { try await GitWorktreeDetector.executable() } }
    init(gitExecutable: @escaping @Sendable () async throws -> String?) { self.gitExecutable = gitExecutable }

    public func review(_ directory: URL) async throws -> GitWorktreeReview {
        try await review(directory, includeFileChecks: true)
    }

    /// Reads Git metadata before the scan measures the worktree.
    func metadata(_ directory: URL) async throws -> GitWorktreeReview {
        try await review(directory, includeFileChecks: false)
    }

    private func review(_ directory: URL, includeFileChecks: Bool) async throws -> GitWorktreeReview {
        var review = GitWorktreeReview()
        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin(includeFileChecks ? "worktree_review" : "worktree_metadata", path: directory.path)
        defer {
            diagnostics?.end(span, outcome: Task.isCancelled ? "cancelled" : "completed", details: [
                "review_status": review.statusLabel, "branch": review.branch,
                "local_files": "\(review.localFiles.count)", "ignored_files": "\(review.ignoredFiles.count)",
                "push_status": "\(review.pushStatus)", "activity": "\(review.activity)", "locks": "\(review.locks)"
            ])
        }
        guard GitWorktreeDetector.isWorktree(directory) else {
            review.filesIssue = "This folder is no longer a linked Git worktree."
            review.pushIssue = review.filesIssue
            return review
        }
        if includeFileChecks { review.activity = try await Self.activity(in: directory) }
        guard let git = try await gitExecutable() else {
            review.filesIssue = "Git is not installed."
            review.pushIssue = review.filesIssue
            review.locks = .unknown(review.filesIssue)
            return review
        }
        let runner = ProcessRunner()
        func run(_ arguments: [String]) async throws -> Data {
            try await runner.run(git, ["--no-optional-locks", "--no-lazy-fetch", "-c", "core.fsmonitor=false",
                "-C", directory.path] + arguments, timeout: .seconds(5),
                environment: ["GIT_TERMINAL_PROMPT": "0"], allowsInput: false)
        }
        let comparison = try await GitWorktreeDetector.pushStatus(of: directory, executable: git)
        review.pushStatus = comparison.status
        if let reason = comparison.reason { review.pushIssue = reason }
        if let output = try? await run(["symbolic-ref", "--quiet", "--short", "HEAD"]) {
            review.branch = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let output = try? await run(["rev-parse", "--short", "HEAD"]) {
            review.branch = "Detached HEAD · " + String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        do {
            let output = try await run(["status", "--porcelain=v1", "-z", "--untracked-files=all",
                "--ignore-submodules=none", "--ignored=matching"])
            let parsed = Self.files(in: output, directory: directory)
            review.localFiles = parsed.local
            review.ignoredFiles = parsed.ignored
            review.filesChecked = parsed.complete
            if !parsed.complete { review.filesIssue = "Git returned an incomplete file list." }
            review.status = review.localFiles.isEmpty ? .clean : .uncommittedChanges
            if includeFileChecks {
                var classifier = IgnoredFileClassifier(root: directory)
                for index in review.ignoredFiles.indices {
                    try Task.checkCancellation()
                    let url = directory.appendingPathComponent(review.ignoredFiles[index].path)
                    let measured = try await AllocatedSizeMeasurer().measure(url)
                    Self.apply(measured, at: index, directory: directory, classifier: &classifier, to: &review)
                }
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            review.status = .unavailable
            review.filesIssue = GitWorktreeReview.failureReason(error, tool: "Git")
        }
        do {
            let paths = try await run(["rev-parse", "--absolute-git-dir", "--git-common-dir"])
            let lines = String(decoding: paths, as: UTF8.self).split(separator: "\n")
            if lines.count == 2 {
                let folders = lines.map { URL(fileURLWithPath: String($0), relativeTo: directory).standardizedFileURL }
                var found: [String] = []
                for folder in Set(folders) {
                    let fetch = folder.appendingPathComponent("FETCH_HEAD")
                    if let values = try? fetch.resourceValues(forKeys: [
                        .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
                    ]), values.isRegularFile == true, values.isSymbolicLink != true,
                       (values.fileSize ?? 0) > 0, let date = values.contentModificationDate {
                        review.lastFetchDate = max(review.lastFetchDate ?? date, date)
                    }
                    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
                    found += names.filter { $0.hasSuffix(".lock") || $0 == "locked" }
                }
                review.locks = found.isEmpty ? .clear : .found(found.sorted().joined(separator: ", "))
            } else {
                review.locks = .unknown("Git did not return its metadata paths.")
            }
        } catch is CancellationError { throw CancellationError() }
        catch { review.locks = .unknown(GitWorktreeReview.failureReason(error, tool: "Git")) }
        try Task.checkCancellation()
        return review
    }

    /// Applies scan measurements without another filesystem traversal.
    static func applyMeasurements(_ measurements: [URL: SizeMeasurement], directory: URL, to review: inout GitWorktreeReview) {
        var classifier = IgnoredFileClassifier(root: directory)
        for index in review.ignoredFiles.indices {
            let url = directory.appendingPathComponent(review.ignoredFiles[index].path).standardizedFileURL
            guard let measured = measurements[url] else {
                review.ignoredFiles[index].regeneratesSafely = nil
                ScanDiagnostics.current?.record("worktree_ignored_file", details: [
                    "path": url.path, "worktree": directory.path,
                    "classification": "unverified", "reason": "missing_measurement"
                ])
                continue
            }
            apply(measured, at: index, directory: directory, classifier: &classifier, to: &review)
        }
    }

    private static func apply(_ measured: SizeMeasurement, at index: Int, directory: URL,
                              classifier: inout IgnoredFileClassifier, to review: inout GitWorktreeReview) {
        let url = directory.appendingPathComponent(review.ignoredFiles[index].path)
        let regenerates = classifier.regenerates(url)
        review.ignoredFiles[index].allocatedBytes = measured.allocatedBytes
        review.ignoredFiles[index].regeneratesSafely = nil
        if measured.containsProtectedPattern || regenerates == false {
            review.ignoredFiles[index].regeneratesSafely = false
        } else if measured.unreadableCount > 0 || measured.containsCloudOnlyItem {
            review.ignoredFilesIssue = "Some ignored files could not be read. Check folder access permissions."
        } else {
            review.ignoredFiles[index].regeneratesSafely = regenerates
        }
        let classification = review.ignoredFiles[index].regeneratesSafely
        ScanDiagnostics.current?.record("worktree_ignored_file", details: [
            "path": url.path, "worktree": directory.path,
            "classification": classification == true ? "regenerable" : classification == false ? "local" : "unverified",
            "allocated_bytes": "\(measured.allocatedBytes)"
        ])
    }

    static func files(in data: Data, directory: URL) -> (local: [GitWorktreeReview.File], ignored: [GitWorktreeReview.File], complete: Bool) {
        let records = data.split(separator: 0)
        var local: [GitWorktreeReview.File] = [], ignored: [GitWorktreeReview.File] = []
        var index = 0, complete = true
        while index < records.count {
            let record = Array(records[index])
            index += 1
            guard record.count > 3, record[2] == 32,
                  let path = String(bytes: record.dropFirst(3), encoding: .utf8) else { complete = false; continue }
            let url = directory.appendingPathComponent(path).standardizedFileURL
            guard !path.hasPrefix("/"), url.path.hasPrefix(directory.standardizedFileURL.path + "/"),
                  path.split(separator: "/").allSatisfy({ $0 != ".git" }) else { complete = false; continue }
            let code = String(bytes: record.prefix(2), encoding: .utf8)
            if code == "!!" { ignored.append(.init(path: path, status: .ignored)) }
            else { local.append(.init(path: path, status: code == "??" ? .untracked : .changed)) }
            if record[0] == 82 || record[0] == 67 || record[1] == 82 || record[1] == 67 {
                if index < records.count { index += 1 } else { complete = false }
            }
        }
        return (local.sorted { $0.path < $1.path }, ignored.sorted { $0.path < $1.path }, complete)
    }

    /// Reuses verified parent classifications within one worktree review.
    private struct IgnoredFileClassifier {
        private enum Classification { case regenerable, local, unavailable, blocked }
        private let root: URL
        private var cache: [String: Classification] = [:]

        init(root: URL) { self.root = root.standardizedFileURL }

        mutating func regenerates(_ url: URL) -> Bool? {
            switch classify(url.standardizedFileURL) {
            case .regenerable: true
            case .local, .blocked: false
            case .unavailable: nil
            }
        }

        private mutating func classify(_ url: URL) -> Classification {
            let path = url.path
            guard path == root.path || path.hasPrefix(root.path + "/") else { return .blocked }
            if let cached = cache[path] { return cached }
            let result = inspect(url)
            cache[path] = result
            return result
        }

        private mutating func inspect(_ url: URL) -> Classification {
            guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
                  let isDirectory = values.isDirectory, let isSymbolicLink = values.isSymbolicLink else { return .unavailable }
            guard !isSymbolicLink else { return .blocked }
            // The worktree itself cannot supply cache evidence for its contents.
            guard url.path != root.path else { return isDirectory ? .local : .blocked }
            let parent = classify(url.deletingLastPathComponent())
            switch parent {
            case .blocked, .unavailable: return parent
            case .regenerable: return .regenerable
            case .local: break
            }
            if isDirectory, let kind = BuildOutputDetector.kind(of: url) {
                if case .dependencyStore = kind {
                    if BuildOutputDetector.reinstallEvidence(for: url, within: root) != nil { return .regenerable }
                } else {
                    return .regenerable
                }
            }
            return GeneratedWorktreeFileDetector(root: root).recognizes(url, isDirectory: isDirectory) ? .regenerable : .local
        }
    }

    private static func activity(in directory: URL) async throws -> GitWorktreeReview.Check {
        do {
            let data = try await ProcessRunner().run("/usr/sbin/lsof",
                ["-n", "-P", "-a", "-u", NSUserName(), "-Fpcn", "+D", directory.path], timeout: .seconds(5), allowsInput: false)
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
            let names = Set(lines.filter { $0.hasPrefix("c") }.map { String($0.dropFirst()) })
            return names.isEmpty ? .unknown("The process check returned no process names.") : .found(names.sorted().joined(separator: ", "))
        } catch is CancellationError { throw CancellationError() }
        catch ProcessError.failed(_, let status, let stderr) where status == 1 && stderr.isEmpty { return .clear }
        catch { return .unknown(GitWorktreeReview.failureReason(error, tool: "The process check")) }
    }
}
