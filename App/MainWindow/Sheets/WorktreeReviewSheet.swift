import AppKit
import SwiftUI
import MoppoCore

/// Shows worktree checks before the user selects removal.
struct WorktreeReviewSheet: View {
    let entry: FileEntry
    let onReview: (GitWorktreeReview) -> Void
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var review = GitWorktreeReview()
    @State private var isChecking = true

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
                FileEntryIcon(entry: entry, presentation: FileEntryPresentation(entry: entry), symbolSize: 32)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text(entry.displayName).foregroundStyle(Token.Text.primary)
                            .lineLimit(1).truncationMode(.middle)
                        Text("· " + ByteFormatting.string(entry.displayBytes)).foregroundStyle(Token.Text.secondary).fixedSize()
                    }.font(.mcToolbarTitle)
                    Label(review.branch, systemImage: "arrow.triangle.branch")
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
                                Text(isChecking ? "Checking worktree" : review.statusLabel)
                                    .font(.mcSectionHeader)
                                Text(verdict).font(.mcBody).foregroundStyle(Token.Text.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                    }
                    section("Checks") {
                        check("Uncommitted changes", state: review.localFilesCheck)
                        Divider()
                        check("Unpushed commits", state: review.pushCheck,
                            clear: review.lastFetchDate == nil ? "None" : "None · last fetch " + fetchDate,
                            detail: "Compared with saved remote data. Last fetch: " + fetchDate)
                        Divider()
                        check("Ignored files", state: review.ignoredFilesCheck,
                            clear: review.ignoredFiles.isEmpty ? "None" : "Build output only")
                        Divider()
                        check("Git locks", state: review.locks)
                        Divider()
                        check("In use", state: review.activity, clear: "Not detected")
                    }
                    if !review.localFiles.isEmpty { files("Files only on this Mac", items: review.localFiles) }
                    if !review.ignoredFiles.isEmpty {
                        files("Ignored files", items: review.ignoredFiles, detail: "\(review.ignoredFiles.count) · \(ByteFormatting.string(review.ignoredBytes))")
                    }
                    Text(nextStep).font(.mcSubtitle).foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            Divider()
            HStack(spacing: 8) {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
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
        .background {
            Button("Close worktree review", action: onClose).keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
        .task(id: entry.id) {
            review = entry.gitWorktreeReview ?? GitWorktreeReview()
            isChecking = true
            do {
                let current = try await GitWorktreeReviewService().review(entry.url)
                try Task.checkCancellation()
                review = current
                onReview(current)
                isChecking = false
            } catch is CancellationError { }
            catch { review = GitWorktreeReview(); isChecking = false }
        }
    }

    private var fetchDate: String {
        review.lastFetchDate?.formatted(date: .abbreviated, time: .omitted) ?? "Unavailable"
    }

    private var verificationDetails: String {
        [
            ("Uncommitted changes", review.localFilesCheck),
            ("Unpushed commits", review.pushCheck),
            ("Ignored files", review.ignoredFilesCheck),
            ("Git locks", review.locks),
            ("In use", review.activity)
        ].compactMap { title, state in
            state.reason.map { "\(title): \($0)" }
        }.joined(separator: "\n")
    }

    private var verdict: String {
        if isChecking { return "Moppo is checking local files, commits, locks, and open files." }
        if isSafe {
            return "All checks passed using the saved remote data. You can recreate these files from Git."
        }
        var findings: [String] = []
        if review.status == .uncommittedChanges || !review.localFiles.isEmpty {
            let count = review.localFiles.count
            findings.append(count == 0 ? "This worktree has uncommitted changes."
                : "\(count) \(count == 1 ? "file has" : "files have") local changes.")
        }
        if case .found = review.pushCheck, let count = review.unpushedCommitCount {
            findings.append("\(count) \(count == 1 ? "commit is" : "commits are") absent from the saved remote data.")
        }
        if case .found = review.ignoredFilesCheck {
            findings.append("Ignored files can contain local settings or user data.")
        }
        if case .found = review.locks { findings.append("Git locks are present.") }
        if case .found = review.activity { findings.append("An open process uses this worktree.") }
        if !findings.isEmpty { return findings.joined(separator: " ") }
        return "Moppo could not complete every check."
    }

    private var nextStep: String {
        if isChecking { return "Wait for the checks before you select removal." }
        switch review.outcome {
        case .safeToRemove:
            return "Select this worktree to move it to the Trash. You can put it back with a saved receipt."
        case .inUse:
            return "Close the tool session. Wait for Git to finish. If you select it anyway, Moppo moves it to the Trash."
        case .uncommittedChanges, .unpushedCommits:
            return "Save your local work before removal. If you select it anyway, Moppo moves it to the Trash."
        case .hasLocalFiles:
            return "Review the ignored files before removal. If you select it anyway, Moppo moves it to the Trash."
        case .couldNotVerify:
            return "Complete the checks in your Git tool before removal. If you select it anyway, Moppo moves it to the Trash."
        }
    }

    private func check(_ title: String, state: GitWorktreeReview.Check, clear: String = "None",
                       detail: String? = nil) -> some View {
        let problem: Bool = if case .found = state { true } else { false }
        let value: String = switch state {
        case .clear: clear
        case .found(let value): value
        case .unknown: "Couldn't check"
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

    private func files(_ title: String, items: [GitWorktreeReview.File], detail: String? = nil) -> some View {
        section(title, detail: detail ?? String(items.count)) {
            VStack(spacing: 0) {
                ForEach(items) { file in
                    if file.id != items.first?.id { Divider() }
                    HStack(spacing: 8) {
                        Text(file.path).font(.mcMonoPath).lineLimit(1).truncationMode(.middle).help(file.path)
                        Spacer(minLength: 8)
                        Badge(text: file.status.rawValue, style: file.status == .changed ? .review : .neutral).fixedSize()
                    }.padding(.horizontal, 14).padding(.vertical, 7)
                }
            }
        }
    }
}
