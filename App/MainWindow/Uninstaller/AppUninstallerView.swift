import AppKit
import SwiftUI
import MoppoCore

/// Removes selected applications after checking their related files and ownership.
struct AppUninstallerView: View {
    @Bindable var model: AppUninstallerModel
    var findRequest = 0
    var onViewDashboard: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isDropTargeted = false
    @State private var searchText = ""
    /// By name, which is the order the list arrives in, so the page opens still.
    /// It opened on `largest`: alphabetical while the bundles were measured, then
    /// every card moving at once when the last size came in — a reshuffle nobody
    /// had asked for, on a page the user had only just opened. Sorting by size is
    /// now something the user chooses, and the one move follows their choice.
    ///
    /// There is no "Unsorted" option, though one was asked for: the list has no
    /// order of its own to show — `AppUninstallPlanner.installedApplications` sorts
    /// by name — so the label would sit beside `Name` and mean the same thing.
    @State private var sortOrder: SortOrder = .name

    /// The page's two lists. Leftovers are here as well as in the Scanner because
    /// this is where the question gets asked: whoever came to uninstall an
    /// application is the person who wants to know what the last one left behind.
    /// On the model, not here: the toolbar's remove button has to name what it
    /// would take, and "3 apps" and "2 leftovers" are different sentences.
    private var tab: AppUninstallerModel.UninstallerTab { model.uninstallerTab }
    /// Removed applications whose files are disclosed, by bundle identifier.
    @State private var expandedLeftovers: Set<String> = []

    private enum SortOrder: String, CaseIterable {
        case name = "Name"
        case largest = "Largest"
    }

