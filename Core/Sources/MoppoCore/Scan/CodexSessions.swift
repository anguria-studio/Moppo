import Foundation
import Darwin

/// Reads session metadata. Codex owns deletion and database changes.
struct CodexSessions: Sendable {
    let home: URL
    let executable: String?
    private let runner = ProcessRunner()

    init(home: URL, executable: String? = nil) {
        self.home = home
        self.executable = executable ?? Self.resolveExecutable()
    }

    private struct Record: Decodable {
        let kind: String
        let id: String
        let path: String?
        let name: String?
        let parent: String?
    }

    private struct Snapshot {
        let records: [String: Record]
        let children: [String: [String]]
        let files: [String: [CodexSessionReview.Member]]
        let unsupportedIDs: Set<String>
        let openPaths: Set<String>

        func subtree(_ id: String) -> [String]? {
            var result: [String] = []
            var pending = [id]
            var seen: Set<String> = []
            while let next = pending.popLast() {
                guard seen.insert(next).inserted, records[next] != nil else { return nil }
                result.append(next)
                pending.append(contentsOf: children[next] ?? [])
            }
            return result.sorted()
        }

        func review(_ id: String, home: URL) -> CodexSessionReview? {
            guard let ids = subtree(id) else { return nil }
            var members: [CodexSessionReview.Member] = []
            for id in ids {
                guard !unsupportedIDs.contains(id), let record = records[id], let path = record.path,
                      let candidates = files[id], candidates.count == 1,
                      candidates[0].url.path == path,
                      candidates[0].url.lastPathComponent.hasPrefix("rollout-"),
                      candidates[0].url.lastPathComponent.hasSuffix(id + ".jsonl") else { return nil }
                members.append(candidates[0])
            }
            return CodexSessionReview(codexHome: home, threadID: id, members: members)
        }
    }

    enum Failure: Error { case unavailable, changed, active }
    struct PartialDeletion: Error {
        let members: [CodexSessionReview.Member]
    }

    static func resolveExecutable() -> String? {
        let userHome = NSHomeDirectory()
        let applications = ["/Applications", userHome + "/Applications"]
        let bundled = applications.flatMap { root in
            ["ChatGPT", "Codex"].map { root + "/\($0).app/Contents/Resources/codex-cli/bin/codex" }
        }
        return (bundled + ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", userHome + "/.local/bin/codex"])
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func supportsDeletion() async -> Bool {
        guard let executable,
              let data = try? await runner.run(executable, ["delete", "--help"], timeout: .seconds(10), allowsInput: false)
        else { return false }
        let help = String(decoding: data, as: UTF8.self)
        return help.contains("Permanently delete a saved session") && help.contains("--force")
    }

    /// An unknown schema, path, or file format keeps the corresponding storage locked.
    private func snapshot() async throws -> Snapshot {
        let database = home.appendingPathComponent("state_5.sqlite")
        guard owned(database), FileManager.default.fileExists(atPath: database.path) else { throw Failure.unavailable }
        let databases = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
        guard databases.map(\.path) == [database.path] else { throw Failure.unavailable }
        let query = """
        BEGIN;
        SELECT 'thread' AS kind, id, rollout_path AS path,
               COALESCE(NULLIF(name, ''), NULLIF(title, ''), id) AS name, NULL AS parent FROM threads
        UNION ALL
        SELECT 'edge', child_thread_id, NULL, NULL, parent_thread_id FROM thread_spawn_edges;
        COMMIT;
        """
        let data = try await runner.run("/usr/bin/sqlite3", ["-readonly", "-json", "-cmd", ".timeout 1000", database.path, query],
                                        timeout: .seconds(10), allowsInput: false)
        let rows = try JSONDecoder().decode([Record].self, from: data)
        var records: [String: Record] = [:]
        var children: [String: [String]] = [:]
        for row in rows {
            guard UUID(uuidString: row.id) != nil else { throw Failure.unavailable }
            if row.kind == "thread" {
                guard records.updateValue(row, forKey: row.id) == nil else { throw Failure.unavailable }
            } else if row.kind == "edge", let parent = row.parent {
                children[parent, default: []].append(row.id)
            } else { throw Failure.unavailable }
        }
        var files: [String: [CodexSessionReview.Member]] = [:]
        var unsupportedIDs: Set<String> = []
        for directory in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(directory)
            guard owned(root) else { continue }
            var failedRead = false
            guard let walk = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                errorHandler: { _, _ in failedRead = true; return true }) else { continue }
            while let url = walk.nextObject() as? URL {
                try Task.checkCancellation()
                guard owned(url) else { throw Failure.unavailable }
                if url.lastPathComponent.hasSuffix(".jsonl.zst") {
                    let stem = String(url.lastPathComponent.dropLast(".jsonl.zst".count))
                    let id = String(stem.suffix(36))
                    if UUID(uuidString: id) != nil { unsupportedIDs.insert(id) }
                    continue
                }
                guard url.pathExtension == "jsonl", let member = readMember(url) else { continue }
                files[member.threadID, default: []].append(member)
            }
            guard !failedRead else { throw Failure.unavailable }
        }
        let openPaths = try await openHistoryPaths()
        return Snapshot(records: records, children: children, files: files, unsupportedIDs: unsupportedIDs, openPaths: openPaths)
    }

