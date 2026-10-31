import Foundation

/// Shows AI storage without treating task data or installed runtimes as disposable caches.
public struct AIToolsScanner: CategoryScanner {
    public let id: CategoryID = .aiTools
    private let home: URL
    private let codexExecutable: String?
    /// Reads open model files. Tests replace the process check.
    var captureModelActivity: @Sendable ([URL]) async throws -> WorktreeActivity = {
        try await WorktreeActivity.capture(roots: $0)
    }

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
        self.codexExecutable = nil
    }

    init(home: URL, codexExecutable: String) {
        self.home = home
        self.codexExecutable = codexExecutable
    }

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        var found = Found()
        for root in AIToolStorage.roots {
            try Task.checkCancellation()
            let url = home.appendingPathComponent(root.path)
            guard !context.isWithinExclusion(url), isOwnedPath(url),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            let parts = root.parts.map { (part: $0, paths: ApplicationsScanner.expand($0.path, under: url)) }
            let roots: [URL]
            if root.reviewsWorktrees {
                roots = try GitWorktreeDetector.isWorktree(url)
                    ? [url] : GitWorktreeDetector.roots(under: url, context: context)
            } else {
                roots = []
            }
            let worktrees = try await WorktreeScan.prepare(roots)
            let measured = try await worktrees.measure(url, with: context.measurer, retaining: parts.flatMap(\.paths))
            let total = measured.measurements[url.standardizedFileURL] ?? .zero
            found.unreadableCount += total.unreadableCount
            guard total.allocatedBytes > 0, !total.containsProtectedPattern else { continue }

            var entry = FileEntry(
                url: url, displayName: root.name, kind: .folder,
                allocatedBytes: total.allocatedBytes, lastOpened: lastOpenedDate(for: url),
                protectionReason: .inventory,
                protectionExplanation: root.explanation,
                aiTool: root.tool, aiStorageSection: root.section
            )
            if let identifier = root.curationIdentifier,
               let curation = ApplicationsScanner.curation(bundleID: identifier, baseName: root.tool.rawValue, home: home),
               home.appendingPathComponent(curation.root).standardizedFileURL == url.standardizedFileURL {
                for pattern in curation.regenerable {
                    for cache in ApplicationsScanner.expand(pattern, under: url) {
                        guard let child = try await measuredPart(cache, context: context) else { continue }
                        var row = child
                        row.kind = .cache
                        row.isRegenerable = true
                        row.inUseBy = root.curationIdentifier.flatMap { context.runningOwner(bundleIdentifier: $0) }
                            ?? context.runningOwner(ofCacheNamed: url.lastPathComponent)
                        append(row, to: &entry)
                    }
                }
            }
            var sessionGroups: [FileEntry] = []
            if root.path == ".codex",
               let groups = try? await CodexSessions(home: url, executable: codexExecutable).scan(context: context),
               groups.reduce(0, { $0 + $1.displayBytes }) <= entry.allocatedBytes {
                sessionGroups = groups
                entry.allocatedBytes -= groups.reduce(0) { $0 + $1.displayBytes }
                found.entries.append(contentsOf: groups)
            }
            for (part, paths) in parts {
                if sessionGroups.contains(where: { $0.url == url.appendingPathComponent(part.path) }) { continue }
                for path in paths {
                    guard var child = try await measuredPart(path, context: context,
                        measurement: measured.measurements[path.standardizedFileURL] ?? .zero) else { continue }
                    child.displayName = part.name
                    child.protectionReason = .inventory
                    child.protectionExplanation = part.explanation
                    append(child, to: &entry)
                }
            }
            if root.reviewsWorktrees {
                entry = try await GitWorktreeDetector.addingWorktrees(to: entry, context: context, prepared: measured)
            }
            found.entries.append(entry)
        }
        try await appendLocalModels(context: context, to: &found)
        found.entries.sort { $0.displayBytes > $1.displayBytes }
        var result = ScanCategoryResult(
            categoryID: id, totalBytes: found.entries.reduce(0) { $0 + $1.displayBytes },
            entries: found.entries,
            availability: found.entries.isEmpty
                ? (found.unreadableCount == 0 ? .empty : .unavailable(reason: "Moppo could not read AI storage. Check file access in System Settings."))
                : .available,
            unreadableCount: found.unreadableCount
        )
        result.claimedStoragePaths = AIToolStorage.roots.map { home.appendingPathComponent($0.path).path }
            + LocalModelStores.claimedPaths(home: home)
        return result
    }

    /// Rejects symlinks in each component, including a parent of an expanded cache path.
    private func isOwnedPath(_ url: URL) -> Bool {
        let root = home.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return false }
        var componentURL = home
        for component in path.dropFirst(root.count + 1).split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            guard let values = try? componentURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
                  values.isSymbolicLink != true else { return false }
        }
        return true
    }

    private func measuredPart(_ url: URL, context: ScanContext,
                              measurement: SizeMeasurement? = nil) async throws -> FileEntry? {
        try Task.checkCancellation()
        guard !context.isExcluded(url), isOwnedPath(url) else { return nil }
        let size: SizeMeasurement
        if let measurement { size = measurement }
        else { size = try await context.measurer.measure(url) }
        guard size.allocatedBytes > 0, size.unreadableCount == 0, !size.containsProtectedPattern else { return nil }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
        return FileEntry(
            url: url, kind: values?.isDirectory == true ? .folder : .file,
            allocatedBytes: size.allocatedBytes, lastOpened: lastOpenedDate(for: url)
        )
    }

    /// Subtracts disclosed bytes from the protected remainder. Each path appears once.
    private func append(_ child: FileEntry, to entry: inout FileEntry) {
        guard !entry.children.contains(where: { ApplicationsScanner.overlaps($0.url.path, child.url.path) }) else { return }
        var child = child
        child.allocatedBytes = min(child.allocatedBytes, entry.allocatedBytes)
        guard child.allocatedBytes > 0 else { return }
        entry.allocatedBytes -= child.allocatedBytes
        entry.children.append(child)
    }

    private func appendLocalModels(
        context: ScanContext, to found: inout Found
    ) async throws {
        let huggingFace = home.appendingPathComponent(".cache/huggingface")
        let ollama = home.appendingPathComponent(".ollama/models", isDirectory: true)
        if !context.isExcluded(ollama), isOwnedPath(ollama),
           FileManager.default.fileExists(atPath: ollama.path) {
            let measurement = try await context.measurer.measure(ollama)
            found.unreadableCount += measurement.unreadableCount
            if measurement.allocatedBytes > 0, !measurement.containsProtectedPattern {
                let explanation = "Moppo cannot verify all Ollama model references or active models. Use Ollama to manage these files."
                found.entries.append(FileEntry(
                    url: ollama, displayName: "Ollama models", kind: .folder,
                    allocatedBytes: measurement.allocatedBytes, lastOpened: lastOpenedDate(for: ollama),
                    protectionReason: .inventory, protectionExplanation: explanation,
                    aiTool: .ollama,
                    aiStorageSection: .init(owner: .ollama, title: "Models", summary: explanation)
                ))
            }
        }

        let models = LocalModelStores.all(home: home, context: context).filter { model in
            ([model.primary] + model.exclusive).allSatisfy { !context.isExcluded($0) && isOwnedPath($0) }
        }
        // LM Studio can link to Hugging Face files without a matching model row.
        let links = models.isEmpty ? LocalModelStores.ExternalLinks() : LocalModelStores.lmStudioLinks(home: home)
        let activity = models.isEmpty ? nil : try await captureModelActivity(models.map(\.primary))
        var countedInodes: Set<String> = []
        for model in models {
            try Task.checkCancellation()
            guard let activity else { break }
            let files = ModelFiles(owner: model.primary, activity: activity)
            let own = try await files.measure(model.primary, with: context.measurer)
            found.unreadableCount += own.unreadableCount
            guard !own.containsProtectedPattern else { continue }

            var children: [FileEntry] = []
            var protectsModel = own.unreadableCount > 0
            for url in model.exclusive {
                let size = try await files.measure(url, with: context.measurer)
                found.unreadableCount += size.unreadableCount
                protectsModel = protectsModel || size.containsProtectedPattern || size.unreadableCount > 0
                children.append(FileEntry(
                    url: url, kind: .file, allocatedBytes: size.allocatedBytes,
                    lastOpened: lastOpenedDate(for: url)
                ))
            }
            // A partial measurement cannot support model removal. Empty models have no removal target.
            guard !protectsModel else { continue }
            let total = own.allocatedBytes + children.reduce(0) { $0 + $1.allocatedBytes }
            guard total > 0 else { continue }

            // Count each hard-linked file once across model rows.
            var ownBytes = own.allocatedBytes
            for link in files.hardLinks where !countedInodes.insert(link.identity).inserted {
                if link.root == model.primary.standardizedFileURL {
                    ownBytes = max(0, ownBytes - link.bytes)
                } else if let index = children.firstIndex(where: { $0.url.standardizedFileURL == link.root }) {
                    children[index].allocatedBytes = max(0, children[index].allocatedBytes - link.bytes)
                }
            }
            let targetsChecked = files.observeLinkTargets()
            var check = activity.check(model.primary, measurement: own)
            if check == .clear, !targetsChecked { check = .unknown("Some link targets could not be checked.") }
            let (reason, explanation) = Self.protection(for: model, files: files, links: links, activity: check)

            var qualifier = model.memberNames.count == 1
                ? "\(model.runtime) model"
                : "\(model.memberNames.count) \(model.runtime) models that share their weights: "
                    + model.memberNames.joined(separator: ", ")
            qualifier += " · " + FileEntry.abbreviate(model.primary.deletingLastPathComponent().path)
            if model.sharedBytes > 0 {
                qualifier += " · \(ByteFormatting.string(model.sharedBytes)) shared with another model stays"
            }
            let isFolder = (try? model.primary.resourceValues(forKeys: [.isDirectoryKey]))?
                .isDirectory == true
            var row = FileEntry(
                url: model.primary,
                displayName: model.name,
                parentDisplay: qualifier,
                kind: isFolder ? .folder : .file,
                allocatedBytes: ownBytes,
                lastOpened: children.compactMap(\.lastOpened).max()
                    ?? lastOpenedDate(for: model.primary),
                childCount: children.isEmpty ? nil : children.count,
                children: children
            )
            row.protectionReason = reason
            row.protectionExplanation = explanation
            row.removesAsUnit = true
            row.localModelPaths = model.memberPaths
            if let owner = AIStorageSection.Owner(rawValue: model.runtime) {
                row.aiTool = owner.tool
                row.aiStorageSection = .init(owner: owner, title: model.name, summary: qualifier)
            }
            found.entries.append(row)
        }

        // Other Hugging Face files remain protected because their contents can vary.
        let others = try await context.measurer.measureChildren(of: huggingFace)
        for (child, measurement) in others where child.lastPathComponent != "hub" {
            found.unreadableCount += measurement.unreadableCount
            guard !context.isExcluded(child), isOwnedPath(child),
                  measurement.allocatedBytes > 0, !measurement.containsProtectedPattern else { continue }
            found.entries.append(FileEntry(
                url: child, displayName: "Hugging Face " + child.lastPathComponent,
                kind: .folder, allocatedBytes: measurement.allocatedBytes,
                lastOpened: lastOpenedDate(for: child), protectionReason: .inventory,
                protectionExplanation: "Additional model store files. Use Hugging Face tools to manage them.",
                aiTool: .huggingFace,
                aiStorageSection: .init(owner: .huggingFace, title: child.lastPathComponent,
                    summary: "Additional model store files. Use Hugging Face tools to manage them.")
            ))
        }
    }

    /// Protects a model when Moppo cannot show that removal is safe and frees its space.
    static func protection(
        for model: LocalModel, files: ModelFiles, links: LocalModelStores.ExternalLinks,
        activity: GitWorktreeReview.Check
    ) -> (FileEntry.ProtectionReason?, String?) {
        if case .found(let names) = activity {
            return (.running, "Files are open in: \(names). Unload the model or quit the tool. Then scan again.")
        }
        if ([model.primary] + model.exclusive).contains(where: links.reach) {
            return (.inventory, "An LM Studio model links to these files. Use LM Studio to remove that model first.")
        }
        if !links.isComplete, model.runtime == "Hugging Face" {
            return (.inventory, "Moppo could not read all LM Studio links. LM Studio can use these files.")
        }
        if !files.hardLinks.isEmpty {
            return (.inventory, "Other paths share these files through hard links. Removal might not free their space.")
        }
        if activity != .clear {
            return (.inventory, "Open files could not be checked. Scan again before removal.")
        }
        return (nil, nil)
    }

    private struct Found {
        var entries: [FileEntry] = []
        var unreadableCount = 0
    }
}

