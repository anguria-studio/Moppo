import Foundation

/// Shares scan measurements and process information across a group of worktrees.
struct WorktreeScan: Sendable {
    struct Result: Sendable {
        let roots: [URL]
        let measurements: [URL: SizeMeasurement]
        let reviews: [URL: GitWorktreeReview]
    }

    let roots: [URL]
    private let reviews: [URL: GitWorktreeReview]
    private let activity: WorktreeActivity?

    private var measurementPaths: [URL] {
        roots + reviews.flatMap { root, review in
            review.ignoredFiles.map { root.appendingPathComponent($0.path).standardizedFileURL }
        }
    }

    static func prepare(_ roots: [URL]) async throws -> Self {
        let roots = roots.map(\.standardizedFileURL)
        guard !roots.isEmpty else { return Self(roots: [], reviews: [:], activity: nil) }
        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin("worktree_batch", details: ["worktrees": "\(roots.count)", "review_limit": "2"])
        defer { diagnostics?.end(span, outcome: Task.isCancelled ? "cancelled" : "completed") }
        let git = try await GitWorktreeDetector.executable()
        let service = GitWorktreeReviewService(gitExecutable: { git })
        var reviews: [URL: GitWorktreeReview] = [:]
        try await withThrowingTaskGroup(of: (URL, GitWorktreeReview).self) { group in
            var next = 0
            func submit() {
                guard next < roots.count else { return }
                let root = roots[next]
                next += 1
                group.addTask { (root, try await service.metadata(root)) }
            }
            for _ in 0..<min(2, roots.count) { submit() }
            for try await (root, review) in group {
                reviews[root] = review
                diagnostics?.update(span, details: ["reviewed": "\(reviews.count)"])
                try Task.checkCancellation()
                submit()
            }
        }
        let activity = try await WorktreeActivity.capture(roots: roots)
        return Self(roots: roots, reviews: reviews, activity: activity)
    }

    func measure(_ root: URL, with measurer: AllocatedSizeMeasurer,
                 retaining paths: [URL] = []) async throws -> Result {
        let observer: (@Sendable (URL, URLResourceValues, [URL]) -> Void)?
        if let activity {
            observer = { url, values, owners in activity.observe(url, values: values, attribution: owners) }
        } else { observer = nil }
        return finish(try await measurer.measure(root, retaining: paths + measurementPaths, observeEntry: observer))
    }

    private func finish(_ measurements: [URL: SizeMeasurement]) -> Result {
        var reviews = reviews
        if let activity {
            ScanDiagnostics.current?.record("worktree_activity_measurement", details: [
                "worktrees": "\(roots.count)", "identity_fallbacks": "\(activity.fallbackCount)"
            ])
        }
        for root in roots {
            var review = reviews[root] ?? GitWorktreeReview()
            GitWorktreeReviewService.applyMeasurements(measurements, directory: root, to: &review)
            review.activity = activity?.check(root, measurement: measurements[root])
                ?? .unknown("Open files and processes were not checked.")
            reviews[root] = review
            ScanDiagnostics.current?.record("worktree_scan_result", details: [
                "path": root.path, "review_status": review.statusLabel,
                "ignored_files": "\(review.ignoredFiles.count)", "ignored_bytes": "\(review.ignoredBytes)",
                "regenerable_ignored_files": "\(review.regenerableIgnoredFiles.count)",
                "local_ignored_files": "\(review.localIgnoredFiles.count)",
                "unverified_ignored_files": "\(review.unverifiedIgnoredFiles.count)",
                "activity": "\(review.activity)", "measurement_reused": "true"
            ])
        }
        return Result(roots: roots, measurements: measurements, reviews: reviews)
    }
}

/// Matches open file identities during the existing measurement traversal.
final class WorktreeActivity: @unchecked Sendable {
    private let roots: Set<URL>
    private let processes: [String: Set<String>]
    private let processesByVolume: [NSObject: [UInt64: Set<String>]]
    private let issue: String?
    private let lock = NSLock()
    private var matches: [URL: Set<String>] = [:]
    private var unreadable: Set<URL> = []
    private var identityFallbacks = 0

    var fallbackCount: Int { lock.withLock { identityFallbacks } }

