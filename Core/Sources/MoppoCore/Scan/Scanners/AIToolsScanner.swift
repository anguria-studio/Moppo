import Foundation

/// Shows AI storage without treating task data or installed runtimes as disposable caches.
public struct AIToolsScanner: CategoryScanner {
    public let id: CategoryID = .aiTools
    private let home: URL
    private let codexExecutable: String?

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
            + LocalModelStores.homeDotFolders.map { home.appendingPathComponent($0).path }
            + LocalModelStores.dotCacheFolders.map { home.appendingPathComponent(".cache/" + $0).path }
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

        for model in LocalModelStores.all(home: home, context: context) {
            try Task.checkCancellation()
            guard ([model.primary] + model.exclusive).allSatisfy({ !context.isExcluded($0) && isOwnedPath($0) }) else { continue }
            let own = try await context.measurer.measure(model.primary)
            found.unreadableCount += own.unreadableCount
            guard !own.containsProtectedPattern else { continue }

            var children: [FileEntry] = []
            var protectsModel = own.unreadableCount > 0
            for url in model.exclusive {
                let size = try await context.measurer.measure(url)
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
                allocatedBytes: own.allocatedBytes,
                lastOpened: children.compactMap(\.lastOpened).max()
                    ?? lastOpenedDate(for: model.primary),
                childCount: children.isEmpty ? nil : children.count,
                children: children
            )
            row.removesAsUnit = true
            row.localModelPaths = model.memberPaths
            let owner: AIStorageSection.Owner? = switch model.runtime {
            case "Ollama": .ollama
            case "Hugging Face": .huggingFace
            case "LM Studio": .lmStudio
            default: nil
            }
            if let owner {
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

    private struct Found {
        var entries: [FileEntry] = []
        var unreadableCount = 0
    }
}
