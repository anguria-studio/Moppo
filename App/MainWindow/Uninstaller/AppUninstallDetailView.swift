import AppKit
import SwiftUI
import MoppoCore

/// Shows the existing application review inside the centered dialog.
struct AppUninstallDetailView: View {
    @Bindable var model: AppUninstallerModel
    var activity: AppModel.Activity? = nil

    private var plan: AppUninstallPlan? {
        model.isPlanningAppUninstall ? nil : model.appUninstallPlan
    }

    var body: some View {
        VStack(spacing: 0) {
            if let url = model.appUninstallReviewURL ?? model.appUninstallPlan?.applicationURL {
                reviewHeader(
                    url: url,
                    name: plan?.applicationName ?? url.deletingPathExtension().lastPathComponent,
                    identifier: plan?.bundleIdentifier ?? Bundle(url: url)?.bundleIdentifier
                        ?? "Bundle identifier unavailable",
                    identifierIsWarning: plan?.isApplicationOnly ?? false
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            UninstallerDivider()

            Group {
                if let activity {
                    PageProgressView(title: activity.title, detail: activity.detail, icon: activity.progressIcon)
                        // Keep progress readable and scrollable while removal disables the controls.
                        .environment(\.isEnabled, true)
                } else if model.isPlanningAppUninstall {
                    planningContent
                } else if let plan {
                    resultsContent(plan)
                } else {
                    PageState(
                        title: "Could Not Find Related Files",
                        symbol: "exclamationmark.triangle",
                        detail: model.appUninstallError ?? "Review the application again."
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transaction { $0.animation = nil }

            UninstallerDivider()
            footer
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Token.pageBackground)
        .ignoresSafeArea()
        .modifier(KeyboardFocusVisibility())
        .sheet(item: $model.pendingSoundLibraryRemoval) { review in
            ConfirmationSheet(
                variant: .soundLibrary(
                    totalBytes: review.items.reduce(0) { $0 + $1.allocatedBytes }
                ),
                onConfirm: { Task { await model.confirmSoundLibraryRemoval() } },
                onCancel: { model.pendingSoundLibraryRemoval = nil }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("Application details")
    }

    /// Keeps the header and footer visible while related files load.
    private var planningContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupedBox { UninstallerSkeletonRow(nameWidth: 130, pathWidth: 250).frame(height: 58) }
                GroupedBox {
                    VStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { index in
                            if index > 0 { UninstallerDivider() }
                            UninstallerSkeletonRow(
                                nameWidth: [150, 110, 170, 95, 140, 120][index],
                                pathWidth: [280, 240, 310, 220, 260, 300][index]
                            )
                            .frame(height: 42)
                        }
                    }
                }
            }
            .skeletonPulse()
            .padding(.horizontal, Token.Size.pageGutter)
            .padding(.vertical, 14)
        }
        .scrollDisabled(true)
        .accessibilityLabel("Finding related files")
    }

    private var footer: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if let plan {
                    Text(ByteFormatting.string(plan.totalBytes))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text(plan.isApplicationOnly
                        ? "Application only"
                        : "\(plan.items.count - 1) related \(plan.items.count == 2 ? "item" : "items")")
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                } else {
                    Text(model.isPlanningAppUninstall ? "Finding related files…" : "Review could not finish")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                }
            }
            Spacer(minLength: 8)
            if let plan {
                if !plan.soundLibraryItems.isEmpty {
                    Button("Move Sounds to Trash") {
                        let paths = model.selectedSoundLibraryIDs
                        Task { await model.requestSoundLibraryRemoval(plan, itemPaths: paths) }
                    }
                    .buttonStyle(PageActionButtonStyle(size: .small))
                    .disabled(model.isBusyWithDisk || model.selectedSoundLibraryIDs.isEmpty)
                }
                if let package = plan.managedPackage {
                    CopyHomebrewCommandButton(package: package)
                        .disabled(model.isBusyWithDisk)
                }
                Button(
                    plan.managedPackage != nil ? "Uninstall with Homebrew"
                        : plan.isApplicationOnly ? "Uninstall Application" : "Uninstall",
                    action: model.requestAppUninstall
                )
                .buttonStyle(PageActionButtonStyle(tint: Token.color(.red), size: .small))
                .disabled(model.isBusyWithDisk)
            } else if model.isPlanningAppUninstall {
                Button("Uninstall") {}
                    .buttonStyle(PageActionButtonStyle(tint: Token.color(.red), size: .small))
                    .disabled(true)
            } else if let url = model.appUninstallReviewURL {
                Button("Try Again") { model.planAppUninstall(url) }
                    .buttonStyle(PageActionButtonStyle(size: .small))
                    .disabled(model.isBusyWithDisk)
            }
        }
        .controlSize(.regular)
        .frame(minHeight: 36)
        .padding(16)
        .background(Token.pageBackground)
    }

