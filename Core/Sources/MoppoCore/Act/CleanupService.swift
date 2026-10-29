import Foundation

/// The user cancelled permanent application removal.
public enum ApplicationRemovalError: Error, Sendable, Equatable {
    case cancelled
}

/// What a cleanup actually did.
public struct CleanupOutcome: Sendable, Equatable {

    /// What the removed items *occupied*: allocated size, summed as each item was
    /// measured immediately before it went.
    ///
    /// An upper bound on reclaimed space, and deliberately so — APFS clones share
    /// blocks between distinct files, so two 16 MB clones occupy 32 MB while the
    /// disk holds 16. Use it to say what was removed, never what was freed.
    /// ``freedBytes`` answers that.
    public var removedBytes: Int64

    /// What the removal releases: private size — bytes belonging to that file alone
    /// — read for each item in the instant before it goes.
    ///
    /// **Exact for a permanent deletion.** Removals run in sequence, so the second
    /// of a cloned pair is measured after the first has already been deleted, by
    /// which time it holds those blocks alone and reports all of them. The sum
    /// telescopes: delete one of a cloned pair and this is 0, delete both and it is
    /// the full size, and both answers are right.
    ///
    /// **A floor for a move to the Trash**, because a trashed file still exists and
    /// still holds its blocks. Trash two clones and each reads zero as it goes; the
    /// 4 MB they share comes back when the Trash is emptied, credited to neither
    /// removal. Understating is the direction to be wrong in — the alternative is
    /// promising space the disk has not given back.
    ///
    /// Falls short by ``unreportedFreedCount`` items besides, whose filesystem
    /// would not answer at all.
    public var freedBytes: Int64

    /// Removed items whose private size the filesystem declined to report, so their
    /// bytes are in ``removedBytes`` and absent from ``freedBytes``. Non-zero means
    /// the freed figure understates by an unknown amount.
    public var unreportedFreedCount: Int

    public var removedCount: Int
    /// The split behind `removedCount`, because the two halves make different
    /// promises: a trashed item can come back, a deleted one cannot, and the
    /// completion message must not say "undo" over bytes that are already gone.
    public var trashedCount: Int
    public var deletedCount: Int
    /// Paths that could not be removed. Reported rather than swallowed so the sheet
    /// can say "freed 3.2 GB, 2 items could not be removed" instead of claiming a
    /// clean run.
    public var failed: [String]
    /// Paths that failed because macOS denied access.
    public var permissionDenied: [String]
    /// Worktree paths kept because macOS blocked access to the Trash.
    public var trashAccessDenied: [String]
    public var administratorApprovalCancelled = false
    public var applicationRemovalCancelled: Bool
    /// Worktree paths excluded because their removal checks changed.
    public var skippedWorktrees: [String]
    public var toolCommandResults: [ToolCommandRemovalResult]

    public init(
        removedBytes: Int64 = 0,
        freedBytes: Int64 = 0,
        unreportedFreedCount: Int = 0,
        removedCount: Int = 0,
        failed: [String] = [],
        permissionDenied: [String] = [],
        trashAccessDenied: [String] = [],
        applicationRemovalCancelled: Bool = false,
        trashedCount: Int = 0,
        deletedCount: Int = 0,
        skippedWorktrees: [String] = [],
        toolCommandResults: [ToolCommandRemovalResult] = []
    ) {
        self.removedBytes = removedBytes
        self.freedBytes = freedBytes
        self.unreportedFreedCount = unreportedFreedCount
        self.removedCount = removedCount
        self.failed = failed
        self.permissionDenied = permissionDenied
        self.trashAccessDenied = trashAccessDenied
        self.applicationRemovalCancelled = applicationRemovalCancelled
        self.trashedCount = trashedCount
        self.deletedCount = deletedCount
        self.skippedWorktrees = skippedWorktrees
        self.toolCommandResults = toolCommandResults
    }

    /// Bytes the removed items claimed but did not give back, because another file
    /// still holds them. Zero for everything that was not sharing storage.
    public var sharedBytes: Int64 { max(0, removedBytes - freedBytes) }

    public mutating func merge(_ other: CleanupOutcome) {
        removedBytes += other.removedBytes
        freedBytes += other.freedBytes
        unreportedFreedCount += other.unreportedFreedCount
        removedCount += other.removedCount
        trashedCount += other.trashedCount
        deletedCount += other.deletedCount
        failed.append(contentsOf: other.failed)
        permissionDenied.append(contentsOf: other.permissionDenied)
        trashAccessDenied.append(contentsOf: other.trashAccessDenied)
        administratorApprovalCancelled = administratorApprovalCancelled || other.administratorApprovalCancelled
        applicationRemovalCancelled = applicationRemovalCancelled || other.applicationRemovalCancelled
        skippedWorktrees.append(contentsOf: other.skippedWorktrees)
        toolCommandResults.append(contentsOf: other.toolCommandResults)
    }
}

