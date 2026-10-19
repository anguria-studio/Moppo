import AppKit
import SwiftUI
import MoppoCore

struct HomebrewRemovalExplanation: View {
    var isBatchReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(isBatchReview
                ? "Apps removed with Homebrew cannot be restored from the Trash."
                : "Only Homebrew can uninstall this app. You cannot restore it from the Trash.")
                .font(.mcRowTitle)
                .foregroundStyle(Token.textColor(.orange))
            if isBatchReview {
                Text("After Homebrew removes each app, Moppo moves its verified related data to the Trash.")
                    .font(.mcControlLabel)
            }
            Text("If needed, Moppo asks for your login password and never stores it.")
                .font(.mcSubtitle)
        }
        .foregroundStyle(Token.Text.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CopyHomebrewCommandButton: View {
    let package: AppUninstallPlan.ManagedPackage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false
    @State private var copyCount = 0

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(package.uninstallCommand, forType: .string)
            if copied { copyCount += 1 }
        } label: {
            ZStack {
                Text("Copy Command")
                    .opacity(copied ? 0 : 1)
                if copied {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Token.color(.green))
                        .transition(.opacity)
                }
            }
        }
        .buttonStyle(PageActionButtonStyle(size: .small))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: copied)
        .help(package.uninstallCommand)
        .accessibilityLabel(copied ? "Command copied for \(package.name)" : "Copy Homebrew command for \(package.name)")
        .task(id: copyCount) {
            guard copyCount > 0 else { return }
            NSAccessibility.post(
                element: NSApplication.shared, notification: .announcementRequested,
                userInfo: [.announcement: "Command copied for \(package.name)",
                           .priority: NSAccessibilityPriorityLevel.medium.rawValue]
            )
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            copied = false
        }
    }
}

/// Keeps errors, skipped applications, and available recovery actions together.
struct UninstallAttentionList: View {
    let applications: [AppUninstallerModel.SetAsideApplication]
    let title: String
    let review: (URL) -> Void
    var isCentered = false

    var body: some View {
        VStack(alignment: isCentered ? .center : .leading, spacing: 8) {
            Text(title).mcEyebrowStyle()
            GroupedBox {
                VStack(spacing: 0) {
                    ForEach(Array(applications.enumerated()), id: \.offset) { index, application in
                        if index > 0 { Rectangle().fill(Token.Fill.boxBorder).frame(height: Token.hairline) }
                        VStack(alignment: isCentered ? .center : .leading, spacing: 10) {
                            VStack(alignment: isCentered ? .center : .leading, spacing: 4) {
                                Text(application.name)
                                    .font(.mcBody.weight(.semibold))
                                    .foregroundStyle(Token.Text.primary)
                                Text(application.reason)
                                    .font(.mcCaption)
                                    .foregroundStyle(Token.Text.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { actions(application) }
                                VStack(alignment: isCentered ? .center : .leading, spacing: 10) { actions(application) }
                            }
                            if application.managedPackage != nil {
                                Text("Review the application to try again. If removal still fails, run the copied command in Terminal for more details.")
                                    .font(.mcCaption)
                                    .foregroundStyle(Token.Text.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: isCentered ? .center : .leading)
                        .multilineTextAlignment(isCentered ? .center : .leading)
                        .padding(14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ application: AppUninstallerModel.SetAsideApplication) -> some View {
        if let package = application.managedPackage {
            CopyHomebrewCommandButton(package: package)
        }
        if let url = application.applicationURL {
            if application.kind == .failed {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(PageActionButtonStyle())
            }
            Button("Review Application") { review(url) }
                .buttonStyle(PageActionButtonStyle())
                .accessibilityLabel("Review \(application.name)")
        }
    }
}

struct AppUninstallResultView: View {
    let outcome: AppUninstallerModel.BatchUninstallOutcome
    let back: () -> Void
    let review: (URL) -> Void
    let reviewLeftovers: () -> Void
    var viewDashboard: () -> Void = {}

    var body: some View {
        PageCompletionView(title: outcome.title, isSuccess: isSuccess) {
            summary
        } actions: {
            VStack(spacing: 22) {
                let failed = outcome.setAside.filter { $0.kind == .failed }
                let skipped = outcome.setAside.filter { $0.kind == .notAttempted }
                if !failed.isEmpty {
                    UninstallAttentionList(applications: failed, title: "Removal incomplete", review: review, isCentered: true)
                        .frame(maxWidth: 640)
                }
                if !skipped.isEmpty {
                    UninstallAttentionList(applications: skipped, title: "Not attempted", review: review, isCentered: true)
                        .frame(maxWidth: 640)
                }
                PageStateActions {
                    completionActions
                }
            }
        }
    }

    private var isSuccess: Bool {
        outcome.setAside.isEmpty && outcome.survivorCount == 0
    }

    @ViewBuilder
    private var summary: some View {
        if !outcome.uninstalled.isEmpty {
            VStack(spacing: 8) {
                Text(ListFormatter.localizedString(byJoining: outcome.uninstalled))
                if outcome.removedBytes > 0 {
                    Text(outcome.permanentlyRemovedCount > 0
                         ? "Removed \(ByteFormatting.string(outcome.removedBytes))."
                         : "Moved \(ByteFormatting.string(outcome.removedBytes)) to the Trash.")
                }
                if !outcome.homebrewUninstalled.isEmpty {
                    Text("Removed through Homebrew: \(ListFormatter.localizedString(byJoining: outcome.homebrewUninstalled)).")
                    Text("Reinstall the application through Homebrew. Put Back can restore its recorded profiles and settings.")
                }
                if outcome.permanentlyRemovedCount > 0 {
                    Text(outcome.permanentlyRemovedCount == 1
                         ? "One application was permanently deleted. It cannot be restored from the Trash."
                         : "\(outcome.permanentlyRemovedCount) applications were permanently deleted. They cannot be restored from the Trash.")
                }
                if outcome.survivorCount > 0 {
                    Text("Moppo could not move \(outcome.survivorCount) related items to the Trash.")
                        .foregroundStyle(Token.textColor(.orange))
                }
            }
        }
    }

    @ViewBuilder
    private var completionActions: some View {
        Button("Back to Applications", action: back)
            .buttonStyle(PageStateButtonStyle.primary)
        if outcome.survivorCount > 0 || outcome.setAside.contains(where: {
            $0.kind == .failed && $0.applicationURL == nil
        }) {
            Button("Review Leftovers", action: reviewLeftovers)
        }
        if isSuccess {
            Button("View Dashboard", action: viewDashboard)
        }
    }
}