    var body: some View {
        Group {
            if model.isInterruptingAppUninstall {
                PageProgressView(title: ScanInterruptionView.title, isInterrupting: true)
            } else if model.isPlanningAppUninstall, let url = model.appUninstallPlanningURL {
                planningState(url)
            } else if model.isPlanningAppUninstall {
                busyState
            } else if let outcome = model.batchUninstallOutcome {
                batchDoneState(outcome)
            } else if let outcome = model.appUninstallOutcome {
                doneState(outcome)
            } else if let review = model.batchUninstallReview {
                batchReviewState(review)
            } else if let plan = model.appUninstallPlan {
                resultsState(plan)
            } else {
                emptyState
            }
        }
        .operationResultAnimation(isRunning: model.isPlanningAppUninstall)
        .dropDestination(for: URL.self) { urls, _ in
            guard let application = urls.first(where: {
                $0.pathExtension.lowercased() == "app"
            }) else { return false }
            model.planAppUninstall(application)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: Installed applications

    /// Cards select applications. Each chevron opens an optional file review.
    private var emptyState: some View {
        VStack(spacing: 0) {
            libraryHeader
            HairlineDivider()

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let error = model.appUninstallError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.mcSubtitle)
                                .foregroundStyle(Token.textColor(.orange))
                        }

                        if tab == .leftovers {
                            leftoversList
                        } else if let applications = model.installedApplications {
                            let shown = visibleApplications(applications)
                            if shown.isEmpty {
                                PageState(
                                    title: applications.isEmpty ? "No Applications" : "No Results",
                                    symbol: "xmark.app",
                                    detail: applications.isEmpty
                                        ? "Nothing removable was found in /Applications or ~/Applications."
                                        : "No application matches “\(searchText)”."
                                )
                            } else {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)],
                                    spacing: 10
                                ) {
                                    ForEach(shown) { application in
                                        ApplicationCard(
                                            application: application,
                                            bytes: model.installedApplicationBytes[application.id],
                                            isSelected: model.selectedApplicationIDs
                                                .contains(application.id),
                                            toggle: { model.toggleApplicationSelection(application) },
                                            open: { model.planAppUninstall(application.url) }
                                        )
                                    }
                                }
                                // One move, when the order changes: the measured sort
                                // arriving, a new sort order, a search narrowing.
                                .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: shown.map(\.id))
                            }
                        }
                    }
                    .frame(minHeight: isLibraryEmpty ? geometry.size.height : 0, alignment: .top)
                    .padding(.horizontal, isLibraryEmpty ? 0 : Token.Size.pageGutter)
                    .padding(.vertical, isLibraryEmpty ? 0 : 14)
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                        .strokeBorder(
                            Token.color(.accent),
                            style: StrokeStyle(lineWidth: 2, dash: [9, 7])
                        )
                        .background(
                            Token.color(.accent).opacity(0.07),
                            in: RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
                        )
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear { model.loadInstalledApplications() }
        // Read when the tab is first opened, and again on each return to it: the
        // disk it describes changes whenever something is uninstalled.
        .onChange(of: tab) { _, newTab in
            if newTab == .leftovers { model.loadApplicationLeftovers() }
        }
    }

    private var isLibraryEmpty: Bool {
        if tab == .leftovers {
            return model.applicationLeftovers?.groups.isEmpty == true
        }
        return model.installedApplications.map { visibleApplications($0).isEmpty } ?? false
    }

    // MARK: Leftovers

    private var leftoversSelectionControls: some View {
        let identifiers = Set(model.applicationLeftovers?.groups.map(\.bundleIdentifier) ?? [])
        let selected = identifiers.intersection(model.selectedLeftoverIdentifiers)
        return HStack(spacing: 12) {
            SelectionCheckbox(
                title: "Select All",
                detail: "\(identifiers.count) \(identifiers.count == 1 ? "application" : "applications")",
                state: !identifiers.isEmpty && identifiers.isSubset(of: selected) ? .on : .off,
                isEnabled: !identifiers.isEmpty && !model.isBusyWithDisk && !model.isLoadingApplicationLeftovers
            ) { isOn in
                if isOn { model.selectedLeftoverIdentifiers = identifiers }
                else { model.selectedLeftoverIdentifiers.removeAll() }
            }
            .fixedSize()
            Spacer(minLength: 12)
            Text("\(selected.count) selected · \(ByteFormatting.string(model.selectedLeftoverBytes))")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .animatedTotal(model.selectedLeftoverBytes)
                .fixedSize()
        }
        .padding(.leading, 13)
        .padding(.horizontal, Token.Size.pageGutter)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var leftoversList: some View {
        if let leftovers = model.applicationLeftovers {
            if leftovers.groups.isEmpty {
                PageState(
                    title: "No Leftovers", symbol: "checkmark.circle",
                    detail: "Nothing was found that a removed application left behind."
                )
            } else {
                // Never ticked for the user: whether a removed application's
                // settings matter depends on whether it is coming back.
                GroupedBox(fill: Token.Fill.cardContent) {
                    VStack(spacing: 0) {
                        let groups = leftovers.groups.sorted { $0.totalBytes > $1.totalBytes }
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            if index > 0 { HairlineDivider() }
                            leftoverRow(group)
                            if expandedLeftovers.contains(group.bundleIdentifier) {
                                ForEach(group.items, id: \.id) { item in
                                    HairlineDivider()
                                    itemRow(item).padding(.leading, 28)
                                }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                }
            }
        } else {
            // Bones, not a spinner over an empty page: the list is a few rows.
            GroupedBox {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        if index > 0 { HairlineDivider() }
                        skeletonRow(nameWidth: 180, pathWidth: 120).frame(height: 46)
                    }
                }
            }
        }
    }

    private func leftoverRow(_ group: OrphanedAppLeftoverPlan.Group) -> some View {
        let isSelected = model.selectedLeftoverIdentifiers.contains(group.bundleIdentifier)
        let isExpanded = expandedLeftovers.contains(group.bundleIdentifier)
        let holdsUserData = group.items.contains(where: \.isProtectedUserData)
        return HStack(spacing: 10) {
            Button {
                if isExpanded { expandedLeftovers.remove(group.bundleIdentifier) }
                else { expandedLeftovers.insert(group.bundleIdentifier) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Token.Text.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(group.items.count) files")

            SelectionCheckbox(
                title: "Select \(group.displayName ?? group.bundleIdentifier)",
                state: isSelected ? .on : .off,
                isEnabled: !model.isBusyWithDisk && !model.isLoadingApplicationLeftovers,
                showsTitle: false
            ) { _ in model.toggleLeftoverSelection(group.bundleIdentifier) }
            .fixedSize()

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    // What macOS calls the container when it calls it anything;
                    // otherwise the identifier, which is what is known. The
                    // application is gone, and a name made up from its identifier
                    // would be a guess about something that is not here.
                    Text(group.displayName ?? group.bundleIdentifier)
                        .font(.mcBody)
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if holdsUserData { Badge(text: "includes user data").fixedSize() }
                }
                Text((group.displayName == nil ? "" : "\(group.bundleIdentifier) · ")
                     + "No installed application owner · "
                     + (group.items.count == 1 ? "1 file" : "\(group.items.count) files"))
                    .font(.mcMonoSmall)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
            }

            Spacer()

            Text(ByteFormatting.string(group.totalBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .contentShape(Rectangle())
        .hoverHighlight(restingFill: Token.Fill.groupHeader)
        .onTapGesture {
            guard !model.isBusyWithDisk, !model.isLoadingApplicationLeftovers else { return }
            model.toggleLeftoverSelection(group.bundleIdentifier)
        }
    }

    private var libraryHeader: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                PageSegmentedControl(selection: $model.uninstallerTab, segments:
                    AppUninstallerModel.UninstallerTab.allCases.map { tab in
                        .init(id: tab, title: tab.rawValue,
                              symbol: tab == .installed ? "app" : "archivebox")
                    }
                )
                Spacer()
            }
            .padding(Token.Size.pageGutter)
            if tab == .leftovers {
                leftoversSelectionControls
            } else {
                PageHeader {
                    installedSummaryContent
                } trailing: {
                    installedActions
                }
            }
        }
    }

    @ViewBuilder
    private var installedSummaryContent: some View {
        // A selection takes over the summary's place: the count the user is
        // building matters more than the total they are not acting on.
        if model.selectedApplicationIDs.isEmpty {
            Text(librarySummary)
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)
                .help("Sizes are the application itself. Its related files are found when you open it.")
        } else {
            Text("\(model.selectedApplicationIDs.count) selected")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)
            Button("Deselect All", action: model.clearApplicationSelection)
                .buttonStyle(PageActionButtonStyle(size: .small))
                .fixedSize()
        }
    }

    @ViewBuilder
    private var installedActions: some View {
        Menu {
            Picker("Sort", selection: $sortOrder) {
                ForEach(SortOrder.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 7) {
                Text(sortOrder.rawValue)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
        }
        .menuStyle(.button)
        .buttonStyle(PageActionButtonStyle(size: .small))
        .menuIndicator(.hidden)
        .accessibilityLabel("Sort")
        .accessibilityValue(sortOrder.rawValue)
        .fixedSize()

        // The one thing in this header that may narrow. At a fixed 180 pt it
        // won the space and the button beside it was cut to "Unins…" — a
        // truncated label on the destructive control is the wrong one to lose.
        FindField(text: $searchText, findRequest: findRequest)
            .frame(minWidth: 90, idealWidth: 180, maxWidth: 180)

    }

    /// Tall enough for the header's tallest control, a regular bordered button.
    private static let headerControlHeight: CGFloat = 38

    /// The total appears only once every card has its figure; a sum of the bundles
    /// measured so far would read as the whole and grow under the user's eyes.
    private var librarySummary: String {
        guard let applications = model.installedApplications else { return "Reading applications…" }
        let count = applications.count == 1 ? "1 application" : "\(applications.count) applications"
        let sizes = applications.compactMap { model.installedApplicationBytes[$0.id] }
        guard sizes.count == applications.count else { return "\(count) · measuring…" }
        return "\(count) · \(ByteFormatting.string(sizes.reduce(0, +)))"
    }

    private func visibleApplications(_ applications: [InstalledApplication]) -> [InstalledApplication] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let matching = query.isEmpty ? applications : applications.filter {
            $0.name.localizedCaseInsensitiveContains(query)
        }
        // `Largest` waits for every size. Sorting on partial figures reshuffled
        // the grid once per application measured; chosen early, the cards fill in
        // where they stand and move once, together.
        guard sortOrder == .largest, model.installedApplicationsMeasured else { return matching }
        // An application that could not be measured compares as -1 and keeps its
        // alphabetical place at the end.
        let bytes = model.installedApplicationBytes
        return matching.enumerated().sorted { lhs, rhs in
            let l = bytes[lhs.element.id] ?? -1, r = bytes[rhs.element.id] ?? -1
            return l == r ? lhs.offset < rhs.offset : l > r
        }.map(\.element)
    }

    // MARK: Busy state

    /// Several applications being planned — there is no one header to show. The
    /// uninstall itself is a removal, and removals are shown by
    /// the window-wide `ActivityOverlay`; a second spinner here said the same thing.
    private var busyState: some View {
        PageProgressView(
            title: "Finding related files",
            detail: model.appUninstallPlanningDetail
        )
    }

    // MARK: Planning one application

    /// The review's own frame, at once: the header is known from the bundle the
    /// moment the chevron is pressed, and the close button cancels the planning.
    /// Only what has to be found — sizes and related files — is bone.
    private func planningState(_ url: URL) -> some View {
        var name = url.deletingPathExtension().lastPathComponent
        if name.isEmpty { name = url.lastPathComponent }
        return VStack(spacing: 0) {
            reviewHeader(
                url: url, name: name,
                identifier: Bundle(url: url)?.bundleIdentifier ?? " ",
                identifierIsWarning: false
            ) {
                // The bundle's size is already on the card, so it is shown and named
                // for what it is. The review's figure is a different one — the
                // application plus everything found — and replaces it, with its own
                // caption, when the plan lands.
                VStack(alignment: .trailing, spacing: 2) {
                    if let bytes = model.installedApplicationBytes[url.path] {
                        Text(ByteFormatting.string(bytes))
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    } else {
                        SkeletonBone(width: 64, height: 12).skeletonPulse().frame(height: 18)
                    }
                    Text("Application · finding related files…")
                        .font(.mcCaption)
                        .foregroundStyle(Token.Text.secondary)
                }

                // The review's button, in its place and disabled, so the figures do
                // not slide left by its width when the plan lands. Nothing can be
                // uninstalled before there is a plan, which is what disabled says.
                // An application-only or Homebrew plan carries a longer label and
                // will still shift; the ordinary one does not.
                Button("Uninstall") {}
                    .buttonStyle(PageActionButtonStyle(tint: Token.color(.red), size: .small))
                    .controlSize(.regular)
                    .disabled(true)
                    .fixedSize()
            }
            HairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupedBox { skeletonRow(nameWidth: 130, pathWidth: 250).frame(height: 58) }
                    GroupedBox {
                        VStack(spacing: 0) {
                            ForEach(0..<6, id: \.self) { index in
                                if index > 0 { HairlineDivider() }
                                skeletonRow(
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
    }

    private func skeletonRow(nameWidth: CGFloat, pathWidth: CGFloat) -> some View {
        HStack(spacing: 10) {
            SkeletonBone(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBone(width: nameWidth, height: 10)
                SkeletonBone(width: pathWidth, height: 8)
            }
            Spacer()
            SkeletonBone(width: 54, height: 10)
        }
        .padding(.horizontal, 13)
    }

    // MARK: Results

    private func resultsState(_ plan: AppUninstallPlan) -> some View {
        VStack(spacing: 0) {
            planHeader(plan)
            HairlineDivider()

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

                    GroupedBox(fill: Token.Fill.cardContent) {
                        VStack(spacing: 0) {
                            let groups = groupedItems(plan)
                            ForEach(Array(groups.enumerated()), id: \.element.category) { index, group in
                                if index > 0 { HairlineDivider() }
                                itemSection(group.category, items: group.items)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Token.Radius.box))
                    }
                }
                .padding(.horizontal, Token.Size.pageGutter)
                .padding(.vertical, 14)
            }

        }
    }

    private func planHeader(_ plan: AppUninstallPlan) -> some View {
        reviewHeader(
            url: plan.applicationURL, name: plan.applicationName,
            identifier: plan.bundleIdentifier ?? "Bundle identifier unavailable",
            identifierIsWarning: plan.isApplicationOnly
        ) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormatting.string(plan.totalBytes))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Text(plan.isApplicationOnly
                    ? "Application only"
                    : "\(plan.items.count - 1) related \(plan.items.count == 2 ? "item" : "items")")
                    .font(.mcCaption)
                    .foregroundStyle(Token.Text.secondary)
            }

            if plan.managedPackage != nil {
                Button("Uninstall with Homebrew", action: model.requestAppUninstall)
                .buttonStyle(PageActionButtonStyle(tint: Token.color(.red), size: .small))
                .controlSize(.regular)
                .disabled(model.isBusyWithDisk)
                .fixedSize()
            } else {
                // The size is in the figures beside it, so the label does not
                // repeat it.
                Button(plan.isApplicationOnly ? "Uninstall Application" : "Uninstall",
                       action: model.requestAppUninstall)
                    .buttonStyle(PageActionButtonStyle(tint: Token.color(.red), size: .small))
                    .controlSize(.regular)
                    .disabled(model.isBusyWithDisk)
                    .fixedSize()
            }
        }
    }

    /// One header for the review and for its loading state, so nothing moves when
    /// the plan arrives.
    private func reviewHeader<Figures: View>(
        url: URL, name: String, identifier: String, identifierIsWarning: Bool,
        @ViewBuilder figures: () -> Figures
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

            // The figure and the action keep their width; the name beside them is
            // what truncates when the window is narrow.
            figures().fixedSize()

            Button(action: model.resetAppUninstall) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Token.Text.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to all applications")
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
                CopyHomebrewCommandButton(package: package)
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

            HairlineDivider()

            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index > 0 { HairlineDivider() }
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: AppUninstallPlan.Item) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName)
                        .font(.mcBody)
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.isProtectedUserData {
                        Badge(text: "user data").fixedSize()
                    } else if item.content == .regenerable {
                        Badge(text: "regenerable", style: .safe).fixedSize()
                    } else if item.content == .appComponent {
                        Badge(text: "app component").fixedSize()
                    }
                }

                Text(FileEntry.abbreviate(item.url.path))
                    .font(.mcMonoSmall)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(ByteFormatting.string(item.allocatedBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Token.Text.tertiary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .hoverHighlight()
    }

    // MARK: Done state

    private func doneState(_ outcome: CleanupOutcome) -> some View {
        let applicationName = model.lastUninstalledApplicationName ?? "Application"
        let failed = outcome.failed
        let applicationFailed = model.appUninstallError != nil && outcome.removedCount == 0

        return PageCompletionView(
            title: applicationFailed ? "Could not uninstall \(applicationName)" : "\(applicationName) uninstalled",
            isSuccess: failed.isEmpty && !applicationFailed
        ) {
            VStack(spacing: 12) {
                Text("Moved \(ByteFormatting.string(outcome.removedBytes)) to the Trash.")
                if let error = model.appUninstallError {
                    Text(error)
                        .foregroundStyle(Token.textColor(.orange))
                } else if !failed.isEmpty {
                    Text("\(failed.count) related \(failed.count == 1 ? "item remains" : "items remain") on disk.")
                        .foregroundStyle(Token.textColor(.orange))
                }
            }
        } actions: {
            completionActions
        }
    }

    // MARK: Several applications

    private func batchReviewState(_ review: AppUninstallerModel.BatchUninstallReview) -> some View {
        VStack(spacing: 0) {
            batchReviewHeader(review)
            HairlineDivider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if review.homebrewCount > 0 {
                        GroupedBox {
                            HomebrewRemovalExplanation()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                    }
                    if !review.plans.isEmpty {
                        GroupedBox {
                            VStack(spacing: 0) {
                                ForEach(Array(review.plans.enumerated()), id: \.element.applicationURL) { index, plan in
                                    if index > 0 { HairlineDivider() }
                                    batchPlanRow(plan)
                                }
                            }
                        }
                    }
                    if !review.setAside.isEmpty {
                        setAsideBox(review.setAside, title: "Not attempted")
                    }
                }
                .padding(.horizontal, Token.Size.pageGutter)
                .padding(.vertical, 14)
            }

        }
    }

    private func batchReviewHeader(_ review: AppUninstallerModel.BatchUninstallReview) -> some View {
        HStack(spacing: 10) {
            Text("\(review.plans.count) \(review.plans.count == 1 ? "application" : "applications") to review")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)

            Spacer()

            Button("Back", action: model.resetAppUninstall)
                .buttonStyle(PageActionButtonStyle(size: .small))
                .fixedSize()
            Button("Uninstall Selected",
                   action: model.requestBatchUninstall)
                .buttonStyle(PageActionButtonStyle(tint: Token.color(.red), size: .small))
                .controlSize(.regular)
                .disabled(review.plans.isEmpty || model.isBusyWithDisk)
                .fixedSize()
        }
        .frame(height: Self.headerControlHeight)
        .padding(.horizontal, Token.Size.pageGutter)
        .padding(.vertical, 10)
    }

    private func batchPlanRow(_ plan: AppUninstallPlan) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: plan.applicationURL.path))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(plan.applicationName)
                        .font(.mcBody.weight(.medium))
                        .foregroundStyle(Token.Text.primary)
                        .lineLimit(1)
                    if !plan.protectedItems.isEmpty {
                        Badge(text: "includes user data").fixedSize()
                    }
                }
                Text(plan.managedPackage.map { "Homebrew · \($0.name) · \(plan.items.count - 1) related \(plan.items.count == 2 ? "item" : "items")" } ?? (plan.isApplicationOnly
                    ? "Application only — related files cannot be identified safely"
                    : "Trash · application and \(plan.items.count - 1) related "
                        + (plan.items.count == 2 ? "item" : "items")))
                    .font(.mcCaption)
                    .foregroundStyle(plan.isApplicationOnly
                        ? Token.textColor(.orange) : Token.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Text(ByteFormatting.string(plan.totalBytes))
                .font(.mcRowValue)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
    }

    private func setAsideBox(
        _ applications: [AppUninstallerModel.SetAsideApplication], title: String
    ) -> some View {
        UninstallAttentionList(applications: applications, title: title, review: model.planAppUninstall)
    }

    private func batchDoneState(_ outcome: AppUninstallerModel.BatchUninstallOutcome) -> some View {
        AppUninstallResultView(outcome: outcome) {
            model.resetAppUninstall()
            model.loadInstalledApplications()
        } review: { url in
            model.planAppUninstall(url)
        } reviewLeftovers: {
            model.resetAppUninstall()
            model.uninstallerTab = .leftovers
            model.loadApplicationLeftovers()
        } viewDashboard: {
            model.resetAppUninstall()
            onViewDashboard()
        }
    }

    private var completionActions: some View {
        PageStateActions {
            Button("Continue") {
                model.resetAppUninstall()
                model.loadInstalledApplications()
            }
            .buttonStyle(PageStateButtonStyle(tint: .white, foreground: .black))
            Button("View Dashboard") {
                model.resetAppUninstall()
                onViewDashboard()
            }
            .buttonStyle(PageStateButtonStyle())
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

/// Application icons by path. `NSWorkspace.icon(forFile:)` is synchronous and a
/// card's body runs again whenever any figure lands, so an uncached grid asked for
/// every icon once per application measured.
@MainActor
private enum ApplicationIcons {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for url: URL) -> NSImage {
        if let cached = cache.object(forKey: url.path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(icon, forKey: url.path as NSString)
        return icon
    }
}

/// One installed application. The card toggles its tick; the chevron opens the
/// review. The chevron is a sibling laid over the card, not a button inside the
/// card's label — a button nested in a button's label does not get its own clicks.
private struct ApplicationCard: View {
    let application: InstalledApplication
    let bytes: Int64?
    let isSelected: Bool
    let toggle: () -> Void
    let open: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isChevronHovered = false

    var body: some View {
        Button(action: toggle) {
            VStack(spacing: 6) {
                Image(nsImage: ApplicationIcons.icon(for: application.url))
                    .resizable()
                    .frame(width: 48, height: 48)
                    .padding(.bottom, 2)
                Text(application.name)
                    .font(.mcBody.weight(.medium))
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ZStack {
                    if let bytes {
                        Text(ByteFormatting.string(bytes))
                            .font(.mcCaption)
                            .foregroundStyle(Token.Text.secondary)
                            .transition(.opacity)
                    } else {
                        SkeletonBone(width: 52, height: 9)
                            .skeletonPulse()
                            .transition(.opacity)
                    }
                }
                .frame(height: 14)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: bytes == nil)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, minHeight: 126)
            // Before the box fill: the highlight is a background, and a background
            // added after the fill would sit underneath it and never show.
            .hoverHighlight(radius: Token.Radius.card)
            .background(
                isSelected ? Token.color(.accent).opacity(0.10) : Token.Fill.box, in: shape
            )
            .overlay(shape.strokeBorder(
                isSelected ? Token.color(.accent) : Token.Fill.boxBorder,
                lineWidth: isSelected ? 1.5 : Token.hairline
            ))
            .overlay(alignment: .topLeading) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Token.color(.accent) : Token.Text.disabled)
                    .padding(8)
            }
            .contentShape(shape)
        }
        .buttonStyle(CardPressButtonStyle())
        .accessibilityLabel(bytes.map { "\(application.name), \(ByteFormatting.string($0))" }
            ?? application.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Selects this application for uninstall")
        .overlay(alignment: .topTrailing) {
            Button(action: open) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isChevronHovered ? Token.Text.primary : Token.Text.tertiary)
                    .frame(width: 24, height: 24)
                    .background(
                        isChevronHovered ? Token.Fill.control : .clear,
                        in: RoundedRectangle(cornerRadius: Token.Radius.control)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isChevronHovered = $0 }
            .padding(5)
            .help("Review \(application.name) and its related files")
            .accessibilityLabel("Review \(application.name)")
        }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Token.Radius.card, style: .continuous)
    }
}

/// Local one-pixel rule. The scanner's identically purposed divider is private to
/// its file so the Uninstaller keeps its own tiny spelling rather than widening
/// that implementation detail into an app-wide API.
private struct HairlineDivider: View {
    var body: some View {
        Rectangle().fill(Token.Fill.boxBorder).frame(height: Token.hairline)
    }
}
