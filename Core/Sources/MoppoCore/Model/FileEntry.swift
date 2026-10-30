import Foundation

/// One removable thing: a file, a folder, or an app bundle with its leftovers.
public struct FileEntry: Sendable, Equatable, Identifiable {

    /// Identifies the tool icon without changing storage ownership or removal rules.
    public enum AITool: String, Sendable {
        case codex = "Codex", chatGPT = "ChatGPT", claude = "Claude", cursor = "Cursor", grokBot = "GrokBot"
        case t3Code = "T3Code"
        case ollama = "Ollama", huggingFace = "HuggingFace", lmStudio = "LMStudio"
        case gemini = "Gemini", antigravity = "Antigravity"
    }

    /// A removal workflow that needs more checks than ordinary file cleanup.
    public enum RemovalAction: Sendable, Equatable {
        case orphanedApplication(bundleIdentifier: String)
    }

    public enum Kind: String, Sendable {
        case file, folder, appBundle, cache, archive, diskImage
        /// An `.app` found in the user's folders — an installer in Downloads, a copy
        /// on the Desktop. Not `appBundle`: that kind means an *installed*
        /// application and routes to the uninstaller, which reasons about running
        /// state, leftovers and Homebrew. A bundle lying in Downloads has none of
        /// that; it is a large file the user downloaded, and it is removed like one.
        case downloadedApp

        /// SF Symbol name, per the design's icon table.
        public var symbolName: String {
            switch self {
            case .file:          "doc"
            case .folder:        "folder"
            case .appBundle:     "app"
            case .downloadedApp: "app.dashed"
            case .cache:         "folder"
            case .archive:       "doc.zipper"
            case .diskImage:     "externaldrive"
            }
        }

        /// File-row icon tint: gray documents, teal folders, purple for anything
        /// regenerable.
        public var color: ColorToken {
            switch self {
            case .file, .archive: .gray
            case .folder:         .teal
            case .cache:          .purple
            case .appBundle:      .accent
            case .downloadedApp:  .gray
            case .diskImage:      .gray
            }
        }
    }

    /// The file path, application group identifier, or Docker image URL.
    public var id: String {
        if dockerImage != nil { return url.absoluteString }
        if let runtime = toolCommand?.simulatorRuntime { return "simulator-runtime:\(runtime.runtime.identifier)" }
        return switch removalAction {
        case .orphanedApplication(let identifier):
            "orphaned-application:\(identifier)"
        case nil:
            url.path
        }
    }

    public var url: URL
    public var displayName: String
    /// Tilde-abbreviated parent, e.g. `~/Downloads`.
    public var parentDisplay: String
    public var kind: Kind
    public var allocatedBytes: Int64
    /// A known usage date. Docker images show "Unknown" when this value is absent.
    public var lastOpened: Date?
    /// Regenerates on demand; shown as `· regenerable` after the path.
    public var isRegenerable: Bool
    /// Why this entry is listed for information but refused for removal.
    ///
    /// Protection is shown, never silent: hiding these rows hid the useful fact
    /// that a daily app had grown gigabytes. The reason is carried so the UI can
    /// say the true thing.
    ///
    /// There was a third reason, `recentUse`, until 19 Sep 2026: a badge for
    /// anything used inside a window the user set in Preferences. It locked nothing
    /// and decided nothing, and its date could not carry even that much. An
    /// application's date is the newest of its bundle and its caches, and a cache is
    /// rewritten by an updater or a helper whether or not anybody opened the app;
    /// `kMDItemLastUsedDate` moves only for a Launch Services open. WhatsApp and
    /// Spotify both wore "recently used" beside a date column reading "last week".
    /// The date stays, as a column the user can weigh. The claim built on it went.
    public enum ProtectionReason: String, Sendable, Equatable {
        /// The app has a live process right now. Ground truth from NSWorkspace.
        case running
        /// Profiles, logins, history, documents. Locked by default; an interactive
        /// caller may authorize this exact row after a destructive warning.
        case userData
        /// Storage shown for information. Ordinary cleanup cannot override this lock.
        case inventory
        /// A size remainder with no separate removal target. The parent includes these files.
        case folderRemainder
    }