    init(roots: [URL], processes: [String: Set<String>], issue: String? = nil) {
        self.roots = Set(roots.map(\.standardizedFileURL))
        self.processes = processes
        self.issue = issue
        var volumes: [NSObject: [UInt64: Set<String>]] = [:]
        for root in roots {
            guard let values = try? root.resourceValues(forKeys: [.volumeIdentifierKey]),
                  let volume = values.volumeIdentifier as? NSObject, volumes[volume] == nil,
                  let identity = FileIdentity.of(root), let device = identity.split(separator: ":").first else { continue }
            let prefix = device + ":"
            var files: [UInt64: Set<String>] = [:]
            for (identity, names) in processes where identity.hasPrefix(prefix) {
                if let inode = UInt64(identity.dropFirst(prefix.count)) { files[inode] = names }
            }
            volumes[volume] = files
        }
        self.processesByVolume = volumes
    }

    static func capture(roots: [URL]) async throws -> WorktreeActivity {
        do {
            let data = try await ProcessRunner().run("/usr/sbin/lsof",
                ["-n", "-P", "-u", NSUserName(), "-F0pcftDin"], timeout: .seconds(5),
                allowsInput: false, requiresEmptyStandardError: true)
            let parsed = parse(data, scanProcessID: ProcessInfo.processInfo.processIdentifier)
            return WorktreeActivity(roots: roots, processes: parsed.processes,
                issue: parsed.complete ? nil : "The process check returned incomplete file information.")
        } catch is CancellationError { throw CancellationError() }
        catch {
            return WorktreeActivity(roots: roots, processes: [:],
                issue: GitWorktreeReview.failureReason(error, tool: "The process check"))
        }
    }