/// Records link facts for one model row during its measurement.
final class ModelFiles: @unchecked Sendable {
    struct HardLink: Equatable {
        let identity: String
        /// The measured path that includes this file.
        let root: URL
        let bytes: Int64
    }

    private let owner: URL
    private let activity: WorktreeActivity
    private let lock = NSLock()
    private var linkedFiles: [HardLink] = []
    private var symbolicLinks: [URL] = []

    init(owner: URL, activity: WorktreeActivity) {
        self.owner = owner
        self.activity = activity
    }

    /// Files with more than one hard link, once for each measured path.
    var hardLinks: [HardLink] { lock.withLock { linkedFiles } }

    func measure(_ url: URL, with measurer: AllocatedSizeMeasurer) async throws -> SizeMeasurement {
        let root = url.standardizedFileURL
        // The subtree walk lists its root, so a file root is observed here.
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .linkCountKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .volumeIdentifierKey, .fileIdentifierKey]
        if let values = try? root.resourceValues(forKeys: keys), values.isDirectory != true {
            observe(root, values: values, root: root)
            return try await measurer.measure(root)
        }
        let measurements = try await measurer.measure(root, retaining: []) { [self] entry, values, _ in
            observe(entry, values: values, root: root)
        }
        return measurements[root] ?? .zero
    }

    private func observe(_ entry: URL, values: URLResourceValues, root: URL) {
        activity.observe(entry, values: values, attribution: [owner])
        if values.isSymbolicLink == true {
            lock.withLock { symbolicLinks.append(entry) }
        } else if values.isRegularFile == true, (values.linkCount ?? 1) > 1,
                  let identity = FileIdentity.of(entry) {
            let link = HardLink(identity: identity, root: root,
                                bytes: AllocatedSizeMeasurer.allocatedSize(of: values) ?? 0)
            lock.withLock { if !linkedFiles.contains(link) { linkedFiles.append(link) } }
        }
    }

    /// Checks link targets, because a runtime opens the target and not the link.
    /// Returns false when a target exists but cannot be checked. A missing target cannot be open.
    func observeLinkTargets() -> Bool {
        var checked = true
        for link in lock.withLock({ symbolicLinks }) {
            var info = stat()
            guard stat(link.path, &info) == 0 else {
                if errno != ENOENT { checked = false }
                continue
            }
            let target = link.resolvingSymlinksInPath()
            guard target.path != link.path,
                  let values = try? target.resourceValues(
                    forKeys: [.isSymbolicLinkKey, .volumeIdentifierKey, .fileIdentifierKey]),
                  values.isSymbolicLink != true
            else { checked = false; continue }
            activity.observe(target, values: values, attribution: [owner])
        }
        return checked
    }
}
