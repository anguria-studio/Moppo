import AppKit
import SwiftUI
import MoppoCore

struct HomebrewRemovalExplanation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Moppo Put Back cannot restore applications that Homebrew removes.")
                .foregroundStyle(Token.textColor(.orange))
            Text("Homebrew removes the package. Moppo then moves its verified related data to the Trash, including profiles and settings.")
            Text("If Homebrew needs administrator access, Moppo asks for your login password.")
        }
        .font(.mcCaption)
        .foregroundStyle(Token.Text.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CopyHomebrewCommandButton: View {
    let package: AppUninstallPlan.ManagedPackage
    @State private var copied = false

    var body: some View {
        Button(copied ? "Command Copied" : "Copy Homebrew Command") {
            NSPasteboard.general.clearContents()
            copied = NSPasteboard.general.setString(package.uninstallCommand, forType: .string)
        }
        .buttonStyle(PageActionButtonStyle())
        .help(package.uninstallCommand)
        .accessibilityLabel(copied ? "Command copied for \(package.name)" : "Copy Homebrew command for \(package.name)")
    }
}

/// Keeps errors, skipped applications, and available recovery actions together.
struct UninstallAttentionList: View {
    let applications: [AppModel.SetAsideApplication]
    let title: String
    let review: (URL) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).mcEyebrowStyle()
            GroupedBox {
                VStack(spacing: 0) {
                    ForEach(Array(applications.enumerated()), id: \.offset) { index, application in
                        if index > 0 { Rectangle().fill(Token.Fill.boxBorder).frame(height: Token.hairline) }
                        VStack(alignment: .leading, spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(application.name)
                                    .font(.mcBody.weight(.semibold))
                                    .foregroundStyle(Token.Text.primary)
                                Text(application.reason)
                                    .font(.mcCaption)
                                    .foregroundStyle(Token.Text.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            if let details = application.details, !details.isEmpty {
                                DisclosureGroup("Details") {
                                    Text(details)
                                        .font(.mcMonoSmall)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.mcCaption)
                            }
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) { actions(application) }
                                VStack(alignment: .leading, spacing: 10) { actions(application) }
                            }
                            if application.managedPackage != nil {
                                Text("Review the application to try again. If removal still fails, run the copied command in Terminal for more details.")
                                    .font(.mcCaption)
                                    .foregroundStyle(Token.Text.secondary)
                            }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .padding(14)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func actions(_ application: AppModel.SetAsideApplication) -> some View {
        if let package = application.managedPackage {
            CopyHomebrewCommandButton(package: package)
        }
        if let url = application.applicationURL {
            Button("Review Application") { review(url) }
                .buttonStyle(PageActionButtonStyle())
                .accessibilityLabel("Review \(application.name)")
        }
    }
}

struct AppUninstallResultView: View {
    let outcome: AppModel.BatchUninstallOutcome
    let back: () -> Void
    let review: (URL) -> Void
    let reviewLeftovers: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .center, spacing: 14) {
                    CompletionMark(
                        animate: false,
                        isSuccess: outcome.setAside.isEmpty && outcome.survivorCount == 0,
                        size: 36
                    )
                    .accessibilityHidden(true)
                    Text(outcome.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Token.Text.primary)
                        .accessibilityAddTraits(.isHeader)
                }

                if !outcome.uninstalled.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(ListFormatter.localizedString(byJoining: outcome.uninstalled))
                            .font(.mcBody)
                        if outcome.removedBytes > 0 {
                            Text("Moved \(ByteFormatting.string(outcome.removedBytes)) to the Trash.")
                        }
                        if !outcome.homebrewUninstalled.isEmpty {
                            Text("Removed through Homebrew: \(ListFormatter.localizedString(byJoining: outcome.homebrewUninstalled)).")
                            Text("Moppo Put Back cannot restore applications that Homebrew removes. Related data stays in the Trash.")
                        }
                        if outcome.survivorCount > 0 {
                            Text("Moppo could not move \(outcome.survivorCount) related items to the Trash.")
                                .foregroundStyle(Token.textColor(.orange))
                        }
                    }
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
                }

                let failed = outcome.setAside.filter { $0.kind == .failed }
                let skipped = outcome.setAside.filter { $0.kind == .notAttempted }
                if !failed.isEmpty {
                    UninstallAttentionList(applications: failed, title: "Removal incomplete", review: review)
                }
                if !skipped.isEmpty {
                    UninstallAttentionList(applications: skipped, title: "Not attempted", review: review)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { completionActions }
                    VStack(alignment: .leading, spacing: 10) { completionActions }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 640, alignment: .leading)
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }

    @ViewBuilder
    private var completionActions: some View {
        Button("Back to Applications", action: back)
            .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent)))
        if outcome.survivorCount > 0 || outcome.setAside.contains(where: { $0.kind == .failed && $0.applicationURL == nil }) {
            Button("Review Leftovers", action: reviewLeftovers)
                .buttonStyle(PageActionButtonStyle())
        }
    }
}