    /// Instructions for storage that requires removal outside Moppo.
    public struct ManualRemoval: Sendable, Equatable {
        public let explanation: String
        public let command: String

        public init(explanation: String, command: String) {
            self.explanation = explanation
            self.command = command
        }
    }

    public var manualRemoval: ManualRemoval?
    public var removalMethod: RemovalMethod

    public var toolCommand: ToolCommandRemoval? {
        if case .toolCommand(let command) = removalMethod { return command }
        return nil
    }
    /// Docker handles permanent removal of this image.
    public var dockerImage: DockerImage?

    /// The running application that has this row's files open.
    ///
    /// Not a lock and not a `ProtectionReason`: the checkbox works and removal is
    /// allowed. It withdraws one claim only — *safe*. "Regenerable" had been judged
    /// by what is on disk, and a running process also holds state in memory. On
    /// 19 Sep 2026 Chrome's `Shared Dictionary` went from under a live Chrome, which
    /// kept advertising dictionaries it no longer had; `www.reddit.com` failed with
    /// `ERR_DICTIONARY_LOAD_FAILED` until Chrome was relaunched. That folder is no
    /// longer offered at all, but the rule it broke is general: nothing here knows
    /// what another process keeps in RAM, so a cache under a live owner is never
    /// counted safe and never ticked for the user. Quit the owner and it is both.
    public struct RunningOwner: Sendable, Equatable, Hashable {
        public let name: String
        public let bundleIdentifier: String?
        public let bundlePath: String