    static func parse(_ data: Data, scanProcessID: Int32? = nil)
        -> (processes: [String: Set<String>], complete: Bool, revokedFiles: Int, incompleteFiles: Int) {
        var processes: [String: Set<String>] = [:]
        let diagnostics = ScanDiagnostics.current
        let inventoryID = diagnostics == nil ? "" : UUID().uuidString
        var name = "", type = "", device = "", inode = "", fileName = ""
        var pid = "", descriptor = ""
        var revokedFiles = 0, incompleteFiles = 0
        var invalidFields = 0, issueRecords = 0, scanDescriptors = 0
        let issueLimit = 32
        let terminatedRecord = !data.isEmpty && data.last == 10
        var hasFile = false, sawProcess = false, complete = terminatedRecord
        func recordFile(_ event: String, reason: String, fields: [String: String] = [:]) {
            guard let diagnostics else { return }
            let details = ["inventory_id": inventoryID, "reason": reason, "pid": pid, "process": name,
                "descriptor": descriptor, "file_type": type, "device": device, "inode": inode, "path": fileName]
                .merging(fields, uniquingKeysWith: { _, new in new })
            var bounded = details.mapValues { String($0.prefix(1024)) }
            bounded["truncated_fields"] = details.filter { $0.value.count > 1024 }.keys.sorted().joined(separator: ",")
            diagnostics.record(event, details: bounded)
        }
        func recordIssue(_ reason: String, fields: [String: String] = [:]) {
            issueRecords += 1
            guard issueRecords <= issueLimit else { return }
            recordFile("worktree_activity_issue", reason: reason, fields: fields)
        }
        func finishFile() {
            guard hasFile else { return }
            defer { type = ""; device = ""; inode = ""; fileName = ""; descriptor = ""; hasFile = false }
            // Exclude this scanner's numbered handles. Keep its working directory and executable mappings.
            if let scanProcessID, pid == String(scanProcessID), !descriptor.isEmpty,
               descriptor.utf8.allSatisfy({ (48...57).contains($0) }) {
                scanDescriptors += 1
                if scanDescriptors <= issueLimit {
                    recordFile("worktree_activity_scan_handle", reason: "scan_process_descriptor")
                }
                return
            }
            // Darwin reports ENOENT handles as revoked without a type or identity.
            if type.isEmpty, device.isEmpty, inode.isEmpty, fileName == "(revoked)" {
                revokedFiles += 1
                return
            }
            guard type == "REG" || type == "DIR" else {
                let otherTypes: Set<String> = ["CHR", "BLK", "FIFO", "PIPE", "unix", "IPv4", "IPv6", "KQUEUE",
                                               "NPOLICY", "NEXUS", "systm", "CHAN", "PSXSEM", "PSXSHM", "FSEVENT"]
                if !otherTypes.contains(type) {
                    incompleteFiles += 1
                    recordIssue(type.isEmpty ? "missing_file_type" : "unsupported_file_type",
                        fields: ["missing_fields": type.isEmpty ? "file_type" : ""])
                }
                return
            }
            guard device.hasPrefix("0x"), let dev = UInt32(device.dropFirst(2), radix: 16),
                  let ino = UInt64(inode), !name.isEmpty else {
                incompleteFiles += 1
                let missing = [("device", device), ("inode", inode), ("process", name)]
                    .filter { $0.1.isEmpty }.map { $0.0 }
                recordIssue("invalid_file_identity", fields: ["missing_fields": missing.joined(separator: ",")])
                return
            }
            let identity = "\(Int64(Int32(bitPattern: dev))):\(ino)"
            processes[identity, default: []].insert(name)
        }
        for record in data.split(separator: 0) {
            let record = record.drop(while: { $0 == 10 })
            guard let field = record.first else { continue }
            guard let value = String(bytes: record.dropFirst(), encoding: .utf8) else {
                complete = false
                invalidFields += 1
                recordIssue("invalid_utf8", fields: ["field": String(UnicodeScalar(field))])
                continue
            }
            switch field {
            case 112: // Process identifier.
                finishFile()
                sawProcess = true
                name = ""
                pid = value
            case 99: name = value
            case 102: // File descriptor.
                finishFile()
                hasFile = true
                descriptor = value
            case 116: type = value
            case 68: device = value
            case 105: inode = value
            case 110: fileName = value
            default: break
            }
        }
        finishFile()
        complete = complete && sawProcess && incompleteFiles == 0
        diagnostics?.record("worktree_activity_inventory", details: [
            "inventory_id": inventoryID, "file_identities": "\(processes.count)", "complete": "\(complete)",
            "revoked_files": "\(revokedFiles)", "incomplete_files": "\(incompleteFiles)",
            "scan_process_id": scanProcessID.map(String.init) ?? "",
            "scan_descriptors_excluded": "\(scanDescriptors)",
            "scan_descriptor_records_logged": "\(min(scanDescriptors, issueLimit))",
            "scan_descriptor_records_omitted": "\(max(0, scanDescriptors - issueLimit))",
            "invalid_utf8_fields": "\(invalidFields)", "terminated_record": "\(terminatedRecord)",
            "process_record_found": "\(sawProcess)", "issue_records_logged": "\(min(issueRecords, issueLimit))",
            "issue_records_omitted": "\(max(0, issueRecords - issueLimit))"
        ])
        return (processes, complete, revokedFiles, incompleteFiles)
    }

    func observe(_ url: URL, values: URLResourceValues, attribution: [URL]) {
        let owners = attribution.filter { roots.contains($0) }
        guard !owners.isEmpty, issue == nil else { return }
        let names: Set<String>?
        if let volume = values.volumeIdentifier as? NSObject,
           let files = processesByVolume[volume], let inode = values.fileIdentifier {
            names = files[inode]
        } else {
            // Preserve identity checks when the filesystem cannot prefetch the inode.
            lock.withLock { identityFallbacks += 1 }
            guard let identity = FileIdentity.of(url) else {
                lock.withLock { unreadable.formUnion(owners) }
                return
            }
            names = processes[identity]
        }
        guard let names else { return }
        lock.withLock {
            for root in owners { matches[root, default: []].formUnion(names) }
        }
    }

    func check(_ root: URL, measurement: SizeMeasurement?) -> GitWorktreeReview.Check {
        lock.withLock {
            if let names = matches[root], !names.isEmpty { return .found(names.sorted().joined(separator: ", ")) }
            if let issue { return .unknown(issue) }
            guard let measurement, measurement.unreadableCount == 0, !unreadable.contains(root) else {
                return .unknown("Some worktree files could not be checked for open processes.")
            }
            return .clear
        }
    }
}
