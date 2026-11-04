import Foundation

/// Lists package caches and obsolete Homebrew formula versions.
///
/// Cache rows can regenerate and enter Safe to Remove.
/// Old formula versions require review and Homebrew removal.
/// Cache roots use a fixed list to protect project files.
///
/// Ports `electron/cleaners/packageManagers.ts`, dropping two of its behaviours:
///
/// * **`du -sk` sizing.** `du` exits non-zero on the first unreadable directory and
///   the old `catch` turned that into `0`, so one permission-denied folder reported
///   an entire multi-gigabyte cache as empty. All sizing goes through
///   `context.measurer`, whose enumerator counts an unreadable entry and keeps
///   walking; the count is surfaced in `unreadableCount` instead of being swallowed.
/// * **`which npm` gating.** The old scanner hid a cache whenever the tool was not
///   on `PATH`. That is backwards twice over: a GUI app inherits a login `PATH`
///   without the user's shell rc, so an nvm-managed `npm` is routinely invisible and
///   its cache was never offered; and the cache of a tool the user has *uninstalled*
///   is the single best thing to reclaim. The directory existing, with bytes in it,
///   is the whole condition now.
///
/// ### Reported size is an upper bound
///
/// A pnpm store is content-addressable: its files are hard-linked (or APFS-cloned)
/// into every project `node_modules` that needs them. Deleting store entries
/// therefore frees **less** than their apparent sum, because the blocks stay alive
/// behind the other references. `AllocatedSizeMeasurer` deduplicates hard links
/// within a single measurement, but no per-file API can see clone sharing between
/// distinct files, so the number reported here remains an upper bound on what
/// removal actually reclaims.
///
/// Do not "fix" this by scaling the total down. Any correction factor would be a
/// guess, and turning an honest upper bound into a fabricated precise figure would
/// make the app promise space it cannot deliver.
public struct PackageManagerScanner: CategoryScanner {

    public let id: CategoryID = .packageManagers

    /// The home whose cache roots are scanned. Injectable so the rules above can be
    /// exercised against a fixture tree; production reads the real home.
    private let home: URL
    private let goExecutable: @Sendable () -> String?
    private let homebrewVersions: HomebrewFormulaVersions

    public init(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                goExecutable: @escaping @Sendable () -> String? = ToolCommandRemoval.resolveGo,
                homebrewVersions: HomebrewFormulaVersions? = nil) {
        self.home = home
        self.goExecutable = goExecutable
        // A custom home does not inspect this Mac's system package installations without an explicit service.
        self.homebrewVersions = homebrewVersions ?? (home.standardizedFileURL.path == NSHomeDirectory()
            ? HomebrewFormulaVersions() : HomebrewFormulaVersions(executables: { [] }, run: { _, _ in Data() }))
    }

    // MARK: - Cache roots

    /// The `roots` table is in `Generated/ToolRules.swift`. Change a rule in `rules/<tool>.json`.

    /// One audited cache location, addressed relative to `$HOME`.
    struct CacheRoot: Sendable {
        /// Shown as the row's name. The row also prints the real parent path
        /// underneath, so several roots may share a tool name without ambiguity.
        let label: String
        let components: [String]
        /// A download that the tool does not restore by itself. The row needs review and shows this text.
        var reviewCaveat: String? = nil

        func url(relativeTo home: URL) -> URL {
            components.reduce(home) { $0.appendingPathComponent($1) }
        }
    }


    // MARK: - Scan

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        var entries: [FileEntry] = []
        var totalBytes: Int64 = 0
        var unreadableCount = 0

        let homebrew = try await homebrewVersions.entries(context: context)
        entries += homebrew.entries
        totalBytes += homebrew.entries.reduce(0) { $0 + $1.allocatedBytes }
        unreadableCount += homebrew.unreadableCount