    private func resultsContent(_ plan: AppUninstallPlan) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = model.appUninstallError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.textColor(.orange))
                }

                if let package = plan.managedPackage {
                    managedPackageCard(package)
                }

                if plan.managedPackage == nil, let package = plan.installerPackage {
                    installerPackageCard(package)
                }

                completeUninstallCard(plan)

                if !plan.soundLibraryItems.isEmpty { soundLibraryCard(plan) }
                if plan.soundLibraryUnreadableCount > 0 {
                    Label("Some sound content could not be read. Check access, then review the application again.",
                          systemImage: "exclamationmark.triangle")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.textColor(.orange))
                }

                if !plan.preservedPaths.isEmpty {
                    Label {
                        Text(
                            "\(plan.preservedPaths.count) excluded, protected, or shared "
                            + (plan.preservedPaths.count == 1 ? "path will" : "paths will")
                            + " stay on disk."
                        )
                    } icon: {
                        Image(systemName: "shield.lefthalf.filled")
                    }
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.textColor(.orange))
                    .help(plan.preservedPaths.map(\.path).joined(separator: "\n"))
                }

                ForEach(groupedItems(plan), id: \.category) { group in
                    GroupedBox(fill: Token.Fill.cardContent) {
                        itemSection(group.category, items: group.items)
                            .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                    }
                }
            }
            .padding(.horizontal, Token.Size.pageGutter)
            .padding(.vertical, 14)
        }
    }

    private func soundLibraryCard(_ plan: AppUninstallPlan) -> some View {
        GroupedBox {
            VStack(alignment: .leading, spacing: 12) {
                Text("Downloaded Sound Content").font(.mcBody.weight(.medium))
                Text("Complete uninstall keeps this content. Sound removal keeps your application and projects. Projects may need another sound download.")
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
                ForEach(plan.soundLibraryItems) { item in
                    HStack(spacing: 10) {
                        SelectionCheckbox(
                            title: "Select \(item.displayName)",
                            state: model.selectedSoundLibraryIDs.contains(item.id) ? .on : .off,
                            isEnabled: !model.isBusyWithDisk, showsTitle: false
                        ) { isOn in
                            if isOn { model.selectedSoundLibraryIDs.insert(item.id) }
                            else { model.selectedSoundLibraryIDs.remove(item.id) }
                        }
                        .fixedSize()
                        Text(item.displayName)
                            .font(.mcBody)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(ByteFormatting.string(item.allocatedBytes))
                            .font(.mcRowValue)
                            .fixedSize()
                    }
                }
            }
            .padding(14)
        }
    }

    /// Uses the same header during planning and review.
    private func reviewHeader(
        url: URL, name: String, identifier: String, identifierIsWarning: Bool
    ) -> some View {
        HStack(spacing: 13) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(identifier)
                    .font(.mcMonoSmall)
                    .foregroundStyle(identifierIsWarning
                        ? Token.textColor(.orange) : Token.Text.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: model.resetAppUninstall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Token.Text.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(model.isUninstallingApp)
            .accessibilityLabel("Close application details")
            .help("Close application details (Escape)")
        }
        .padding(16)
    }

    private func completeUninstallCard(_ plan: AppUninstallPlan) -> some View {
        GroupedBox {
            HStack(spacing: 12) {
                Image(systemName: plan.isApplicationOnly
                    ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(plan.isApplicationOnly
                        ? Token.textColor(.orange) : Token.color(.green))

                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.isApplicationOnly
                        ? "Application-only uninstall" : "Complete uninstall")
                        .font(.mcBody.weight(.medium))
                        .foregroundStyle(Token.Text.primary)
                    Text(
                        plan.isApplicationOnly
                            ? "Moppo cannot identify related files safely. Removal includes only the application."
                            : plan.protectedItems.isEmpty
                            ? "Every verified related file below will move to the Trash."
                            : "Every verified related file below will move to the Trash, including profiles and settings."
                    )
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                }

                Spacer()
            }
            .padding(12)
        }
    }

    /// An application a `.pkg` put in place is often a part of what that installer
    /// wrote — Python's leaves 468 MB of framework behind IDLE. Information, not a
    /// gate, so it is drawn in the ordinary tone and not the Homebrew card's orange.
    /// The words are Core's, where they are tested.
    private func installerPackageCard(
        _ package: InstallerReceipts.Package
    ) -> some View {
        GroupedBox {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "shippingbox")
                    .font(.system(size: 17))
                    .foregroundStyle(Token.Text.secondary)

                VStack(alignment: .leading, spacing: 3) {
                    Text(package.reviewTitle)
                        .font(.mcBody.weight(.medium))
                        .foregroundStyle(Token.Text.primary)
                    Text(package.reviewDetail)
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
        }
    }

    private func managedPackageCard(
        _ package: AppUninstallPlan.ManagedPackage
    ) -> some View {
        GroupedBox {
            VStack(alignment: .leading, spacing: 10) {
                Label("Homebrew package: \(package.name)", systemImage: "shippingbox")
                    .font(.mcBody.weight(.medium))
                HomebrewRemovalExplanation()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }

    private struct ItemGroup {
        let category: AppUninstallPlan.Item.Category
        let items: [AppUninstallPlan.Item]
    }

    private func groupedItems(_ plan: AppUninstallPlan) -> [ItemGroup] {
        AppUninstallPlan.Item.Category.allCases.compactMap { category in
            let items = plan.items.filter { $0.category == category }
            return items.isEmpty ? nil : ItemGroup(category: category, items: items)
        }
    }

    private func itemSection(
        _ category: AppUninstallPlan.Item.Category,
        items: [AppUninstallPlan.Item]
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(categoryTitle(category))
                    .mcEyebrowStyle()
                Spacer()
                Text(ByteFormatting.string(items.reduce(0) { $0 + $1.allocatedBytes }))
                    .font(.mcMonoSmall)
                    .foregroundStyle(Token.Text.tertiary)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(Token.Fill.groupHeader, in: Rectangle())

            UninstallerDivider()

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { UninstallerDivider() }
                UninstallerItemRow(item: item)
            }
        }
    }

    // MARK: Helpers

    private func categoryTitle(_ category: AppUninstallPlan.Item.Category) -> String {
        switch category {
        case .application: "Application"
        case .support: "Application Support"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers & Scripts"
        case .logs: "Logs"
        case .state: "Saved State"
        case .helpers: "Helpers & Launch Items"
        }
    }
}