        public init(name: String, bundleIdentifier: String?, bundlePath: String) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.bundlePath = bundlePath
        }
    }

    public var inUseBy: RunningOwner?
    public var xcodeBuildCacheReview: XcodeBuildCache.Review?

    /// Why a row that looks regenerable is not called so, in two or three words:
    /// `no lockfile` on a dependency store nothing can put back as it was.
    ///
    /// For the reader, not for arithmetic. The row already carries
    /// `isRegenerable == false`, which is what keeps it out of Safe to remove; this
    /// says why, so a grey `node_modules` beside a green one is not a riddle. See
    /// `BuildOutputDetector.reinstallEvidence(for:)`.
    public var safetyCaveat: String?

    /// Git status at scan time. A failed check does not mean the worktree is clean.
    public enum GitWorktreeStatus: Sendable, Equatable {
        case clean, uncommittedChanges, unavailable
    }

    /// Compares commits with local remote-tracking data, which can be out of date.
    public enum GitWorktreePushStatus: Sendable, Equatable {
        case noUnpushedCommits
        case unpushedCommits(Int)
        case unknown
    }

    public var gitWorktreeReview: GitWorktreeReview?
    public var isGitWorktree: Bool { gitWorktreeReview != nil }

    /// Counts worktrees in this row and its disclosed children.
    public var worktreeCount: Int {
        (isGitWorktree ? 1 : 0) + children.reduce(0) { $0 + ($1.isGitWorktree ? 1 : 0) }
    }

    /// The row and its children are one thing, removed together or not at all.
    ///
    /// Children are ordinarily targets in their own right: an application's cache
    /// can go while the application stays. A model's are not. Its row is a manifest
    /// or a folder of links, and its children are the weights and the records that
    /// say who uses them; removing the weights alone leaves a model its runtime
    /// still lists and cannot load, and removing a record alone leaves weights
    /// nothing claims. The table draws such children as part of the row, with no
    /// checkbox of their own — see `LocalModelStores`.
    public var removesAsUnit: Bool = false

    /// Model manifests or repository folders represented by this row.
    public var localModelPaths: [URL] = []

    /// Exclude model identities without excluding shared blobs.
    public var exclusionURLs: [URL] {
        if !localModelPaths.isEmpty { return localModelPaths }
        if removalAction != nil { return children.map(\.url) }
        return [url]
    }

    public var canExcludeFromCleanup: Bool {
        !isRemovalLocked || protectionReason == .userData
    }

    /// A specialized cleanup action for this row.
    public var removalAction: RemovalAction?
    /// The identities and owners checked before downloaded sound content moves.
    public var soundLibrary: AppleSoundLibrary.Inventory?
    public var aiTool: AITool?
    public var aiStorageSection: AIStorageSection?
    public var codexSession: CodexSessionReview?

    /// Child items that support separate removal after a user data review.
    public var unlockableChildren: [FileEntry] {
        guard kind != .appBundle, removalAction == nil, !removesAsUnit, manualRemoval == nil else { return [] }
        return children.filter {
            $0.protectionReason == .userData && $0.manualRemoval == nil
                && $0.dockerImage?.isRemovalLocked != true && $0.kind != .appBundle
        }
    }

    /// Child selection stays separate from permission to remove protected data.
    public func selectableChildren(userDataRemovalOverrides: Set<ID>) -> [FileEntry] {
        let locked = unlockableChildren
        guard !locked.isEmpty, locked.allSatisfy({ userDataRemovalOverrides.contains($0.id) }) else { return [] }
        let unlockedIDs = Set(locked.map(\.id))
        return children.filter {
            $0.kind != .appBundle && (!$0.isRemovalLocked || unlockedIDs.contains($0.id))
        }
    }

    /// Explains a permanent inventory lock in the row help and selection tooltip.
    public var protectionExplanation: String?
    public var protectionReason: ProtectionReason?
    /// Any reason at all: drives the badge, nothing else.
    public var isProtectedFromRemoval: Bool { protectionReason != nil }

    /// Whether removal is actually refused.
    ///
    /// User data requires separate authorization. Running apps and inventory rows stay locked.
    public var isRemovalLocked: Bool {
        protectionReason != nil
            || manualRemoval != nil || toolCommand?.lockReason != nil
            || dockerImage?.isRemovalLocked == true || !unlockableChildren.isEmpty
    }
    /// Item count for folders, shown as `· 1,204 items`.
    public var childCount: Int?
    /// Files disclosed under this row. A selected parent removes these first.
    /// Protected app data still requires explicit uninstall authorization.
    public var children: [FileEntry]

    public init(
        url: URL,
        displayName: String? = nil,
        parentDisplay: String? = nil,
        kind: Kind,
        allocatedBytes: Int64,
        lastOpened: Date? = nil,
        isRegenerable: Bool = false,
        protectionReason: ProtectionReason? = nil,
        protectionExplanation: String? = nil,
        manualRemoval: ManualRemoval? = nil,
        removalMethod: RemovalMethod = .trash,
        dockerImage: DockerImage? = nil,
        inUseBy: RunningOwner? = nil,
        xcodeBuildCacheReview: XcodeBuildCache.Review? = nil,
        safetyCaveat: String? = nil,
        gitWorktreeReview: GitWorktreeReview? = nil,
        removalAction: RemovalAction? = nil,
        soundLibrary: AppleSoundLibrary.Inventory? = nil,
        aiTool: AITool? = nil,
        aiStorageSection: AIStorageSection? = nil,
        codexSession: CodexSessionReview? = nil,
        childCount: Int? = nil,
        children: [FileEntry] = []
    ) {
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.parentDisplay = parentDisplay
            ?? FileEntry.abbreviate(url.deletingLastPathComponent().path)
        self.kind = kind
        self.allocatedBytes = allocatedBytes
        self.lastOpened = lastOpened
        self.isRegenerable = isRegenerable
        self.protectionReason = protectionReason
        self.protectionExplanation = protectionExplanation
        self.manualRemoval = manualRemoval
        self.removalMethod = removalMethod
        self.dockerImage = dockerImage
        self.inUseBy = inUseBy
        self.xcodeBuildCacheReview = xcodeBuildCacheReview
        self.safetyCaveat = safetyCaveat
        self.gitWorktreeReview = gitWorktreeReview
        self.removalAction = removalAction
        self.soundLibrary = soundLibrary
        self.aiTool = aiTool
        self.aiStorageSection = aiStorageSection
        self.codexSession = codexSession
        self.childCount = childCount
        self.children = children
    }

    /// Bytes freed by removing this entry and everything attached to it.
    public var totalBytesIncludingChildren: Int64 {
        allocatedBytes + children.reduce(0) { $0 + $1.allocatedBytes }
    }

    /// What removal can actually offer. A protected entry contributes only its
    /// removable children; counting its own bytes would promise space the app
    /// refuses to free.
    public var reclaimableBytes: Int64 {
        if removalAction != nil {
            return children.reduce(0) { $0 + $1.allocatedBytes }
        }
        let childBytes = children
            .filter { !$0.isRemovalLocked }
            .reduce(Int64(0)) { $0 + $1.allocatedBytes }
        let remainderBytes = children.filter { $0.protectionReason == .folderRemainder }
            .reduce(Int64(0)) { $0 + $1.allocatedBytes }
        return isRemovalLocked ? childBytes : allocatedBytes + childBytes + remainderBytes
    }

    /// Storage shown in the row and category totals, including protected tool storage.
    /// Removal estimates use `reclaimableBytes` separately.
    public var displayBytes: Int64 {
        if dockerImage != nil || toolCommand != nil { return allocatedBytes }
        if removalAction != nil { return reclaimableBytes }
        return manualRemoval != nil || protectionReason == .inventory || protectionReason == .folderRemainder
            || codexSession != nil || !unlockableChildren.isEmpty
            ? totalBytesIncludingChildren : reclaimableBytes
    }

    /// Bytes among this row's children that regenerate and can actually be removed.
    ///
    /// Counted as safe wherever the row itself is not. An application's caches come
    /// back the next time it launches even though the application does not, and the
    /// Scanner has always said so by badging those children `regenerable`; without
    /// this the Dashboard's "Safe to remove" could not see them, because they are
    /// children rather than rows and their parent is never safe.
    public var regenerableChildBytes: Int64 {
        children
            .filter(\.regeneratesSafely)
            .reduce(0) { $0 + $1.allocatedBytes }
    }

    /// Whether this item may be *called* safe on the strength of regenerating.
    ///
    /// It regenerates, nothing refuses its removal, and no running application has
    /// it open. A badge never overrides a lock, and a cache whose owner is running
    /// is not safe *yet* — see `inUseBy`.
    ///
    /// One definition, because it had three. The tile arithmetic and the Safe to
    /// Remove list each spelled it out, and the Scanner's child row spelled out a
    /// shorter one: it painted `regenerable` green on `isRegenerable` alone. So on
    /// 19 Sep 2026 every cache under a running Chrome wore the colour that means
    /// safe while the tile, correctly, refused to count one of them. The figure and
    /// the badge now ask the same question.
    public var regeneratesSafely: Bool {
        (gitWorktreeReview?.isSafeToRemove ?? isRegenerable) && !isRemovalLocked && inUseBy == nil
    }

    /// The size shown beside a top-level Scanner row. Applications show only their
    /// installed bundle. Other parents include their disclosed removal targets.
    public var rowDisplayBytes: Int64 {
        kind == .appBundle ? allocatedBytes : displayBytes
    }

    public var orphanedApplicationBundleIdentifier: String? {
        guard case .orphanedApplication(let identifier) = removalAction else { return nil }
        return identifier
    }

    /// `/Users/me/Downloads` → `~/Downloads`
    public static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// The design's trailing qualifier: `· 1,204 items` or `· regenerable`.
    public var parentQualifier: String {
        if isRegenerable { return "\(parentDisplay) · regenerable" }
        if let childCount, childCount > 0 {
            let formatted = NumberFormatter.localizedString(
                from: NSNumber(value: childCount), number: .decimal
            )
            return "\(parentDisplay) · \(formatted) items"
        }
        return parentDisplay
    }
}
