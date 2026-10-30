import Foundation

/// Xcode and iOS development leftovers: build products, downloaded device symbols,
/// simulator state and preview caches.
///
/// Ports `electron/cleaners/xcodeArtifacts.ts`, whose sizing was the reason this
/// rewrite exists. It measured every folder with
/// `execSync('du -sk "…" 2>/dev/null')` wrapped in a `catch { return 0 }`, and `du`
/// exits non-zero the moment it meets one unreadable directory. A single 0700
/// subdirectory — `DerivedData/CompilationCache.noindex` is one, on this machine —
/// was enough to report a multi-gigabyte tree as `0`, and the caller then dropped it
/// with `if (size > 0)`. The category disappeared instead of reporting a permission
/// problem. Every byte here comes from `context.measurer`, which counts the
/// unreadable entry and keeps walking, and that count is surfaced in the result.
///
/// Only scanning is ported. The original's `cleanXcodeArtifacts` shelled out to
/// `rm -rf`; removal is the remover's job in this app, not a scanner's.
public struct XcodeScanner: CategoryScanner {

    public let id: CategoryID = .xcode

    /// The `~/Library/Developer` tree to scan. Injectable so a test can lay out a
    /// real Archives/DerivedData fixture instead of reading the machine's own.
    private let developerRoot: URL

    /// Where projects live. Build output found inside a project here — up to two
    /// levels down, recognised by shape via `BuildOutputDetector` — is offered as
    /// its own regenerable row. Xcode puts derived data wherever a project says,
    /// and a project-local `build` folder is invisible to the roots above.
    private let projectRoots: [URL]
    private let temporaryRoots: [URL]
    var captureBuildActivity: @Sendable ([URL]) async throws -> WorktreeActivity = {
        try await WorktreeActivity.capture(roots: $0)
    }

    /// The system runtime inventory root. Tests use a separate directory.
    private let systemSimulatorRoot: URL
    private let simulatorAssetRoots: [URL]
    var simulatorRuntimes = SimulatorRuntimeService()

    public static let defaultProjectRoots: [URL] = {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return ["Documents", "Desktop", "Downloads", "Developer", "Projects"].map {
            home.appending(path: $0, directoryHint: .isDirectory)
        }
    }()

