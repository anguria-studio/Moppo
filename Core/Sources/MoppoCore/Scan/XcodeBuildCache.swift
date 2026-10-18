import Foundation
import Darwin

/// Finds removable cache children while preserving the rest of a build folder.
public enum XcodeBuildCache {
    public struct Review: Sendable, Equatable {
        public let url: URL
        public let root: URL
        let rootIdentity: String
        let cacheIdentity: String
        let workspacePath: String

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
                    let caches = reviews(in: child)
                    if !caches.isEmpty { found += caches }
                    else if depth < 2, !["node_modules", "SourcePackages", "vendor"].contains(child.lastPathComponent) {
                        try walk(child, depth: depth + 1)
                    }
                }
            }
            try walk(root, depth: 1)
        }
        return found.filter { !excluded($0.url, context: context) }
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
                found += reviews(in: release)
                found += reviews(in: release.appendingPathComponent("DerivedData", isDirectory: true))
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

    static func isCurrent(_ review: Review) -> Bool {
        cacheNames.contains(review.url.lastPathComponent)
            && review.url.deletingLastPathComponent().standardizedFileURL.path == review.root.path
            && ownedDirectory(review.root) && ownedDirectory(review.url)
            && FileIdentity.of(review.root) == review.rootIdentity
            && FileIdentity.of(review.url) == review.cacheIdentity
            && workspacePath(in: review.root) == review.workspacePath
    }

    static func measureForRemoval(_ review: Review, with measurer: AllocatedSizeMeasurer,
        capture: @Sendable ([URL]) async throws -> WorktreeActivity = { try await WorktreeActivity.capture(roots: $0) }
    ) async throws -> SizeMeasurement? {
        guard isCurrent(review) else { return nil }
        let activity = try await capture([review.url])
        let measurements = try await measurer.measure(review.url, retaining: []) {
            activity.observe($0, values: $1, attribution: $2)
        }
        guard let measured = measurements[review.url], !measured.containsProtectedPattern,
              !measured.containsCloudOnlyItem, activity.check(review.url, measurement: measured) == .clear,
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
