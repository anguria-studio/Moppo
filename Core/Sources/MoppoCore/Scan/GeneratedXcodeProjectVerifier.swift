import Foundation

/// Compares generated projects in an isolated copy without running project commands.
struct GeneratedXcodeProjectVerifier {
    private let generator: String?
    private let run: @Sendable (String, [String]) async throws -> Data

    init(generator: String? = ["/opt/homebrew/bin/xcodegen", "/usr/local/bin/xcodegen"]
        .first(where: { FileManager.default.isExecutableFile(atPath: $0) }),
         run: @escaping @Sendable (String, [String]) async throws -> Data = {
             try await ProcessRunner().run($0, $1, timeout: .seconds(2),
                 environment: ["GIT_TERMINAL_PROMPT": "0"], allowsInput: false)
         }) {
        self.generator = generator
        self.run = run
    }

    func verify(_ directory: URL, ignoredPaths: [String], git: String) async throws -> Set<URL> {
        let root = directory.standardizedFileURL
        let names = Set(ignoredPaths.compactMap { path -> String? in
            guard let name = path.split(separator: "/").first, name.hasSuffix(".xcodeproj") else { return nil }
            return String(name)
        })
        guard !names.isEmpty, let generator else { return [] }
        let files = GeneratedWorktreeFileDetector(root: root)
        let specs = ["project.yml", "project.yaml", "project.json"].filter {
            files.safeValues(root.appendingPathComponent($0))?.isRegularFile == true
        }
        guard specs.count == 1, let spec = specs.first,
              let source = files.read(root.appendingPathComponent(spec), limit: 128 * 1024),
              let text = String(data: source, encoding: .utf8),
              !text.lowercased().contains("include"), !text.contains("\\") else { return [] }

        let diagnostics = ScanDiagnostics.current
        let span = diagnostics?.begin("xcode_project_verification", path: root.path)
        var outcome = "unverified"
        defer { diagnostics?.end(span, outcome: Task.isCancelled ? "cancelled" : outcome) }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
            .appendingPathComponent("moppo-project-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: scratch) }
            let listed = try await run(git, ["--no-optional-locks", "--no-lazy-fetch", "-C", root.path,
                "ls-files", "--cached", "-z", "--"])
            guard let tracked = trackedPaths(listed), tracked.contains(spec),
                  try copy(tracked, from: files, to: scratch) else { return [] }
            // Reject a changed spec before the parser can resolve any external inputs.
            guard try Data(contentsOf: scratch.appendingPathComponent(spec)) == source else { return [] }
            let arguments = ["--no-env", "--spec", scratch.appendingPathComponent(spec).path,
                             "--project-root", scratch.path]
            let resolved = try await run(generator, ["dump", "--type", "json"] + arguments)
            guard resolved.count <= 512 * 1024,
                  let object = try JSONSerialization.jsonObject(with: resolved) as? [String: Any],
                  let name = object["name"] as? String, names.contains(name + ".xcodeproj"),
                  safeName(name), safeSpec(object) else { return [] }
            // Use the validated JSON, so generation does not resolve the original YAML again.
            try resolved.write(to: scratch.appendingPathComponent(spec))
            _ = try await run(generator, ["generate", "--quiet", "--project", scratch.path] + arguments)
            let bundle = root.appendingPathComponent(name + ".xcodeproj", isDirectory: true)
            let generated = scratch.appendingPathComponent(name + ".xcodeproj", isDirectory: true)
            guard try matches(bundle, generated: generated, files: files,
                              scratchFiles: GeneratedWorktreeFileDetector(root: scratch)) else { return [] }
            outcome = "verified"
            return [bundle]
        } catch is CancellationError { throw CancellationError() }
        catch {
            diagnostics?.update(span, details: ["reason": "Generation or comparison could not complete."])
            return []
        }
    }

    private func trackedPaths(_ data: Data) -> Set<String>? {
        guard data.count <= 512 * 1024, data.last == 0 else { return nil }
        let entries = data.split(separator: 0)
        guard entries.count <= 2_048 else { return nil }
        var paths: Set<String> = []
        for entry in entries {
            guard let path = String(data: entry, encoding: .utf8), safePath(path) else { return nil }
            paths.insert(path)
        }
        return paths
    }

    private func safeName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && name != "." && name != ".." && !name.contains("\0")
    }

    private func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~") && !path.contains("\0")
            && path.split(separator: "/").allSatisfy { $0 != "." && $0 != ".." && $0 != ".git" }
    }

    private func safeSpec(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            let commands: Set<String> = ["include", "preGenCommand", "postGenCommand"]
            return object.allSatisfy { !commands.contains($0.key) && safeSpec($0.key) && safeSpec($0.value) }
        }
        if let values = value as? [Any] { return values.allSatisfy(safeSpec) }
        if let string = value as? String {
            let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.hasPrefix("/") && !text.hasPrefix("~") && !text.contains("\0")
                && !text.split(separator: "/").contains("..")
        }
        return true
    }

    private func copy(_ paths: Set<String>, from files: GeneratedWorktreeFileDetector, to scratch: URL) throws -> Bool {
        var remaining = 32 * 1024 * 1024
        let started = ContinuousClock.now
        for path in paths.sorted() {
            try Task.checkCancellation()
            guard started.duration(to: .now) < .seconds(2),
                  let data = files.read(files.root.appendingPathComponent(path), limit: min(remaining, 4 * 1024 * 1024))
            else { return false }
            remaining -= data.count
            let destination = scratch.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination)
        }
        return true
    }

    private func matches(_ bundle: URL, generated: URL, files: GeneratedWorktreeFileDetector,
                         scratchFiles: GeneratedWorktreeFileDetector) throws -> Bool {
        var budget = 128
        func emptyTree(_ directory: URL) throws -> Bool {
            try Task.checkCancellation()
            guard let entries = files.children(of: directory, limit: budget + 1), entries.count <= budget else { return false }
            budget -= entries.count
            return try entries.allSatisfy { try emptyTree($0) }
        }
        func compare(_ original: URL, _ expected: URL) throws -> Bool {
            try Task.checkCancellation()
            guard let actual = files.children(of: original, limit: budget + 1), actual.count <= budget,
                  let regenerated = scratchFiles.children(of: expected, limit: budget + 1), regenerated.count <= budget
            else { return false }
            budget -= actual.count
            var pending = Set(regenerated.map(\.lastPathComponent))
            for child in actual {
                if child.lastPathComponent == "xcuserdata", files.recognizes(child, isDirectory: true) { continue }
                if pending.remove(child.lastPathComponent) == nil {
                    guard try emptyTree(child) else { return false }
                    continue
                }
                guard let values = files.safeValues(child), let expectedValues = scratchFiles.safeValues(expected.appendingPathComponent(child.lastPathComponent))
                else { return false }
                let target = expected.appendingPathComponent(child.lastPathComponent)
                if values.isDirectory == true, expectedValues.isDirectory == true {
                    guard try compare(child, target) else { return false }
                } else {
                    guard values.isRegularFile == true, expectedValues.isRegularFile == true,
                          let data = files.read(child, limit: 4 * 1024 * 1024),
                          let expectedData = scratchFiles.read(target, limit: 4 * 1024 * 1024), data == expectedData
                    else { return false }
                }
            }
            return pending.isEmpty
        }
        return try compare(bundle, generated)
    }
}
