import AppKit
import SwiftUI
import MoppoCore

/// Shows worktree checks before the user selects removal.
struct WorktreeReviewSheet: View {
    let entry: FileEntry
    let onReview: (GitWorktreeReview) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void
    let reviewWorktree: (URL) async throws -> GitWorktreeReview
    @State private var review: GitWorktreeReview
    @State private var isChecking = false

    init(entry: FileEntry, onReview: @escaping (GitWorktreeReview) -> Void,
         onSelect: @escaping () -> Void, onClose: @escaping () -> Void,
         reviewWorktree: @escaping (URL) async throws -> GitWorktreeReview = {
             try await ScanLog.reviewWorktrees([$0], source: "dialog")[$0] ?? GitWorktreeReview()
         }) {
        self.entry = entry
        self.onReview = onReview
        self.onSelect = onSelect
        self.onClose = onClose
        self.reviewWorktree = reviewWorktree
        _review = State(initialValue: entry.gitWorktreeReview ?? GitWorktreeReview())
    }

    private var isSafe: Bool { !isChecking && review.isSafeToRemove }
    private var hasProblem: Bool { !isChecking && review.outcome.isProblem }
    private var verdictFill: Color {
        if isSafe { return Token.color(.green).opacity(0.09) }
        if hasProblem { return Token.color(.orange).opacity(0.09) }
        return Token.Fill.control
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                FileEntryIcon(entry: entry, presentation: FileEntryPresentation(entry: entry, localized: true), symbolSize: 32)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(entry.localizedDisplayName).foregroundStyle(Token.Text.primary)
                            .lineLimit(1).truncationMode(.middle)
                        Text("· " + ByteFormatting.localizedString(entry.displayBytes)).foregroundStyle(Token.Text.secondary).fixedSize()
                    }.font(.mcToolbarTitle)
                    Label(review.localizedBranch, systemImage: "arrow.triangle.branch")
                        .font(.mcSubtitle).foregroundStyle(Token.Text.secondary).lineLimit(1).truncationMode(.middle)
                    Text(FileEntry.abbreviate(entry.url.path)).font(.mcMonoPath)
                        .foregroundStyle(Token.Text.secondary).lineLimit(1).truncationMode(.middle).help(entry.url.path)
                }
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.mcSubtitle)
                        .frame(width: 24, height: 24)
                        .contentShape(Circle())
                }
                    .buttonStyle(.plain).background(Token.Fill.control, in: Circle())
                    .accessibilityLabel("Close worktree review")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    GroupedBox(fill: verdictFill) {
                        HStack(alignment: .top, spacing: 10) {
                            HoverHelpIcon(
                                systemName: isSafe ? "checkmark.circle.fill" : hasProblem ? "exclamationmark.circle.fill" : "questionmark.circle.fill",
                                text: isChecking ? verdict : verificationDetails,
                                color: isSafe ? Token.color(.green) : hasProblem ? Token.color(.orange) : Token.Text.disabled)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(isChecking ? String(localized: "Checking worktree") : review.localizedStatusLabel)
                                    .font(.mcSectionHeader)
                                Text(verdict).font(.mcBody).foregroundStyle(Token.Text.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    section(String(localized: "Checks")) {
                        check(String(localized: "Merge"), state: review.localizedMergeCheck,
                            clear: review.mergedInto.map { target in
                                review.mergePullRequestNumber.map { String(localized: "PR #\($0) → \(target)") } ?? String(localized: "Into \(target)")
                            } ?? "",
                            detail: review.mergePullRequestNumber == nil ? String(localized: "Confirmed using saved remote data.")
                                : String(localized: "Confirmed by GitHub and saved Git history."),
                            unknown: review.openPullRequestNumber.map { String(localized: "PR #\($0) open") } ?? String(localized: "Not confirmed"))
                        Divider()
                        check(String(localized: "Uncommitted changes"), state: review.localizedLocalFilesCheck)
                        Divider()
                        check(String(localized: "Unpushed commits"), state: review.localizedPushCheck,
                            clear: review.lastFetchDate == nil ? String(localized: "None") : String(localized: "None · last fetch \(fetchDate)"),
                            detail: String(localized: "Compared with saved remote data. Last fetch: \(fetchDate)"))
                        Divider()
                        check(String(localized: "Ignored files"), state: review.localizedIgnoredFilesCheck,
                            clear: review.ignoredFiles.isEmpty ? String(localized: "None") : review.mergedInto != nil
                                ? String(localized: "Included with merged worktree")
                                : review.copiedIgnoredFiles.isEmpty ? String(localized: "Regenerable files only") : String(localized: "Regenerable files and copies"))
                        Divider()
                        check(String(localized: "Git locks"), state: review.localizedLocks)
                        Divider()
                        check(String(localized: "In use"), state: review.localizedActivity, clear: String(localized: "Not detected"))
                    }
                    if !review.localFiles.isEmpty { files(String(localized: "Files only on this Mac"), items: review.localFiles) }
                    if !review.localIgnoredFiles.isEmpty {
                        files(String(localized: "Local ignored files"), items: review.localIgnoredFiles, showsBytes: true)
                    }
                    if !review.copiedIgnoredFiles.isEmpty {
                        files(String(localized: "Copies in the main checkout"), items: review.copiedIgnoredFiles, showsBytes: true)
                    }
                    if !review.unverifiedIgnoredFiles.isEmpty {
                        files(String(localized: "Unverified files"), items: review.unverifiedIgnoredFiles, showsBytes: true)
                    }
                    if !review.regenerableIgnoredFiles.isEmpty {
                        files(String(localized: "Regenerable files"), items: review.regenerableIgnoredFiles, showsBytes: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack(spacing: 8) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                Button("Check Again") { isChecking = true }
                    .disabled(isChecking)
                Spacer()
                if isSafe {
                    Button("Select for removal", action: onSelect)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent), size: .small))
                } else {
                    Button("Select anyway", action: onSelect).disabled(isChecking)
                    Button("Done", action: onClose)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent), size: .small))
                }
            }
            .buttonStyle(PageActionButtonStyle(size: .small))
            .padding(16)
        }
        .frame(width: 500, height: 620)
        .presentationBackground(Token.chrome)
        .background(WorktreeReviewWindowBehavior())
        .background {
            Button("Close worktree review", action: onClose).keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .task(id: isChecking) {
            guard isChecking else { return }
            do {
                let current = try await reviewWorktree(entry.url)
                try Task.checkCancellation()
                review = current
                onReview(current)
                isChecking = false
            } catch is CancellationError { }
            catch {
                review = GitWorktreeReview()
                onReview(review)
                isChecking = false
            }
        }
    }

    private var fetchDate: String {
        review.lastFetchDate?.formatted(date: .abbreviated, time: .omitted) ?? String(localized: "Unavailable")
    }

    private var verificationDetails: String {
        [
            (String(localized: "Merge"), review.localizedMergeCheck),
            (String(localized: "Uncommitted changes"), review.localizedLocalFilesCheck),
            (String(localized: "Unpushed commits"), review.localizedPushCheck),
            (String(localized: "Ignored files"), review.localizedIgnoredFilesCheck),
            (String(localized: "Git locks"), review.localizedLocks),
            (String(localized: "In use"), review.localizedActivity)
        ].compactMap { title, state in
            state.reason.map { String(localized: "\(title): \($0)") }
        }.joined(separator: "\n")
    }

    private var verdict: String {
        if isChecking { return String(localized: "Moppo is checking local files, commits, locks, and open files.") }
        if isSafe {
            if review.mergedInto != nil {
                if review.mergePullRequestNumber != nil {
                    return String(localized: "GitHub and saved Git history confirm this merge. Removal includes all ignored local files, including environment files.")
                }
                return String(localized: "Saved remote data contains these commits. Removal includes all ignored local files, including environment files.")
            }
            if !review.copiedIgnoredFiles.isEmpty {
                return String(localized: "All checks passed using saved remote data. Project tools can recreate the ignored files, or the main checkout has identical copies.")
            }
            return String(localized: "All checks passed using saved remote data. Git and project tools can recreate these files.")
        }
        if let path = review.missingGitData {
            return String(localized: "Git cannot read this worktree because its Git data is missing at \(path). Someone removed the main repository, or a virtual machine, such as the Claude VM, owns this worktree.")
        }
        var findings: [String] = []
        if let number = review.openPullRequestNumber {
            findings.append(String(localized: "Pull request #\(number) is open. GitHub has all commits of this worktree, but the merge is not complete."))
        }
        if review.status == .uncommittedChanges || !review.localFiles.isEmpty {
            let count = review.localFiles.count
            findings.append(count == 0 ? String(localized: "This worktree has uncommitted changes.")
                : String(localized: "\(count) file has local changes.", bundle: MoppoResources.bundle, locale: MoppoResources.locale))
        }
        if case .found = review.localizedPushCheck, let count = review.unpushedCommitCount {
            findings.append(String(localized: "\(count) commit is absent from the saved remote data.", bundle: MoppoResources.bundle, locale: MoppoResources.locale))
        }
        if case .found = review.localizedIgnoredFilesCheck {
            findings.append(String(localized: "Some ignored files need review. Verified caches and dependencies appear separately."))
        }
        if case .found = review.localizedLocks { findings.append(String(localized: "Git locks are present.")) }
        if case .found = review.localizedActivity { findings.append(String(localized: "An open process uses this worktree.")) }
        if let reason = review.localizedActivity.reason { findings.append(reason) }
        if !findings.isEmpty { return findings.joined(separator: " ") }
        return String(localized: "Moppo could not complete every check.")
    }

    private func check(_ title: String, state: GitWorktreeReview.Check, clear: String = String(localized: "None"),
                       detail: String? = nil, unknown: String = String(localized: "Couldn't check")) -> some View {
        let problem: Bool = if case .found = state { true } else { false }
        let value: String = switch state {
        case .clear: clear
        case .found(let value): value
        case .unknown: unknown
        }
        return HStack(spacing: 9) {
            HoverHelpIcon(
                systemName: problem ? "exclamationmark.circle.fill" : state == .clear ? "checkmark.circle.fill" : "questionmark.circle.fill",
                text: state.reason ?? detail ?? "",
                color: state == .clear ? Token.color(.green) : problem ? Token.color(.orange) : Token.Text.disabled)
            Text(title).fontWeight(problem ? .semibold : .regular)
                .foregroundStyle(problem ? Token.textColor(.orange) : Token.Text.primary)
            Spacer(minLength: 12)
            Text(value).fontWeight(problem ? .semibold : .regular)
                .foregroundStyle(problem ? Token.textColor(.orange) : Token.Text.secondary)
                .multilineTextAlignment(.trailing).lineLimit(2)
        }
        .font(.mcBody).padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func section<Content: View>(_ title: String, detail: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        GroupedBox(fill: Token.Fill.cardContent) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text(title).font(.mcSectionHeader)
                    if let detail { Text(detail).font(.mcSubtitle).foregroundStyle(Token.Text.secondary) }
                    Spacer()
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Token.Fill.control, in: UnevenRoundedRectangle(
                    topLeadingRadius: Token.Radius.box, topTrailingRadius: Token.Radius.box
                ))
                Divider()
                content()
            }
        }
    }

    private func files(_ title: String, items: [GitWorktreeReview.File], showsBytes: Bool = false) -> some View {
        let detail = String(items.count) + (showsBytes ? " · " + ByteFormatting.localizedString(items.reduce(0) { $0 + $1.allocatedBytes }) : "")
        return section(title, detail: detail) {
            VStack(spacing: 0) {
                ForEach(items) { file in
                    if file.id != items.first?.id { Divider() }
                    HStack(spacing: 8) {
                        Text(file.path).font(.mcMonoPath).lineLimit(1).truncationMode(.middle).help(file.path)
                        Spacer(minLength: 8)
                        let included = review.includesAfterMerge(file)
                        let label = file.status == .ignored
                            ? (file.regeneratesSafely == true ? String(localized: "Regenerable") : included ? String(localized: "Included")
                               : file.hasMainCheckoutCopy ? String(localized: "Copy")
                               : file.regeneratesSafely == false ? String(localized: "Review") : String(localized: "Unverified"))
                            : file.status.localizedLabel
                        Badge(text: label, style: file.regeneratesSafely == true || included || file.hasMainCheckoutCopy ? .safe
                            : file.status == .changed || file.regeneratesSafely == false ? .review : .neutral).fixedSize()
                    }.padding(.horizontal, 14).padding(.vertical, 7)
                }
            }
        }
    }
}

/// Allows quitting from the review on all supported macOS versions.
private struct WorktreeReviewWindowBehavior: NSViewRepresentable {
    func makeNSView(context: Context) -> DialogAnchorView { DialogAnchorView() }

    func updateNSView(_ nsView: DialogAnchorView, context: Context) {
        nsView.onWindowChange = { window in
            window?.preventsApplicationTerminationWhenModal = false
        }
        nsView.window?.preventsApplicationTerminationWhenModal = false
    }
}