    /// Protects open history files, including clients that predate Codex writer locks.
    private func openHistoryPaths() async throws -> Set<String> {
        let roots = ["sessions", "archived_sessions"].map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !roots.isEmpty else { return [] }
        let data = try await runner.run("/usr/sbin/lsof",
            ["-n", "-P", "-Fpn"] + roots.flatMap { ["+D", $0.path] }, timeout: .seconds(5),
            allowsInput: false, additionalSuccessExitStatuses: [1])
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { $0.hasPrefix("n") }.map { URL(fileURLWithPath: String($0.dropFirst())).standardizedFileURL.path })
    }

    private func owned(_ url: URL) -> Bool {
        let base = home.path
        let path = url.path
        guard path.hasPrefix(base + "/"), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              let canonical = realpath(home.path, nil) else { return false }
        defer { free(canonical) }
        guard String(cString: canonical) == base else { return false }
        var current = home
        for part in path.dropFirst(base.count + 1).split(separator: "/") {
            current.appendPathComponent(String(part))
            guard let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return false }
        }
        return true
    }

    /// Reads only the first session metadata record, with a fixed size limit.
    private func readMember(_ url: URL) -> CodexSessionReview.Member? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]),
              values.isRegularFile == true, let date = values.contentModificationDate,
              let size = values.fileSize, let identity = FileIdentity.of(url),
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var header = Data()
        while header.count < 65_536 {
            guard let chunk = try? handle.read(upToCount: 4096), !chunk.isEmpty else { return nil }
            header.append(chunk)
            if let newline = header.firstIndex(of: 10) {
                guard let object = try? JSONSerialization.jsonObject(with: header.prefix(upTo: newline)) as? [String: Any],
                      object["type"] as? String == "session_meta",
                      let payload = object["payload"] as? [String: Any], let id = payload["id"] as? String,
                      UUID(uuidString: id) != nil else { return nil }
                return .init(threadID: id, url: url, identity: identity, modifiedAt: date, fileSize: size)
            }
        }
        return nil
    }

    /// A held writer lock protects the complete deletion group.
    private func isInactive(_ review: CodexSessionReview, openPaths: Set<String>) -> Bool {
        for member in review.members {
            if openPaths.contains(member.url.standardizedFileURL.path) { return false }
            let path = home.appendingPathComponent("thread-writer-locks/\(member.threadID).lock")
            var info = stat()
            if lstat(path.path, &info) != 0 {
                if errno == ENOENT { continue }
                return false
            }
            guard owned(path) else { return false }
            let descriptor = open(path.path, O_RDWR | O_NOFOLLOW)
            guard descriptor >= 0 else { return false }
            let locked = flock(descriptor, LOCK_EX | LOCK_NB) == 0
            if locked { _ = flock(descriptor, LOCK_UN) }
            close(descriptor)
            if !locked { return false }
        }
        return true
    }

    func scan(context: ScanContext) async throws -> [FileEntry]? {
        guard await supportsDeletion() else { return nil }
        let snapshot = try await snapshot()
        var groups: [String: FileEntry] = [:]
        for name in ["sessions", "archived_sessions"] {
            let url = home.appendingPathComponent(name)
            guard owned(url), !context.isExcluded(url) else { continue }
            let size = try await context.measurer.measure(url)
            guard size.allocatedBytes > 0, size.unreadableCount == 0, !size.containsProtectedPattern else { continue }
            groups[name] = FileEntry(url: url,
                displayName: name == "sessions" ? "Codex sessions" : "Codex archived sessions", kind: .folder,
                allocatedBytes: size.allocatedBytes, protectionReason: .inventory,
                protectionExplanation: "Review inactive conversations below. Active sessions and unknown files stay protected.", aiTool: .codex)
        }
        let childIDs = Set(snapshot.children.values.flatMap { $0 })
        let roots = snapshot.records.keys.filter { !childIDs.contains($0) }.sorted()
        for id in roots {
            guard let review = snapshot.review(id, home: home), let root = snapshot.records[id],
                  let primary = review.members.first(where: { $0.threadID == id }) else { continue }
            var sizes: [String: Int64] = [:]
            var permitted = true
            for member in review.members {
                let folder = member.url.path.hasPrefix(home.appendingPathComponent("archived_sessions").path + "/")
                    ? "archived_sessions" : "sessions"
                guard groups[folder] != nil, !context.isExcluded(member.url) else { permitted = false; break }
                let size = try await context.measurer.measure(member.url)
                guard size.unreadableCount == 0, !size.containsProtectedPattern,
                      readMember(member.url) == member else { permitted = false; break }
                sizes[folder, default: 0] += size.allocatedBytes
            }
            guard permitted, sizes.allSatisfy({ groups[$0.key]!.allocatedBytes >= $0.value }) else { continue }
            let folder = primary.url.path.hasPrefix(home.appendingPathComponent("archived_sessions").path + "/")
                ? "archived_sessions" : "sessions"
            let inactive = isInactive(review, openPaths: snapshot.openPaths)
            let row = FileEntry(url: primary.url, displayName: root.name ?? id, kind: .file,
                allocatedBytes: sizes.values.reduce(0, +), lastOpened: primary.modifiedAt,
                protectionReason: inactive ? .userData : .inventory,
                protectionExplanation: inactive ? review.warning : "This session or a child session is in use. Close the session, then scan again.",
                codexSession: review)
            for (key, bytes) in sizes { groups[key]!.allocatedBytes -= bytes }
            groups[folder]!.children.append(row)
        }
        return groups.values.sorted { $0.displayName < $1.displayName }.map { group in
            var group = group
            group.children.sort { $0.displayBytes > $1.displayBytes }
            return group
        }
    }

    func remove(_ review: CodexSessionReview) async throws {
        guard review.codexHome == home, let executable, await supportsDeletion() else { throw Failure.unavailable }
        let current = try await snapshot()
        guard current.review(review.threadID, home: home) == review else { throw Failure.changed }
        guard isInactive(review, openPaths: current.openPaths) else { throw Failure.active }
        do {
            _ = try await runner.run(executable, ["delete", "--force", review.threadID], timeout: .seconds(60),
                                     environment: ["CODEX_HOME": home.path], allowsInput: false)
            guard review.members.allSatisfy({ !FileManager.default.fileExists(atPath: $0.url.path) }) else { throw Failure.changed }
        } catch {
            let removed = review.members.filter { member in
                var info = stat()
                return lstat(member.url.path, &info) != 0 && errno == ENOENT
            }
            if !removed.isEmpty { throw PartialDeletion(members: removed) }
            throw error
        }
    }
}