        let moduleCache = home.appendingPathComponent(Self.goModuleCache, isDirectory: true)
        if FileManager.default.fileExists(atPath: moduleCache.path), !context.isExcluded(moduleCache) {
            let review = ToolCommandRemoval.goModuleCache(at: moduleCache, executable: goExecutable(),
                protectedPatterns: context.measurer.protectedPatterns)
            let measured = try await context.measurer.measure(moduleCache)
            unreadableCount += measured.unreadableCount
            if measured.allocatedBytes > 0, !measured.containsProtectedPattern {
                entries.append(FileEntry(url: moduleCache, displayName: "Go module cache", kind: .cache,
                    allocatedBytes: measured.allocatedBytes, isRegenerable: true,
                    protectionReason: measured.unreadableCount > 0 ? .inventory : nil,
                    protectionExplanation: measured.unreadableCount > 0
                        ? "Some cache files could not be checked. Scan again before removal." : review.lockReason,
                    removalMethod: .toolCommand(review),
                    safetyCaveat: "Go removes this cache permanently. Projects may need another download."))
                totalBytes += measured.allocatedBytes
            }
        }

        for root in Self.roots {
            try Task.checkCancellation()

            let url = root.url(relativeTo: home)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }

            let lastOpened = lastOpenedDate(for: url)
            // Folder and pattern exclusions apply, and no date does. A cache is
            // written every time its app runs, so "touched in the last 30 days"
            // describes every cache worth showing — a recency filter hid exactly
            // the largest ones (Chrome's, an active IDE's) and left only the stale
            // caches of abandoned apps. The cost of removal here is regeneration,
            // not loss, which is what the category's `safe` badge tells the user.
            guard !context.isExcluded(url) else { continue }

            let measured: SizeMeasurement
            do {
                measured = try await context.measurer.measure(url)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A root that cannot be measured is reported as unreadable, never
                // reported as zero. Silently zeroing on failure is the predecessor's
                // bug this port exists to kill.
                unreadableCount += 1
                continue
            }

            unreadableCount += measured.unreadableCount
            // See `SizeMeasurement.containsProtectedPattern`.
            guard !measured.containsProtectedPattern else { continue }

            // The original's only threshold: an empty cache is not a cleanup
            // candidate, it is noise in a list the user has to read.
            guard measured.allocatedBytes > 0 else { continue }

            entries.append(FileEntry(
                url: url,
                displayName: root.label,
                kind: .cache,
                allocatedBytes: measured.allocatedBytes,
                lastOpened: lastOpened,
                isRegenerable: root.reviewCaveat == nil,
                safetyCaveat: root.reviewCaveat,
                childCount: (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
            ))
            totalBytes += measured.allocatedBytes
        }

        // Old extension versions an editor has itself marked for removal — see
        // `EditorExtensionStores`. Here and not in a category of their own because
        // that is what they are: packages from a registry, superseded, that the tool
        // which fetched them will delete. Safe on the editor's word, with one
        // condition the editor's word does not cover: an update waiting for a reload
        // leaves the old version running in the open window, so a row under an open
        // editor is held like any cache under its owner.
        for extensionFolder in EditorExtensionStores.obsolete(home: home) {
            try Task.checkCancellation()
            let url = extensionFolder.url
            guard !context.isExcluded(url) else { continue }
            let measured = try await context.measurer.measure(url)
            unreadableCount += measured.unreadableCount
            guard !measured.containsProtectedPattern, measured.allocatedBytes > 0 else { continue }

            let editor = extensionFolder.editor
            entries.append(FileEntry(
                url: url,
                displayName: EditorExtensionStores.displayName(forFolder: url.lastPathComponent),
                parentDisplay: "\(editor.name) marked this version for removal · "
                    + FileEntry.abbreviate(url.deletingLastPathComponent().path),
                kind: .cache,
                allocatedBytes: measured.allocatedBytes,
                lastOpened: lastOpenedDate(for: url),
                isRegenerable: true,
                inUseBy: context.runningOwner(bundleIdentifier: editor.bundleIdentifier)
            ))
            totalBytes += measured.allocatedBytes
        }

        entries.sort { $0.allocatedBytes > $1.allocatedBytes }

        // `.empty`, never `.unavailable`: a machine with no package-manager caches is
        // a successful measurement of nothing, not a scanner that failed. There is no
        // daemon to be missing here and so no fix to tell the user about.
        return ScanCategoryResult(
            categoryID: id,
            totalBytes: totalBytes,
            entries: entries,
            availability: entries.isEmpty ? .empty : .available,
            unreadableCount: unreadableCount
        )
    }
}