/// Removes selected entries, to the Trash or permanently.
///
/// Every removal is measured first and logged after, which is what separates this
/// from the predecessor's cleanup: that one summed the sizes recorded during the
/// scan, so a cache that had been rebuilt since the scan was reported as freed
/// anyway, and nothing was written down afterwards — leaving no record of what the
/// app had done to the user's disk.
public struct CleanupService: Sendable {

    /// Permanently removes an application after separate confirmation and a fresh safety check.
    public typealias ApplicationRemovalFallback = @Sendable (
        URL, @escaping @Sendable () -> Bool
    ) async throws -> Void
    private let applicationRemovalFallback: ApplicationRemovalFallback?
    private let administratorTrash: (@Sendable (AppleSoundLibrary.Inventory) async throws -> URL)?
    private let measureSize: @Sendable (URL) async throws -> SizeMeasurement
    /// Read per item in the instant before that item is removed. Kept out of the
    /// scan's measurement entirely — see ``PrivateSizeMeasurer`` for the 62 % that
    /// would have cost on every whole-disk walk.
    private let privateMeasurer = PrivateSizeMeasurer()
    private let log: RemovalLog
    private let dockerImages: DockerImageService
    private let toolCommands: ToolCommandRemovalService
    private let registeredApplications: @Sendable (Set<String>) -> Set<String>
    private let deleteCodexSession: @Sendable (CodexSessionReview) async throws -> Void
    private let reviewBuildCache: @Sendable (XcodeBuildCache.Review) async throws -> SizeMeasurement?
    private let worktreeTrashDirectory: @Sendable (URL) throws -> URL

    public init(
        measurer: AllocatedSizeMeasurer = AllocatedSizeMeasurer(),
        log: RemovalLog = RemovalLog(),
        dockerImages: DockerImageService = DockerImageService(),
        applicationRemovalFallback: ApplicationRemovalFallback? = nil,
        administratorTrash: (@Sendable (AppleSoundLibrary.Inventory) async throws -> URL)? = nil
    ) {
        self.init(measureSize: { try await measurer.measure($0) }, log: log,
                  registeredApplications: AppleSoundLibrary.registeredOwners, dockerImages: dockerImages,
                  reviewBuildCache: { try await XcodeBuildCache.measureForRemoval($0, with: measurer) },
                  applicationRemovalFallback: applicationRemovalFallback, administratorTrash: administratorTrash)
    }

