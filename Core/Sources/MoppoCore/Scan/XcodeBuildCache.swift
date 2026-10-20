import Foundation
import Darwin

/// Reviews build folders and their separately removable contents.
public enum XcodeBuildCache {
    public struct Review: Sendable, Equatable {
        public let url: URL
        public let root: URL
        let rootIdentity: String
        let cacheIdentity: String
        let workspacePath: String
        var reviewedContents: [String: String]? = nil
        var excludedPaths: [String] = []
        var excludedPatterns: [String] = []

        public var isWholeFolder: Bool { url == root }
        public var isRegenerable: Bool { !isWholeFolder && XcodeBuildCache.cacheNames.contains(url.lastPathComponent) }

        var projectName: String {
            let workspace = URL(fileURLWithPath: workspacePath)
            return (workspace.lastPathComponent == "project.xcworkspace"
                ? workspace.deletingLastPathComponent() : workspace).deletingPathExtension().lastPathComponent
        }
    }

    static let cacheNames: Set<String> = ["Build", "Index.noindex", "ModuleCache.noindex",
        "CompilationCache.noindex", "SDKExplicitPrecompiledModules", "SDKStatCaches.noindex"]
    static let releasePaths = ["dist/releases", "build/releases", "releases"]

    static func temporaryCaches(under roots: [URL], context: ScanContext) throws -> [Review] {
        var found: [Review] = []
        var visited: Set<String> = []
        var budget = 2_048
        for input in roots {
            guard let resolved = realpath(input.path, nil) else { continue }
            let root = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
            free(resolved)
            let logicalPath = root.standardizedFileURL.path
            guard visited.insert(root.path).inserted,
                  !context.excludedPaths.contains(where: {
                      let path = URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                      return logicalPath == path || logicalPath.hasPrefix(path + "/")
                  }) else { continue }
            func walk(_ directory: URL, depth: Int) throws {
                try Task.checkCancellation()
                guard budget > 0, let children = GeneratedWorktreeFileDetector.directoryChildren(of: directory, limit: budget + 1),
                      children.count <= budget else { return }
                budget -= children.count
                for child in children.sorted(by: { $0.path < $1.path }) {
                    try Task.checkCancellation()
                    guard ownedDirectory(child), !context.isWithinExclusion(child),
                          !context.isWithinExclusion(child.resolvingSymlinksInPath()),
                          !child.lastPathComponent.hasPrefix("."),
                          !["app", "xcarchive", "xcresult"].contains(child.pathExtension),
                          !GitWorktreeDetector.isWorktree(child) else { continue }
                    if let review = folderReview(in: child) { found.append(review) }
                    else if depth < 2, !["node_modules", "SourcePackages", "vendor"].contains(child.lastPathComponent) {
                        try walk(child, depth: depth + 1)
                    }
                }
            }
            try walk(root, depth: 1)
        }
        return found.filter { !context.isWithinExclusion($0.url) }
    }

    static func releaseCaches(under project: URL) -> [Review] {
        let project = project.standardizedFileURL
        guard !GitWorktreeDetector.isWorktree(project) else { return [] }
        let files = GeneratedWorktreeFileDetector(root: project)
        var found: [Review] = []
        for path in releasePaths {
            let container = project.appendingPathComponent(path)
            guard let releases = files.children(of: container, limit: 201), releases.count <= 200 else { continue }
            for release in releases {
                guard !Task.isCancelled, files.safeValues(release)?.isDirectory == true,
                      !GitWorktreeDetector.isWorktree(release) else { continue }
                if let review = folderReview(in: release) { found.append(review) }
                if let review = folderReview(in: release.appendingPathComponent("DerivedData", isDirectory: true)) {
                    found.append(review)
                }
            }
        }
        return found
    }

    static func reviews(in input: URL) -> [Review] {
        let root = input.standardizedFileURL
        guard ownedDirectory(root), BuildOutputDetector.isXcodeDerivedData(root),
              let workspace = workspacePath(in: root), let identity = FileIdentity.of(root) else { return [] }
        return cacheNames.sorted().compactMap { name in
            let child = root.appendingPathComponent(name, isDirectory: true)
            guard ownedDirectory(child), let cacheIdentity = FileIdentity.of(child) else { return nil }
            return Review(url: child, root: root, rootIdentity: identity,
                          cacheIdentity: cacheIdentity, workspacePath: workspace)
        }
    }