    public init(
        developerRoot: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: "Library/Developer", directoryHint: .isDirectory),
        projectRoots: [URL] = XcodeScanner.defaultProjectRoots,
        systemSimulatorRoot: URL = URL(fileURLWithPath: "/Library/Developer/CoreSimulator"),
        temporaryRoots: [URL] = [URL(fileURLWithPath: "/private/tmp", isDirectory: true), FileManager.default.temporaryDirectory],
        simulatorAssetRoots: [URL]? = nil
    ) {
        self.developerRoot = developerRoot
        self.projectRoots = projectRoots
        self.temporaryRoots = temporaryRoots
        self.systemSimulatorRoot = systemSimulatorRoot
        self.simulatorAssetRoots = simulatorAssetRoots ?? (systemSimulatorRoot.standardizedFileURL.path == "/Library/Developer/CoreSimulator"
            ? SimulatorRuntimeService.assetRoots() : [])
    }

    // MARK: - Roots

    private struct Root {
        let url: URL
        /// `true` emits one row per immediate subdirectory rather than one row for
        /// the whole tree. Per-child rows are what make the category actionable: a
        /// single 12 GB `DerivedData` row cannot be refined, one row per project can.
        let expandsChildren: Bool
        /// Whether this root's contents come back on the next build. Carried on the
        /// root, not inferred from emitted paths: Archives emits one row per *date
        /// directory*, so a per-path `.xcarchive` test never fired and irreplaceable
        /// archives sailed through as "safe". The root knows what it holds.
        var regenerable: Bool = true
    }

    /// The original hardcoded `iOS DeviceSupport`, so symbol copies from a Watch or
    /// an Apple TV — identical directories under a different platform name — were
    /// invisible and accumulated forever.
    private static let deviceSupportPlatforms = ["iOS", "watchOS", "tvOS", "visionOS"]

    private static func roots(developer: URL) -> [Root] {

        func root(_ relative: String, expandsChildren: Bool, regenerable: Bool = true) -> Root {
            Root(
                url: developer.appending(path: relative, directoryHint: .isDirectory),
                expandsChildren: expandsChildren,
                regenerable: regenerable
            )
        }

        var roots: [Root] = [
            // One subdirectory per project, rebuilt by the next build.
            root("Xcode/DerivedData", expandsChildren: true),

            // `<date>/<name>.xcarchive`. Expanded per build date so a user can drop
            // last year's archives and keep this week's. Not regenerable: an
            // archive holds the only dSYMs for a build that has shipped, and once
            // it is gone crash reports from that build can never be symbolicated.
            // Stale archives stay listed — they really are the biggest win here —
            // but under "Needs review", never as "removal loses nothing".
            root("Xcode/Archives", expandsChildren: true, regenerable: false),

            // SwiftUI preview build products, regenerated the next time a preview
            // renders. One blob, not per-project subdirectories.
            root("Xcode/UserData/Previews", expandsChildren: false),

            // Per-device containers: installed apps, their data, logs. Ordinary
            // user-owned directories, unlike the runtimes — see the note below.
            root("CoreSimulator/Devices", expandsChildren: true),

            // Simulator dyld shared-cache staging. The one root the original did not
            // expand, and correctly so: its children are opaque cache buckets.
            root("CoreSimulator/Caches", expandsChildren: false)
        ]

        // Symbols copied off every physical device ever attached, one directory per
        // OS build. Nothing in Xcode ever prunes them.
        for platform in deviceSupportPlatforms {
            roots.append(root("Xcode/\(platform) DeviceSupport", expandsChildren: true))
        }

        return roots
    }

    // MARK: - Deliberately not scanned
    //
    // Simulator runtimes use simctl for removal. Their mounted files never enter file cleanup.
    // User-owned simulator device directories retain their separate cleanup rows.
    //
    // ### `/Library/Developer/PrivateFrameworks` and `/Library/Developer/CoreDevice`
    //
    // Installed by Xcode's first-launch package, not by dragging Xcode.app into
    // /Applications — and correspondingly *not* removed when Xcode.app is dragged to
    // the Trash. They read as abandoned developer junk left in /Library long after
    // Xcode is gone, which is the trap: a stale copy from an older Xcode makes a
    // freshly installed Xcode die on launch with a dyld symbol-not-found error
    // against CoreDeviceFramework, and recovery means deleting them by hand and
    // re-running the first-launch install. They are versioned system components with
    // an installer that owns them, so this scanner never offers them.
    //
    // ### Owned by other categories
    //
    // `~/Library/Caches/com.apple.dt.Xcode` belongs to System Caches, which scans all
    // of `~/Library/Caches`. Claiming it here too would double-count it, the same
    // defect the storage breakdown had with Homebrew.

    // MARK: - Scan

    public func scan(context: ScanContext) async throws -> ScanCategoryResult {
        let fileManager = FileManager.default
        var entries: [FileEntry] = []
        var unreadableCount = 0
        var additionalCaches: [XcodeBuildCache.Review] = []

        for root in Self.roots(developer: developerRoot) {
            try Task.checkCancellation()
            guard fileManager.fileExists(atPath: root.url.path) else { continue }
            // Excluding a root excludes everything beneath it, so test it before
            // paying for the walk rather than filtering the children afterwards.
            guard !context.isWithinExclusion(root.url) else { continue }

            if root.expandsChildren {
                // One `measureChildren` call rather than a `measure` per child: it
                // shares a hard-link deduplicator across the children, so an inode
                // hard-linked into two projects' DerivedData is charged once and the
                // rows sum to the root instead of exceeding it.
                let measured = try await context.measurer.measureChildren(of: root.url)

                for (childURL, measurement) in measured {
                    // Counted for every child measured, including ones filtered out
                    // below: the number describes how much of the tree could be read,
                    // not how much is on offer.
                    unreadableCount += measurement.unreadableCount

                    // Directories only, as the original's `listSubdirs` did. A stray
                    // `.DS_Store` is a 6 KB row of pure noise in a removal list.
                    guard isDirectory(childURL) else { continue }

                    if let entry = makeCacheEntry(
                        url: childURL, measurement: measurement, context: context,
                        isRegenerable: root.regenerable
                    ) {
                        entries.append(entry)
                    }
                }
            } else {
                let measurement = try await context.measurer.measure(root.url)
                unreadableCount += measurement.unreadableCount

                if let entry = makeCacheEntry(
                    url: root.url, measurement: measurement, context: context,
                    isRegenerable: root.regenerable
                ) {
                    entries.append(entry)
                }
            }
        }

        // Build output inside the user's own projects. Listed here, not under
        // Documents & Files, because this is the category that can say "safe":
        // every root the detector accepts is rebuilt by the next build. The
        // Documents scanner carves the same bytes out of its project rows, so the
        // space is offered once.
        for projectRoot in projectRoots {
            guard fileManager.fileExists(atPath: projectRoot.path),
                  !context.isWithinExclusion(projectRoot)
            else { continue }
            for project in Self.visibleDirectories(in: projectRoot) {
                try Task.checkCancellation()
                guard !context.isWithinExclusion(project) else { continue }
                for output in BuildOutputDetector.roots(under: project)
                where output.kind.isXcodeOutput {
                    guard !context.isExcluded(output.url) else { continue }
                    if let review = output.xcodeBuildCacheReview {
                        additionalCaches.append(review)
                        continue
                    }
                    let measurement = try await context.measurer.measure(output.url)
                    unreadableCount += measurement.unreadableCount
                    guard measurement.allocatedBytes > 0,
                          !measurement.containsProtectedPattern
                    else { continue }
                    entries.append(FileEntry(
                        url: output.url,
                        displayName: "\(project.lastPathComponent) build output",
                        parentDisplay: FileEntry.abbreviate(
                            output.url.deletingLastPathComponent().path
                        ) + " · " + output.kind.label,
                        kind: .cache,
                        allocatedBytes: measurement.allocatedBytes,
                        lastOpened: lastOpenedDate(for: output.url),
                        isRegenerable: true,
                        inUseBy: Self.runningOwner(of: output.url, context: context),
                        childCount: (try? fileManager.contentsOfDirectory(
                            atPath: output.url.path
                        ))?.count
                    ))
                }
            }
        }

        additionalCaches += try XcodeBuildCache.temporaryCaches(under: temporaryRoots, context: context)
        let existing = entries.map { $0.url.resolvingSymlinksInPath().path }
        var seen: Set<String> = []
        additionalCaches = additionalCaches.filter { review in
            let path = review.url.resolvingSymlinksInPath().path
            return !existing.contains { path == $0 || path.hasPrefix($0 + "/") }
                && seen.insert(path).inserted && !context.isWithinExclusion(review.url)
                && !context.isWithinExclusion(review.url.resolvingSymlinksInPath())
        }
        if !additionalCaches.isEmpty {
            let folders = try additionalCaches.sorted(by: { $0.root.path < $1.root.path }).map {
                ($0, try XcodeBuildCache.inspect($0, context: context))
            }
            let activity = try await captureBuildActivity(folders.flatMap { [$0.0.root] + $0.1.children })
            for (folder, inspection) in folders {
                try Task.checkCancellation()
                let root = folder.root
                var measurer = context.measurer
                measurer.detectCloudOnlyItems = true
                let measurements = try await measurer.measure(root, retaining: inspection.children) {
                    activity.observe($0, values: $1, attribution: $2)
                }
                let total = measurements[root] ?? .zero
                unreadableCount += total.unreadableCount
                let owner = Self.runningOwner(of: root, context: context)
                func protection(for url: URL, measured: SizeMeasurement, isRegenerable: Bool)
                    -> (FileEntry.ProtectionReason?, String?) {
                    if let issue = inspection.issue(for: url) { return (.inventory, issue) }
                    if measured.unreadableCount > 0 || measured.containsProtectedPattern || measured.containsCloudOnlyItem {
                        return (.inventory, "Some files are unreadable, protected, or stored only in the cloud.")
                    }
                    switch activity.check(url, measurement: measured) {
                    case .found(let names):
                        return (.running, "Files are open in: \(names). Stop the build or close the tool, then scan again.")
                    case .unknown:
                        return (.inventory, "Open files could not be checked. Scan again before removal.")
                    case .clear:
                        if !isRegenerable, let owner {
                            return (.running, "\(owner.name) is open. Close \(owner.name), then scan again before removing this item.")
                        }
                        return (nil, nil)
                    }
                }
                var children: [FileEntry] = []
                for url in inspection.children {
                    guard !XcodeBuildCache.excluded(url, context: context) else { continue }
                    let measured = measurements[url] ?? .zero
                    let review = inspection.review(for: url, in: folder, context: context)
                    let regenerable = review?.isRegenerable == true
                    let (reason, explanation) = protection(for: url, measured: measured, isRegenerable: regenerable)
                    let kind: FileEntry.Kind = regenerable ? .cache
                        : ((try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ? .folder : .file)
                    children.append(FileEntry(url: url, kind: kind, allocatedBytes: measured.allocatedBytes,
                        lastOpened: lastOpenedDate(for: url), isRegenerable: regenerable,
                        protectionReason: reason, protectionExplanation: explanation,
                        inUseBy: owner, xcodeBuildCacheReview: review))
                }
                let review = inspection.review(for: root, in: folder, context: context)
                let (reason, explanation) = protection(for: root, measured: total, isRegenerable: false)
                let temporary = temporaryRoots.contains {
                    root.path.hasPrefix($0.resolvingSymlinksInPath().path + "/")
                }
                entries.append(FileEntry(url: root,
                    displayName: folder.projectName + (temporary ? " — temporary build cache" : " — release build cache"),
                    parentDisplay: FileEntry.abbreviate(root.path), kind: .cache,
                    allocatedBytes: max(0, total.allocatedBytes - children.reduce(0) { $0 + $1.allocatedBytes }),
                    protectionReason: reason, protectionExplanation: explanation,
                    inUseBy: owner, xcodeBuildCacheReview: review ?? folder, children: children))
                ScanDiagnostics.current?.record("xcode_build_cache", details: [
                    "path": root.path, "allocated_bytes": "\(total.allocatedBytes)",
                    "protection": "\(String(describing: reason))"
                ])
            }
        }

        let runtimes = try await simulatorRuntimeEntries(context: context)
        entries += runtimes.entries
        unreadableCount += runtimes.unreadableCount

        guard !entries.isEmpty else {
            // Ordinary outcome, not an edge case: a machine with Xcode installed but
            // nothing built measures 0 B and the row renders disabled with no
            // disclosure triangle. Not `.unavailable` — that reason string is
            // user-facing repair copy, and a cleaner has no business telling someone
            // to install Xcode.
            var empty = ScanCategoryResult.empty(id)
            // An empty category that could not read anything is not the same as one
            // that is genuinely empty, and the Dashboard's `Unmeasured` bucket needs
            // the difference even when there is nothing to list.
            empty.unreadableCount = unreadableCount
            return empty
        }

        // `measureChildren` returns a dictionary, so iteration order varies between
        // runs; the path tiebreak keeps equal-sized rows in a stable order.
        entries.sort {
            $0.totalBytesIncludingChildren == $1.totalBytesIncludingChildren
                ? $0.url.path < $1.url.path
                : $0.totalBytesIncludingChildren > $1.totalBytesIncludingChildren
        }

        return ScanCategoryResult(
            categoryID: id,
            totalBytes: entries.reduce(0) { $0 + $1.totalBytesIncludingChildren },
            entries: entries,
            availability: .available,
            unreadableCount: unreadableCount
        )
    }

    /// Non-hidden subdirectories, symlinks excluded: a link into another tree must
    /// not be offered as though removing it freed that tree.
    private static func visibleDirectories(in url: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter {
            let values = try? $0.resourceValues(forKeys: keys)
            return values?.isDirectory == true && values?.isSymbolicLink != true
        }.sorted { $0.path < $1.path }
    }

    // MARK: - Entries

    /// Builds the row for an already-measured path, or `nil` when it is excluded or
    /// measured empty.
    ///
    /// Deliberately not the protocol's `makeEntry(url:kind:context:isRegenerable:)`:
    /// that helper runs its own `measure`, which would walk each tree a second time,
    /// and it discards `SizeMeasurement.unreadableCount` — the one number this
    /// scanner exists to stop losing.
    private func makeCacheEntry(
        url: URL,
        measurement: SizeMeasurement,
        context: ScanContext,
        isRegenerable: Bool = true
    ) -> FileEntry? {
        guard measurement.allocatedBytes > 0 else { return nil }

        let lastOpened = lastOpenedDate(for: url)
        // Folder and pattern exclusions apply, and no date does. Build products
        // are rewritten on every build, so "touched recently" describes every
        // DerivedData worth showing; a recency filter once hid them, and hid
        // Chrome's caches from the System Caches category the same way.
        guard !context.isExcluded(url) else { return nil }
        // See `SizeMeasurement.containsProtectedPattern`.
        guard !measurement.containsProtectedPattern else { return nil }

        return FileEntry(
            url: url,
            kind: .cache,
            allocatedBytes: measurement.allocatedBytes,
            lastOpened: lastOpened,
            // From the root that emitted this row — see `Root.regenerable`.
            isRegenerable: isRegenerable,
            inUseBy: Self.runningOwner(of: url, context: context),
            childCount: (try? FileManager.default.contentsOfDirectory(atPath: url.path))?.count
        )
    }

    /// The running tool that has this tree open — see `FileEntry.inUseBy`.
    ///
    /// Removing DerivedData under an idle Xcode is routine; under a build it fails
    /// the build, and a module cache taken from a live Xcode can leave "module not
    /// found" errors that only a relaunch clears. Nothing here can tell idle from
    /// building, so an open Xcode withdraws "safe" from everything it writes.
    /// Simulator data answers to a booted Simulator first, and to Xcode, which
    /// boots simulators of its own for previews and tests.
    static func runningOwner(of url: URL, context: ScanContext) -> FileEntry.RunningOwner? {
        let xcode = context.runningOwner(bundleIdentifier: "com.apple.dt.Xcode")
        guard url.path.contains("/CoreSimulator") else { return xcode }
        return context.runningOwner(bundleIdentifier: "com.apple.iphonesimulator") ?? xcode
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    // MARK: - Simulator runtimes

    private func simulatorRuntimeEntries(context: ScanContext) async throws -> (entries: [FileEntry], unreadableCount: Int) {
        let root = systemSimulatorRoot
        let scanInstalled = FileManager.default.fileExists(atPath: root.path) && !context.isWithinExclusion(root)
        guard scanInstalled || !simulatorAssetRoots.isEmpty else { return ([], 0) }
        context.onPhase?("Checking simulator runtimes")
        var snapshot: SimulatorRuntimeService.Snapshot?
        var entries: [FileEntry] = []
        var measured: Set<String> = []
        var unreadableCount = 0
        if scanInstalled {
            do { snapshot = try await simulatorRuntimes.snapshot() }
            catch is CancellationError { throw CancellationError() }
            catch {
                entries.append(FileEntry(url: root, displayName: "Simulator runtime inventory unavailable", kind: .diskImage,
                    allocatedBytes: 0, protectionReason: .inventory,
                    protectionExplanation: "Runtime details could not be read. Open Xcode Components, then scan again."))
                unreadableCount += 1
            }
        }
        for runtime in snapshot?.runtimes ?? [] {
            try Task.checkCancellation()
            guard !runtime.relatedURLs.contains(where: { context.isExcluded($0) || context.isExcluded($0.resolvingSymlinksInPath()) })
            else { continue }
            guard let review = snapshot?.review(runtime) else { continue }
            let command = ToolCommandRemoval.simulatorRuntime(review,
                fallbackURL: root.appendingPathComponent(runtime.identifier), protectedPatterns: context.excludedPatterns)
            var size = SizeMeasurement.zero
            var caveat = "Size includes the backing image only. Mounted contents and shared caches are excluded."
            if let backing = runtime.backingURL, let key = runtime.storageKey, measured.insert(key).inserted {
                size = try await context.measurer.measure(backing)
                unreadableCount += size.unreadableCount
                if size.unreadableCount > 0 { caveat = "The backing image size could not be measured completely." }
            } else if runtime.backingURL != nil {
                caveat = "Another runtime row includes this shared backing image."
            } else {
                unreadableCount += 1
                caveat = "The runtime size could not be measured."
            }
            guard !size.containsProtectedPattern, !size.containsCloudOnlyItem else { continue }
            let lockReason = command.lockReason ?? (size.unreadableCount > 0 ? caveat : nil)
            entries.append(FileEntry(url: command.targetURL, displayName: runtime.name,
                parentDisplay: "Simulator runtime · " + runtime.identifier, kind: .diskImage,
                allocatedBytes: size.allocatedBytes, protectionReason: lockReason == nil ? nil : .inventory,
                protectionExplanation: lockReason,
                removalMethod: .toolCommand(command), safetyCaveat: caveat))
        }
        let downloads = try await SimulatorRuntimeService.downloadEntries(in: simulatorAssetRoots,
            registeredRuntimes: snapshot?.runtimes, context: context,
            removalGuidance: snapshot.flatMap { SimulatorRuntimeService.retainedImageGuidance(developerDirectory: $0.developerDirectory) })
        entries += downloads.entries
        unreadableCount += downloads.unreadableCount
        return (entries, unreadableCount)
    }
}