    init(
        measureSize: @escaping @Sendable (URL) async throws -> SizeMeasurement,
        log: RemovalLog,
        registeredApplications: @escaping @Sendable (Set<String>) -> Set<String> = { _ in [] },
        dockerImages: DockerImageService = DockerImageService(),
        deleteCodexSession: @escaping @Sendable (CodexSessionReview) async throws -> Void = {
            try await CodexSessions(home: $0.codexHome).remove($0)
        },
        reviewBuildCache: @escaping @Sendable (XcodeBuildCache.Review) async throws -> SizeMeasurement? = {
            try await XcodeBuildCache.measureForRemoval($0, with: AllocatedSizeMeasurer())
        },
        worktreeTrashDirectory: @escaping @Sendable (URL) throws -> URL = {
            try FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: $0, create: true)
        },
        applicationRemovalFallback: ApplicationRemovalFallback? = nil,
        administratorTrash: (@Sendable (AppleSoundLibrary.Inventory) async throws -> URL)? = nil
    ) {
        self.administratorTrash = administratorTrash
        self.measureSize = measureSize
        self.log = log
        self.registeredApplications = registeredApplications
        self.dockerImages = dockerImages
        self.toolCommands = ToolCommandRemovalService()
        self.deleteCodexSession = deleteCodexSession
        self.reviewBuildCache = reviewBuildCache
        self.worktreeTrashDirectory = worktreeTrashDirectory
        self.applicationRemovalFallback = applicationRemovalFallback
    }

    /// - Parameters:
    ///   - entries: what to remove. An entry's `children` go with it.
    ///   - trashFirst: Preferences › General "Always move to Trash". Some categories
    ///     insist on it regardless — see ``alwaysMovesToTrash(_:)``.
    /// - Parameter keepReceipt: the sheet's "Keep a Put Back receipt" checkbox. Off
    ///   means nothing is written to the removal log — no paths, no destinations —
    ///   and so nothing from this run can be Put Back. That is the trade the user
    ///   chose; silently logging anyway would make the checkbox a lie.
    /// - Parameter userDataRemovalOverrides: protected user-data rows the user
    ///   explicitly unlocked after seeing the destructive warning. Running apps and
    ///   tool-managed rows remain refused even if their IDs appear here.
    /// - Parameter appDataRemovalOverrides: selected application bundles with an
    ///   explicit authorization to include protected related data. Without the exact
    ///   parent ID, cleanup removes the bundle and regenerable children but preserves
    ///   profiles, preferences, containers and other non-regenerable children.
    /// - Parameter expectedIdentities: reviewed identities that must still match.
    public func remove(
        entries: [FileEntry],
        trashFirst: Bool,
        keepReceipt: Bool = true,
        userDataRemovalOverrides: Set<FileEntry.ID> = [],
        appDataRemovalOverrides: Set<FileEntry.ID> = [],
        expectedIdentities: [FileEntry.ID: String] = [:],
        confirmedToolCommands: [FileEntry.ID: ToolCommandRemoval] = [:]
    ) async throws -> CleanupOutcome {
        var outcome = CleanupOutcome()
        let hasToolCommands = entries.contains { $0.toolCommand != nil }

        for (index, entry) in entries.enumerated() {
            // Between entries, never mid-item: a half-removed app bundle is worse
            // than one more removal after the user pressed stop.
            if Task.isCancelled, hasToolCommands {
                for skipped in entries[index...] {
                    guard let command = skipped.toolCommand else {
                        outcome.failed.append(skipped.id)
                        continue
                    }
                    var result = ToolCommandRemovalResult(targetID: skipped.id, name: skipped.displayName, command: command.command)
                    result.failureReason = "Removal stopped before this command ran."
                    recordToolCommand(result, in: &outcome)
                }
                break
            }
            try Task.checkCancellation()
            if outcome.administratorApprovalCancelled {
                outcome.failed.append(entry.id)
                continue
            }

            if hasToolCommands, entry.toolCommand == nil {
                // Finish the current file item before Stop starts another item.
                let ordinary = await Task.detached {
                    try await self.remove(entries: [entry], trashFirst: trashFirst, keepReceipt: keepReceipt,
                        userDataRemovalOverrides: userDataRemovalOverrides, appDataRemovalOverrides: appDataRemovalOverrides,
                        expectedIdentities: expectedIdentities)
                }.result
                switch ordinary {
                case .success(let result): outcome.merge(result)
                case .failure: outcome.failed.append(entry.id)
                }
                continue
            }

            if let review = entry.toolCommand {
                let result: ToolCommandRemovalResult
                do {
                    try log.checkWritable()
                    let confirmation = Self.removalAllowed(entry, userDataRemovalOverrides: userDataRemovalOverrides)
                        ? confirmedToolCommands[entry.id] : nil
                    result = await toolCommands.remove(entry, review: review, confirmed: confirmation)
                } catch {
                    var blocked = ToolCommandRemovalResult(targetID: entry.id, name: entry.displayName, command: review.command)
                    blocked.failureReason = "Cleanup History is unavailable. No removal command was run."
                    result = blocked
                }
                recordToolCommand(result, in: &outcome)
                continue
            }

            // Belt and braces beneath the UI's locks: a running app, tool-managed
            // row, or user-data row without its exact override is refused here too,
            // and lands in `failed` so the refusal is reported rather than silently
            // absorbed. Recent use is information for the user, not a veto.
            if !Self.removalAllowed(entry, userDataRemovalOverrides: userDataRemovalOverrides) {
                outcome.failed.append(entry.id)
                if keepReceipt { try? log.append([Self.failureRecord(for: entry)]) }
                continue
            }

            if let image = entry.dockerImage {
                var bytes = entry.allocatedBytes
                var disposition: RemovalDisposition = .failed
                do {
                    bytes = try await dockerImages.remove(image)
                    outcome.removedBytes += bytes
                    outcome.removedCount += 1
                    outcome.deletedCount += 1
                    outcome.unreportedFreedCount += 1
                    disposition = .deleted
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcome.failed.append(entry.id)
                }
                if keepReceipt {
                    try? log.append([RemovalRecord(
                        timestamp: Date(), originalPath: Self.dockerReceiptPath(for: entry),
                        bytes: bytes, disposition: disposition, freedBytes: 0
                    )])
                }
                continue
            }

            if let review = entry.codexSession {
                var measurements: [(CodexSessionReview.Member, Int64, Int64?)] = []
                for member in review.members {
                    let measured = try await measureSize(member.url).allocatedBytes
                    let freed = try await privateMeasurer.measure([member.url])
                    measurements.append((member, measured, freed.flatMap { $0.unreportedCount == 0 ? $0.privateBytes : nil }))
                }
                func recordDeleted(_ members: [CodexSessionReview.Member]) {
                    let ids = Set(members.map(\.threadID))
                    for (member, bytes, freed) in measurements where ids.contains(member.threadID) {
                        outcome.removedBytes += bytes
                        outcome.removedCount += 1
                        outcome.deletedCount += 1
                        if let freed { outcome.freedBytes += freed }
                        else { outcome.unreportedFreedCount += 1 }
                        if keepReceipt {
                            try? log.append([RemovalRecord(timestamp: Date(), originalPath: member.url.path,
                                bytes: bytes, disposition: .deleted, freedBytes: freed)])
                        }
                    }
                }
                do {
                    try await deleteCodexSession(review)
                    recordDeleted(review.members)
                } catch let partial as CodexSessions.PartialDeletion {
                    recordDeleted(partial.members)
                    outcome.failed.append(entry.url.path)
                    if keepReceipt { try? log.append([Self.failureRecord(for: entry)]) }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    outcome.failed.append(entry.url.path)
                    if keepReceipt { try? log.append([Self.failureRecord(for: entry)]) }
                }
                continue
            }

            let disposition: RemovalDisposition =
                (trashFirst || Self.alwaysMovesToTrash(entry)) ? .trashed : .deleted

            var records: [RemovalRecord] = []
            // Save completed removals even if a later measurement stops.
            defer {
                if keepReceipt { try? log.append(records) }
            }
            // Children before the bundle. For an app this list is deliberately
            // narrower unless the parent has its exact destructive override:
            // caches go with the app, profiles and settings stay by default.
            for target in Self.removalTargets(
                for: entry,
                removeProtectedAppData: appDataRemovalOverrides.contains(entry.id)
            ) {
                if outcome.administratorApprovalCancelled {
                    outcome.failed.append(target.id)
                    continue
                }
                guard soundLibraryIsStillSafe(target) else {
                    outcome.failed.append(target.url.path)
                    records.append(Self.failureRecord(for: target))
                    continue
                }
                if let expected = expectedIdentities[target.id],
                   FileIdentity.of(target.url) != expected {
                    outcome.failed.append(target.url.path)
                    records.append(Self.failureRecord(for: target))
                    continue
                }
                // Measured now rather than trusting the scan's figure, which may be
                // hours old. The measurer throws nothing but `CancellationError`, so
                // letting this propagate does not turn an unreadable file into an
                // aborted batch.
                let measured: Int64
                var freed: PrivateSizeMeasurement?
                if let review = target.xcodeBuildCacheReview {
                    freed = try? await privateMeasurer.measure([target.url])
                    guard review.url == target.url, let checked = try await reviewBuildCache(review) else {
                        outcome.failed.append(target.url.path)
                        records.append(Self.failureRecord(for: target))
                        continue
                    }
                    measured = checked.allocatedBytes
                } else {
                    measured = try await measureSize(target.url).allocatedBytes
                }

                if let expected = expectedIdentities[target.id],
                   FileIdentity.of(target.url) != expected {
                    outcome.failed.append(target.url.path)
                    records.append(Self.failureRecord(for: target, bytes: measured))
                    continue
                }

                // Build folder checks run after private-size measurement, immediately before removal.
                if target.xcodeBuildCacheReview == nil {
                    freed = try? await privateMeasurer.measure([target.url])
                }

                guard soundLibraryIsStillSafe(target) else {
                    outcome.failed.append(target.url.path)
                    records.append(Self.failureRecord(for: target, bytes: measured))
                    continue
                }

                let landed: URL?
                do {
                    if GitWorktreeDetector.isWorktree(target.url) {
                        let trash: URL
                        do { trash = try worktreeTrashDirectory(target.url) }
                        catch where FileAccessFailure.isPermissionDenied(error) {
                            outcome.trashAccessDenied.append(target.url.path)
                            throw error
                        }
                        var reserved: Set<String> = []
                        var destination = try Self.freeTrashPath(for: target.url, in: trash, reserved: &reserved)
                        let registered = try await GitWorktreeDetector.registeredPaths(for: target.url)
                        if registered.contains(destination.path) {
                            reserved.formUnion(registered)
                            destination = try Self.freeTrashPath(for: target.url, in: trash, reserved: &reserved)
                        }
                        if try await GitWorktreeDetector.move(target.url, to: destination) { landed = destination }
                        else { landed = try Self.discard(target.url, disposition: .trashed) }
                    } else {
                        do {
                            landed = try Self.discard(target.url, disposition: disposition)
                        } catch {
                            guard FileAccessFailure.isPermissionDenied(error), disposition == .trashed,
                                  keepReceipt, !outcome.administratorApprovalCancelled,
                                  let library = target.soundLibrary, let administratorTrash,
                                  soundLibraryIsStillSafe(target) else { throw error }
                            try log.checkWritable()
                            landed = try await administratorTrash(library)
                        }
                    }
                } catch let error as CocoaError where error.code == .fileNoSuchFile {
                    // Already gone: someone else removed it since the scan. That is
                    // the outcome the user wanted, not a failure — reporting it as
                    // one would keep a ghost row alive for a file that is not there.
                    _ = error
                    continue
                } catch {
                    if error as? AdministratorTrashError == .cancelled {
                        outcome.administratorApprovalCancelled = true
                    }
                    let trashAccessDenied: Bool
                    if case TrashError.unreadable = error { trashAccessDenied = true }
                    else { trashAccessDenied = false }
                    let permissionDenied = trashAccessDenied || FileAccessFailure.isPermissionDenied(error)
                    outcome.failed.append(target.url.path)
                    if permissionDenied { outcome.permissionDenied.append(target.url.path) }
                    if trashAccessDenied { outcome.trashAccessDenied.append(target.url.path) }
                    records.append(Self.failureRecord(for: target, bytes: measured))
                    continue
                }

                outcome.removedBytes += measured
                if let freed { outcome.freedBytes += freed.privateBytes }
                else { outcome.unreportedFreedCount += 1 }
                outcome.removedCount += 1
                if disposition == .trashed { outcome.trashedCount += 1 }
                else { outcome.deletedCount += 1 }

                records.append(RemovalRecord(
                    timestamp: Date(),
                    originalPath: target.url.path,
                    bytes: measured,
                    disposition: disposition,
                    trashedPath: landed?.path,
                    // Read now, while the item is certainly the one just trashed.
                    trashedIdentity: landed.flatMap(FileIdentity.of),
                    freedBytes: freed?.privateBytes
                ))
            }
        }

        return outcome
    }

    private func recordToolCommand(_ result: ToolCommandRemovalResult, in outcome: inout CleanupOutcome) {
        var result = result
        outcome.removedBytes += result.removedBytes ?? 0
        outcome.freedBytes += result.freedBytes ?? 0
        if result.freedBytes == nil, result.status == .completed || (result.removedBytes ?? 0) > 0 {
            outcome.unreportedFreedCount += 1
        }
        if result.status == .completed {
            outcome.removedCount += 1
            outcome.deletedCount += 1
        } else {
            outcome.failed.append(result.targetID)
        }
        do {
            try log.append([RemovalRecord(timestamp: Date(), originalPath: result.targetID,
                bytes: result.removedBytes ?? 0,
                disposition: result.status == .completed ? .deleted : .failed,
                freedBytes: result.freedBytes ?? 0, toolCommandResult: result)])
        } catch {
            result.failureReason = [result.failureReason, "Cleanup History could not save this result."]
                .compactMap { $0 }.joined(separator: " ")
        }
        outcome.toolCommandResults.append(result)
    }

    private func soundLibraryIsStillSafe(_ entry: FileEntry) -> Bool {
        guard let library = entry.soundLibrary else { return true }
        return entry.url.standardizedFileURL == library.url
            && library.isStillSafe(registeredOwners: registeredApplications(library.ownerIdentifiers))
    }

    /// Moves selected downloaded content while keeping the installed application.
    public func removeSoundLibraries(
        _ plan: AppUninstallPlan, itemPaths: Set<String>,
        keepReceipt: Bool = true
    ) async throws -> CleanupOutcome {
        let items = plan.soundLibraryItems.filter { itemPaths.contains($0.id) && $0.soundLibrary != nil }
        guard !items.isEmpty else { return CleanupOutcome() }
        return try await remove(
            entries: items.map(\.fileEntry), trashFirst: true,
            keepReceipt: keepReceipt,
            expectedIdentities: Dictionary(uniqueKeysWithValues: items.compactMap { item in
                item.plannedIdentity.map { (item.id, $0) }
            })
        )
    }

    /// Executes a dedicated application uninstall plan.
    ///
    /// The application moves to Trash first. A denied move can request separate permanent-removal confirmation.
    /// Related files move to Trash only after successful application removal.
    public func uninstall(
        _ plan: AppUninstallPlan,
        keepReceipt: Bool = true,
        confirmPermanentRemoval: @escaping @Sendable () async -> Bool = { false }
    ) async throws -> CleanupOutcome {
        var outcome = CleanupOutcome()
        guard plan.managedPackage == nil else {
            // HomebrewUninstallService handles managed packages and their records.
            // This filesystem path must never remove a managed application directly.
            outcome.failed = [plan.applicationURL.path]
            if keepReceipt {
                try? log.append([Self.failureRecord(for: plan.applicationItem.fileEntry)])
            }
            return outcome
        }
        return try await removeApplicationItems(
            plan, includingApplication: true, keepReceipt: keepReceipt, confirmPermanentRemoval: confirmPermanentRemoval
        )
    }

    /// Homebrew must finish package removal before this method can move related data.
    func removeRelatedFilesAfterHomebrew(
        _ plan: AppUninstallPlan,
        keepReceipt: Bool
    ) async -> CleanupOutcome {
        guard plan.managedPackage != nil else {
            return CleanupOutcome(failed: plan.items.dropFirst().map { $0.url.path })
        }
        // This mode records cancellation and measurement failures without losing completed results.
        do {
            return try await removeApplicationItems(
                plan, includingApplication: false, keepReceipt: keepReceipt
            )
        } catch {
            return CleanupOutcome(failed: plan.items.dropFirst().map { $0.url.path })
        }
    }

    private func removeApplicationItems(
        _ plan: AppUninstallPlan,
        includingApplication: Bool,
        keepReceipt: Bool,
        confirmPermanentRemoval: @escaping @Sendable () async -> Bool = { false }
    ) async throws -> CleanupOutcome {
        var outcome = CleanupOutcome()
        var failedSubtrees = Set<String>()
        let removalOrder = includingApplication ? plan.removalOrder() : Array(plan.removalOrder().dropFirst())
        guard !removalOrder.isEmpty else { return outcome }

        func recordFailure(_ item: AppUninstallPlan.Item, bytes: Int64? = nil) {
            failedSubtrees.insert(item.url.path)
            if !outcome.failed.contains(item.url.path) {
                outcome.failed.append(item.url.path)
                if keepReceipt {
                    try? log.append([Self.failureRecord(for: item.fileEntry, bytes: bytes)])
                }
            }
        }

        var exclusiveBundleIdentifiers: Set<String>?

        for (index, item) in removalOrder.enumerated() {
            if includingApplication {
                if Task.isCancelled, index > 0 {
                    for remaining in removalOrder[index...] { recordFailure(remaining) }
                    return outcome
                }
                try Task.checkCancellation()
            } else {
                // A replacement application at the same path must keep its data.
                guard !Task.isCancelled, FileIdentity.isAbsent(plan.applicationURL) else {
                    for remaining in removalOrder[index...] { recordFailure(remaining) }
                    return outcome
                }
                if FileIdentity.isAbsent(item.url) { continue }
            }
            // A planned containing folder must not smuggle through a descendant
            // that just failed its own identity, ownership, or permission check.
            // Leave the whole subtree where it is and report both review rows.
            if failedSubtrees.contains(where: {
                $0.hasPrefix(item.url.path + "/")
            }) {
                recordFailure(item)
                continue
            }
            // Check current owners only when related files can be removed, after the application removal succeeds.
            if item.content != .application, exclusiveBundleIdentifiers == nil {
                do {
                    exclusiveBundleIdentifiers = try AppUninstallPlanner.exclusiveBundleIdentifiers(
                        candidates: Set(removalOrder.compactMap(\.ownerBundleIdentifier)),
                        selectedApplication: plan.applicationURL,
                        applicationRoots: plan.applicationRoots,
                        checkCancellation: Task.checkCancellation
                    )
                } catch {
                    for remaining in removalOrder[index...] { recordFailure(remaining) }
                    return outcome
                }
            }
            guard AppUninstallPlanner.removalIsStillSafe(
                item, in: plan, exclusiveBundleIdentifiers: exclusiveBundleIdentifiers ?? []
            ) else {
                recordFailure(item)
                // The bundle is the transaction gate. Nothing related moves when
                // the app itself no longer matches the reviewed plan.
                if includingApplication && index == 0 { return outcome }
                continue
            }

            let measured: Int64
            do {
                measured = try await measureSize(item.url).allocatedBytes
            } catch {
                if includingApplication && index == 0 { throw error }
                recordFailure(item)
                continue
            }
            let freed = try? await privateMeasurer.measure([item.url])
            do {
                var disposition: RemovalDisposition = .trashed
                let landed: URL?
                do {
                    landed = try Self.discard(item.url, disposition: .trashed)
                } catch {
                    guard includingApplication, index == 0, FileAccessFailure.isPermissionDenied(error),
                          let applicationRemovalFallback else { throw error }
                    try Task.checkCancellation()
                    guard await confirmPermanentRemoval() else { throw ApplicationRemovalError.cancelled }
                    try Task.checkCancellation()
                    guard AppUninstallPlanner.removalIsStillSafe(
                        item, in: plan, exclusiveBundleIdentifiers: []
                    ), FileIdentity.of(item.url) == item.plannedIdentity else { throw CocoaError(.fileWriteUnknown) }
                    do {
                        try await applicationRemovalFallback(item.url) {
                            AppUninstallPlanner.removalIsStillSafe(
                                item, in: plan, exclusiveBundleIdentifiers: []
                            ) && FileIdentity.of(item.url) == item.plannedIdentity
                        }
                    } catch let error as CocoaError where error.code == .fileNoSuchFile {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    guard FileIdentity.isAbsent(item.url) else { throw CocoaError(.fileWriteUnknown) }
                    disposition = .deleted
                    landed = nil
                }
                outcome.removedBytes += measured
                if let freed { outcome.freedBytes += freed.privateBytes }
                else { outcome.unreportedFreedCount += 1 }
                outcome.removedCount += 1
                if disposition == .deleted { outcome.deletedCount += 1 }
                else { outcome.trashedCount += 1 }
                if keepReceipt {
                    try? log.append([RemovalRecord(
                        timestamp: Date(),
                        originalPath: item.url.path,
                        bytes: measured,
                        disposition: disposition,
                        trashedPath: landed?.path,
                        trashedIdentity: landed.flatMap(FileIdentity.of)
                    )])
                }
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                // Finder or an updater removed it after planning. For the app bundle
                // this still opens the gate: the requested state has been reached.
                _ = error
                continue
            } catch {
                recordFailure(item, bytes: measured)
                if FileAccessFailure.isPermissionDenied(error) { outcome.permissionDenied.append(item.url.path) }
                if error is ApplicationRemovalError {
                    outcome.applicationRemovalCancelled = true
                    return outcome
                }
                if includingApplication && index == 0 { return outcome }
            }
        }

        return outcome
    }

    /// Moves selected application leftovers to the Trash after a second owner check.
    public func removeOrphanedAppLeftovers(
        _ plan: OrphanedAppLeftoverPlan,
        bundleIdentifiers: Set<String>,
        itemPaths: Set<String>? = nil,
        registeredApplicationBundleIdentifiers: Set<String> = [],
        keepReceipt: Bool = true
    ) async throws -> CleanupOutcome {
        var installed = AppUninstallPlanner.installedBundleIdentifiers(
            in: plan.applicationRoots
        )
        installed.formUnion(registeredApplicationBundleIdentifiers)
        let selected = plan.items(for: bundleIdentifiers, itemPaths: itemPaths)
        var outcome = CleanupOutcome()
        var safeEntries: [FileEntry] = []

        for item in selected {
            try Task.checkCancellation()
            guard OrphanedAppLeftoverPlan.removalIsStillSafe(
                item, in: plan, installedBundleIdentifiers: installed
            ) else {
                outcome.failed.append(item.url.path)
                if keepReceipt {
                    try? log.append([Self.failureRecord(for: item.fileEntry)])
                }
                continue
            }
            safeEntries.append(item.fileEntry)
        }

        guard !safeEntries.isEmpty else { return outcome }
        let removed = try await remove(
            entries: safeEntries,
            trashFirst: true,
            keepReceipt: keepReceipt,
            userDataRemovalOverrides: Set(safeEntries.map(\.id))
        )
        outcome.merge(removed)
        return outcome
    }

    // MARK: - Removal records

    private static func failureRecord(
        for entry: FileEntry,
        bytes: Int64? = nil
    ) -> RemovalRecord {
        RemovalRecord(
            timestamp: Date(),
            originalPath: entry.dockerImage != nil ? Self.dockerReceiptPath(for: entry) : entry.url.path,
            bytes: max(0, bytes ?? entry.allocatedBytes),
            disposition: .failed
        )
    }

    private static func dockerReceiptPath(for entry: FileEntry) -> String {
        var url = URLComponents(url: entry.url, resolvingAgainstBaseURL: false)
        url?.queryItems = [URLQueryItem(name: "name", value: entry.displayName)]
        return url?.string ?? entry.id
    }

    // MARK: - Disposition

    /// The concrete paths one selected row will remove.
    ///
    /// Non-application aggregates retain their original all-children semantics. An
    /// application is different: its non-regenerable children are user state, so
    /// they survive unless that exact app has explicit complete-removal authorization.
    /// A running or tool-managed child is never smuggled through by the parent.
    public static func removalTargets(
        for entry: FileEntry,
        removeProtectedAppData: Bool
    ) -> [FileEntry] {
        if entry.toolCommand != nil { return [entry] }
        if entry.xcodeBuildCacheReview?.isWholeFolder == true {
            var folder = entry
            folder.allocatedBytes = entry.displayBytes
            folder.children = []
            return [folder]
        }
        guard entry.kind == .appBundle else {
            var parent = entry
            // Remainder rows share paths with worktrees. Their bytes belong to the final parent target.
            parent.allocatedBytes += entry.children.filter { $0.protectionReason == .folderRemainder }
                .reduce(0) { $0 + $1.allocatedBytes }
            parent.children.removeAll { $0.protectionReason == .folderRemainder }
            return parent.children + [parent]
        }

        let children = entry.children.filter { child in
            if child.manualRemoval != nil || child.toolCommand != nil || child.protectionReason == .running || child.protectionReason == .inventory
                || child.protectionReason == .folderRemainder || child.soundLibrary != nil {
                return false
            }
            return child.isRegenerable || removeProtectedAppData
        }
        return children + [entry]
    }

    /// The service-side gate beneath the UI. Only a user-data lock can be
    /// deliberately overridden; a running process or a tool-managed aggregate is a
    /// real inability to remove the row safely, not merely a caution.
    static func removalAllowed(
        _ entry: FileEntry,
        userDataRemovalOverrides: Set<FileEntry.ID>
    ) -> Bool {
        if entry.manualRemoval != nil || entry.protectionReason == .running || entry.protectionReason == .folderRemainder
            || entry.protectionReason == .inventory || entry.dockerImage?.isRemovalLocked == true
            || entry.toolCommand?.lockReason != nil
            || (entry.kind != .appBundle && entry.children.contains { $0.toolCommand != nil })
            || !entry.unlockableChildren.isEmpty { return false }
        if entry.codexSession != nil {
            return entry.protectionReason == .userData && userDataRemovalOverrides.contains(entry.id)
        }
        if entry.protectionReason == .userData {
            return userDataRemovalOverrides.contains(entry.id)
        }
        return true
    }

    /// `FileEntry` does not carry the category it came from, and cleanup needs
    /// two conservative rules: applications follow
    /// ``CategoryID/alwaysMovesToTrash``, and an individually unlocked user-data row
    /// always gets the same recovery path. A bundle's children inherit the bundle's
    /// disposition, since they are removed as part of it.
    public static func alwaysMovesToTrash(_ entry: FileEntry) -> Bool {
        if entry.codexSession != nil { return false }
        return (entry.kind == .appBundle && CategoryID.applications.alwaysMovesToTrash)
            || entry.protectionReason == .userData
            || entry.soundLibrary != nil
            || entry.xcodeBuildCacheReview.map { !$0.isRegenerable } == true
            || entry.isGitWorktree || GitWorktreeDetector.isWorktree(entry.url)
            || entry.children.contains { $0.isGitWorktree || GitWorktreeDetector.isWorktree($0.url) }
    }

    /// A path in the Trash that is free on disk *and* not already promised to
    /// another item in this batch. `Report.pdf`, `Report 2.pdf`, `Report 3.pdf`…,
    /// which is also what Finder does.
    static func freeTrashPath(
        for source: URL, in trash: URL, reserved: inout Set<String>
    ) throws -> URL {
        func accessError() -> Error {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            return FileAccessFailure.isPermissionDenied(error) ? TrashError.unreadable(trash.path) : error
        }
        guard let directory = opendir(trash.path) else { throw accessError() }
        closedir(directory)
        let trash = trash.resolvingSymlinksInPath()
        let base = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        func candidate(_ suffix: String) -> URL {
            let name = base + suffix
            let url = trash.appendingPathComponent(name)
            return ext.isEmpty ? url : url.appendingPathExtension(ext)
        }
        var attempt = candidate("")
        var counter = 2
        // `lstat`, not `fileExists`: the latter follows symlinks, so a dangling
        // link in the Trash looked like a free name and the move would have
        // replaced it.
        func occupied(_ url: URL) throws -> Bool {
            var info = stat()
            if lstat(url.path, &info) == 0 { return true }
            if errno == ENOENT { return false }
            throw accessError()
        }
        while try reserved.contains(attempt.path) || occupied(attempt) {
            attempt = candidate(" \(counter)")
            counter += 1
        }
        reserved.insert(attempt.path)
        return attempt
    }

    /// Returns where a trashed item landed; `nil` for a permanent deletion.
    private static func discard(_ url: URL, disposition: RemovalDisposition) throws -> URL? {
        switch disposition {
        case .trashed:
            var landed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &landed)
            return landed as URL?
        case .deleted:
            try FileManager.default.removeItem(at: url)
            return nil
        case .restored:
            // Never a removal instruction — `restored` exists only as a log
            // tombstone written by Put Back.
            return nil
        case .failed, .skipped:
            // Never a removal instruction. This value records an attempt only.
            return nil
        }
    }
}