    static func folderReview(in input: URL) -> Review? {
        let root = input.standardizedFileURL
        guard ownedDirectory(root), let workspace = workspacePath(in: root),
              let identity = FileIdentity.of(root) else { return nil }
        return Review(url: root, root: root, rootIdentity: identity, cacheIdentity: identity, workspacePath: workspace)
    }

    struct Inspection {
        var children: [URL] = []
        var contents: [String: String] = [:]
        var issues: [URL: String] = [:]
        var isComplete = true

        func issue(for url: URL) -> String? {
            if !isComplete { return "Folder contents could not be checked completely. Scan again before removal." }
            return issues.sorted { $0.key.path < $1.key.path }.first {
                $0.key == url || $0.key.path.hasPrefix(url.path + "/")
            }?.value
        }

        func review(for url: URL, in folder: Review, context: ScanContext) -> Review? {
            guard issue(for: url) == nil, let identity = FileIdentity.of(url),
                  url == folder.root || url.lastPathComponent == "Logs" || url.lastPathComponent == "TestResults"
                    || url.lastPathComponent == "info.plist"
                    || cacheNames.contains(url.lastPathComponent) else { return nil }
            var review = Review(url: url, root: folder.root, rootIdentity: folder.rootIdentity,
                                cacheIdentity: identity, workspacePath: folder.workspacePath)
            if !review.isRegenerable {
                review.reviewedContents = contents.filter { $0.key == url.path || $0.key.hasPrefix(url.path + "/") }
            }
            review.excludedPaths = context.excludedPaths
            review.excludedPatterns = context.excludedPatterns
            return review
        }
    }

    /// Checks names, ownership, links, exclusions, and file identities within a bounded tree.
    static func inspect(_ folder: Review, scope: URL? = nil, context: ScanContext) throws -> Inspection {
        var result = Inspection()
        var rootInfo = stat()
        guard lstat(folder.root.path, &rootInfo) == 0 else { result.isComplete = false; return result }
        var budget = 200_000
        func walk(_ url: URL, depth: Int) throws {
            try Task.checkCancellation()
            guard budget > 0, depth <= 128 else { result.isComplete = false; return }
            budget -= 1
            var info = stat()
            guard lstat(url.path, &info) == 0 else { result.isComplete = false; return }
            let directory = info.st_mode & S_IFMT == S_IFDIR
            let regular = info.st_mode & S_IFMT == S_IFREG
            let relative = Array(url.pathComponents.dropFirst(folder.root.pathComponents.count))
            result.contents[url.path] = "\(info.st_dev):\(info.st_ino):\(info.st_mode):\(info.st_uid):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec)"
            if context.isExcluded(url) || excluded(url, context: context) {
                result.issues[url] = "This folder contains excluded items. Remove other verified children separately."
            }
            if info.st_mode & S_IFMT == S_IFLNK, relative.count > 1,
               let first = relative.first, cacheNames.contains(first), info.st_uid == getuid() {
                let cache = folder.root.appendingPathComponent(first).resolvingSymlinksInPath().path
                let target = url.resolvingSymlinksInPath().path
                if (target == cache || target.hasPrefix(cache + "/")), FileIdentity.of(url.resolvingSymlinksInPath()) != nil {
                    return
                }
            }
            guard (directory || regular), info.st_uid == getuid(), info.st_dev == rootInfo.st_dev else {
                result.issues[url] = "This folder contains links, special files, or files with another owner or volume."
                return
            }
            if !recognized(relative, isDirectory: directory, root: folder.root) {
                result.issues[url] = "This folder contains unverified files. You can remove verified child items separately."
            }
            guard directory else { return }
            guard let children = GeneratedWorktreeFileDetector.directoryChildren(of: url, limit: budget + 1),
                  children.count <= budget else { result.isComplete = false; return }
            if url == folder.root { result.children = children.sorted { $0.lastPathComponent < $1.lastPathComponent } }
            for child in children { try walk(child, depth: depth + 1) }
        }
        try walk(scope ?? folder.root, depth: 0)
        return result
    }

