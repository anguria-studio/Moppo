import Foundation

/// Default paths verified in vendor sources or installed applications. See docs/ai-storage.md.
/// The `roots` table is in `Generated/ToolRules.swift`. Change a rule in `rules/<tool>.json`.
enum AIToolStorage {
    struct Part: Sendable {
        let path: String
        let name: String
        let explanation: String
    }

    struct Root: Sendable {
        /// The folder that holds `path`.
        enum Base: Sendable { case home, applications }

        let path: String
        let name: String
        let section: AIStorageSection
        var tool: FileEntry.AITool { section.owner.tool }
        var base: Base = .home
        var explanation: String = "Credentials, settings, memories, history, and installed files remain protected. Use the owning tool to manage them."
        var curationIdentifier: String? = nil
        var reviewsWorktrees: Bool = true
        /// Paths in the root that identify the tool when the folder name is not specific.
        /// Each path must exist. A glob component matches any child.
        var identifiedBy: [String] = []
        var parts: [Part] = []
    }

    static let defaultApplications = URL(fileURLWithPath: "/Applications", isDirectory: true)

    /// Home dot folders that AI Tools claims whole. Hidden & System Data does not list them.
    static let homeDotFolders: Set<String> = Set(roots.filter {
        $0.base == .home && $0.identifiedBy.isEmpty && $0.path.hasPrefix(".") && !$0.path.contains("/")
    }.map(\.path))
    static let dotCacheFolders: Set<String> = ["codex-runtimes"]

    /// `~/.config` holds settings for many tools. Other categories list its other children.
    static let partlyClaimedFolders: [String: Set<String>] = [
        ".config": Set(roots.compactMap { $0.path.hasPrefix(".config/") ? String($0.path.dropFirst(8)) : nil })
    ]

    /// The root folder, or nil when the layout does not identify the tool.
    static func location(of root: Root, home: URL, applications: URL = defaultApplications) -> URL? {
        let url = (root.base == .home ? home : applications).appendingPathComponent(root.path)
        let identified = root.identifiedBy.allSatisfy { marker in
            ApplicationsScanner.expand(marker, under: url).contains { FileManager.default.fileExists(atPath: $0.path) }
        }
        return identified ? url : nil
    }

    /// The root paths that AI Tools claims. Other categories do not list these paths.
    static func claimedPaths(home: URL, applications: URL = defaultApplications) -> [String] {
        roots.compactMap { location(of: $0, home: home, applications: applications)?.path }
    }

}
