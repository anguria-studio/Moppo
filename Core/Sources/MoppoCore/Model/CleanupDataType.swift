import Foundation

/// Describes cleanup items without changing their removal rules.
public enum CleanupDataType: String, CaseIterable, Sendable, Identifiable {
    case all, worktrees, nodeModules, pythonEnvironments, archivesAndInstallers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All results"
        case .worktrees: "Worktrees"
        case .nodeModules: "Node modules"
        case .pythonEnvironments: "Python environments"
        case .archivesAndInstallers: "Archives & installers"
        }
    }

    public func matches(_ entry: FileEntry) -> Bool {
        guard self != .all else { return true }
        guard entry.url.isFileURL, entry.removalAction == nil, !entry.removesAsUnit else { return false }
        if entry.isGitWorktree { return self == .worktrees }
        let name = entry.url.lastPathComponent.lowercased()
        switch self {
        case .all: return true
        case .worktrees: return false
        case .nodeModules:
            return name == "node_modules" && (entry.kind == .folder || entry.kind == .cache)
        case .pythonEnvironments:
            return [".venv", "venv", ".tox"].contains(name) && entry.kind == .cache
        case .archivesAndInstallers:
            return entry.kind == .archive || entry.kind == .diskImage || entry.kind == .downloadedApp
                || (entry.kind == .file && entry.url.pathExtension.lowercased() == "pkg")
        }
    }

    /// Shows matching children as rows while keeping their paths and review information.
    public func rows(in entries: [FileEntry]) -> [FileEntry] {
        guard self != .all else { return entries }
        var seen = Set<FileEntry.ID>()
        return entries.flatMap { entry -> [FileEntry] in
            if matches(entry) { return [entry] }
            guard entry.removalAction == nil, !entry.removesAsUnit, entry.manualRemoval == nil,
                  entry.unlockableChildren.isEmpty else { return [] }
            return entry.children.filter(matches).map { child in
                var child = child
                if child.aiStorageSection == nil, let section = entry.aiStorageSection {
                    child.aiStorageSection = .init(owner: section.owner, title: child.displayName,
                        summary: FileEntryPresentation(entry: child).summary)
                }
                return child
            }
        }.filter { seen.insert($0.id).inserted }
    }
}