    private static func recognized(_ path: [String], isDirectory: Bool, root: URL) -> Bool {
        guard let first = path.first else { return isDirectory }
        if cacheNames.contains(first) { return path.count > 1 || isDirectory }
        if first == "info.plist" { return path.count == 1 && !isDirectory }
        if first == "TestResults" {
            if path.count == 1 { return isDirectory }
            guard path == ["TestResults", "metadata.db"], !isDirectory,
                  let data = GeneratedWorktreeFileDetector(root: root).read(
                    root.appendingPathComponent("TestResults/metadata.db"), limit: 4 * 1024 * 1024),
                  let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { return false }
            return Set(metadata.keys) == ["FormatVersion", "Store"]
                && metadata["FormatVersion"] as? Int == 1 && metadata["Store"] is [String: Any]
        }
        guard first == "Logs" else { return false }
        if path.count == 1 { return isDirectory }
        guard ["Build", "Launch", "Localization", "Package", "Test"].contains(path[1]) else { return false }
        if path.count == 2 { return isDirectory }
        if path[1] == "Test", path[2].hasSuffix(".xcresult") { return path.count > 3 || isDirectory }
        return path.count == 3 && !isDirectory
            && (path[2] == "LogStoreManifest.plist" || path[2].hasSuffix(".xcactivitylog"))
    }

    static func isCurrent(_ review: Review) -> Bool {
        guard ownedDirectory(review.root), FileIdentity.of(review.root) == review.rootIdentity,
              FileIdentity.of(review.url) == review.cacheIdentity,
              workspacePath(in: review.root) == review.workspacePath else { return false }
        if review.isWholeFolder { return review.reviewedContents != nil }
        guard review.url.deletingLastPathComponent().standardizedFileURL == review.root else { return false }
        if review.url.lastPathComponent == "info.plist" {
            var info = stat()
            return lstat(review.url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG && info.st_uid == getuid()
        }
        return (cacheNames.contains(review.url.lastPathComponent)
            || ["Logs", "TestResults"].contains(review.url.lastPathComponent))
            && ownedDirectory(review.url)
    }

    static func measureForRemoval(_ review: Review, with measurer: AllocatedSizeMeasurer,
        capture: @Sendable ([URL]) async throws -> WorktreeActivity = { try await WorktreeActivity.capture(roots: $0) }
    ) async throws -> SizeMeasurement? {
        guard isCurrent(review) else { return nil }
        let context = ScanContext(excludedPaths: review.excludedPaths, excludedPatterns: review.excludedPatterns)
        let before = try inspect(review, scope: review.url, context: context)
        guard before.issue(for: review.url) == nil,
              review.reviewedContents.map({ $0 == before.contents }) ?? true else { return nil }
        let activity = try await capture([review.url])
        var measurer = measurer
        measurer.followSymlinks = false
        measurer.detectCloudOnlyItems = true
        measurer.protectedPatterns = Array(Set(measurer.protectedPatterns + review.excludedPatterns))
        let measurements = try await measurer.measure(review.url, retaining: []) {
            activity.observe($0, values: $1, attribution: $2)
        }
        let after = try inspect(review, scope: review.url, context: context)
        guard let measured = measurements[review.url], measured.unreadableCount == 0,
              !measured.containsProtectedPattern, !measured.containsCloudOnlyItem,
              activity.check(review.url, measurement: measured) == .clear,
              after.issue(for: review.url) == nil, before.contents == after.contents,
              isCurrent(review) else { return nil }
        return measured
    }

    private static func workspacePath(in root: URL) -> String? {
        let files = GeneratedWorktreeFileDetector(root: root)
        guard let data = files.read(root.appendingPathComponent("info.plist"), limit: 64 * 1024),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let path = info["WorkspacePath"] as? String, path.hasPrefix("/"), !path.contains("\0"),
              ["xcodeproj", "xcworkspace"].contains(URL(fileURLWithPath: path).pathExtension) else { return nil }
        return path
    }

    private static func ownedDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
    }

    static func excluded(_ url: URL, context: ScanContext) -> Bool {
        context.isExcluded(url) || context.isExcluded(url.resolvingSymlinksInPath())
            || context.excludedPaths.contains { path in
                let excluded = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
                return url.path == excluded || url.path.hasPrefix(excluded + "/") || excluded.hasPrefix(url.path + "/")
            }
    }
}
