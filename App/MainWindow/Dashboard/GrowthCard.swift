import SwiftUI
import MoppoCore

/// Shows dated storage comparisons and cleanup measurement guidance.
struct GrowthCard: View {

    /// Everything the card draws.
    ///
    /// Deliberately not ``GrowthComparison`` itself. A report carries the two stored
    /// measurements, and a measurement cannot be built outside `MoppoCore` —
    /// `VolumeInfo` has no public initializer — so a preview would have nothing to
    /// show. The card needs the figures, not the snapshots they came from.
    enum Presentation: Equatable {
        case report(Report)
        case insufficientHistory
        case notComparable
    }

    struct Report: Equatable {
        /// The real date of the measurement compared against, whichever baseline was
        /// asked for. "7 days" is a request; this is what was found.
        let baselineDate: Date
        let usedDeltaBytes: Int64
        let classDeltas: [GrowthClass: Int64]
        let attributions: [GrowthAttribution]
    }

    let presentation: Presentation
    let baseline: GrowthBaseline
    var lastScanAt: Date? = nil
    var canCompareSinceCleanup = true
    var cleanupMeasurementState: DashboardModel.CleanupMeasurementState = .none
    var cleanupBaselineDate: Date? = nil
    var hasLaterCleanupMeasurement = false
    var isRefreshing = false
    var onRefresh: () -> Void = {}
    var onOpenDiskAccess: () -> Void = {}
    var onSelectBaseline: (GrowthBaseline) -> Void = { _ in }
    var onReveal: (GrowthAttribution) -> Void = { _ in }

    /// How many places the card names.
    ///
    /// Core reports up to eight. Five is what fits under the capacity card without
    /// turning a summary into a table, and the sixth largest change on this Mac was
    /// always small enough to be noise.
    private static let maximumRows = 5

    var body: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(alignment: .leading, spacing: 0) {
                header
                content
                cleanupGuidance
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Storage changes")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Token.Text.primary)
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(lastScanLabel(at: context.date))
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.tertiary)
                        .help(lastScanAt.map(Self.stamp) ?? "Run a scan to find cleanup items.")
                }
            }
            Spacer(minLength: 8)
            baselineMenu
            if case .report(let report) = presentation {
                Text(ByteFormatting.signedString(report.usedDeltaBytes))
                    .font(.mcSecondaryHero)
                    .monospacedDigit()
                    .foregroundStyle(Token.Text.emphasis)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .help("Used space change since \(Self.stamp(report.baselineDate))")
                    .accessibilityLabel("Used space change")
                    .accessibilityValue("\(ByteFormatting.signedString(report.usedDeltaBytes)) since \(Self.stamp(report.baselineDate))")
            }
        }
    }

    private func lastScanLabel(at now: Date) -> String {
        guard let lastScanAt else { return "No scan yet" }
        guard now.timeIntervalSince(lastScanAt) >= 60 else { return "Last scan · Just now" }
        return "Last scan · \(growthScanFormatter.localizedString(for: lastScanAt, relativeTo: now))"
    }

    private var baselineMenu: some View {
        Menu {
            ForEach([GrowthBaseline.lastCleanup, .sevenDays], id: \.self) { choice in
                Button(choice.displayName) { onSelectBaseline(choice) }
                    .disabled(choice == .lastCleanup && !canCompareSinceCleanup)
            }
        } label: {
            HStack(spacing: 5) {
                Text(baseline.displayName)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
        }
        .menuStyle(.button)
        .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
        // The label already carries a chevron, drawn at the size the design's
        // controls use rather than the one AppKit picks.
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a comparison period")
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        switch presentation {
        case .report(let report):
            reportBody(report)
        case .insufficientHistory:
            message("No storage comparison yet.", hint: "Storage changes need two measurements with the same access and settings.")
        case .notComparable:
            message("These measurements cannot be compared.", hint: "Storage changes need measurements with the same access and settings.")
        }
    }

    @ViewBuilder
    private var cleanupGuidance: some View {
        if let guidance = cleanupGuidanceText {
            VStack(alignment: .leading, spacing: 8) {
                Text(guidance)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if cleanupMeasurementState == .requiresAccess {
                    Button("Open Full Disk Access", action: onOpenDiskAccess)
                        .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                } else if cleanupMeasurementState == .failed || cleanupMeasurementState == .interrupted {
                    Button("Refresh Storage", action: onRefresh)
                        .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                        .disabled(isRefreshing)
                        .accessibilityHint("Update current storage. This does not create a cleanup baseline.")
                }
                if let cleanupBaselineDate, cleanupMeasurementState != .none {
                    Text("The available cleanup comparison starts at \(Self.stamp(cleanupBaselineDate)).")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.secondary)
                }
            }
            .padding(.top, 12)
            .accessibilityElement(children: .contain)
        }
    }

    private var cleanupGuidanceText: String? {
        switch cleanupMeasurementState {
        case .measuring:
            "Measuring storage after cleanup."
        case .requiresAccess:
            "The latest cleanup has no storage measurement. Enable Full Disk Access before the next cleanup to save its comparison baseline."
        case .failed:
            "The storage measurement after cleanup failed. Refresh updates current storage. The next cleanup will try to save a new comparison baseline."
        case .interrupted:
            "The storage measurement after cleanup stopped. Refresh updates current storage. The next cleanup will try to save a new comparison baseline."
        case .cleared:
            "Storage history was cleared. The next cleanup starts a new cleanup comparison."
        case .none:
            if cleanupBaselineDate == nil {
                "Since last cleanup needs a storage measurement immediately after removal. No cleanup baseline is available."
            } else if baseline == .lastCleanup && !hasLaterCleanupMeasurement {
                "Cleanup baseline saved. Changes appear after the next storage measurement."
            } else {
                nil
            }
        }
    }

    private func message(_ primary: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(primary)
                .font(.mcRowTitleRegular)
                .foregroundStyle(Token.Text.primary)
            Text(hint)
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.tertiary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func reportBody(_ report: Report) -> some View {
        let rows = Array(report.attributions.prefix(Self.maximumRows))
        let scale = max(1, rows.map { abs(Double($0.deltaBytes)) }.max() ?? 1)

        if rows.isEmpty {
            Text("No folder changed by enough to name.")
                .font(.mcSubtitle)
                .foregroundStyle(Token.Text.tertiary)
                .padding(.top, 14)
        } else {
            divider
                .padding(.top, 16)

            VStack(spacing: 0) {
                ForEach(rows) { attribution in
                    AttributionRow(
                        attribution: attribution,
                        scale: scale,
                        onReveal: onReveal
                    )
                }
            }
            .padding(.top, 8)
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Token.Fill.boxBorder)
            .frame(height: Token.hairline)
    }

    /// "Tue 26 Aug, 09:12", in the user's locale.
    ///
    /// Named to the minute. The report subtracts two dated measurements, and the
    /// user must be able to tell which two.
    private static func stamp(_ date: Date) -> String {
        date.formatted(
            .dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        )
    }
}

// MARK: - Reading a comparison

extension GrowthCard.Presentation {

    /// Reads a stored comparison into the figures the card draws.
    init(_ comparison: GrowthComparison) {
        switch comparison {
        case .report(let report):
            self = .report(GrowthCard.Report(
                baselineDate: report.baseline.measuredAt,
                usedDeltaBytes: report.usedDeltaBytes,
                classDeltas: report.classDeltas,
                attributions: Self.oneRowPerEvent(report.attributions)
            ))
        case .notComparable:
            self = .notComparable
        case .insufficientHistory:
            self = .insufficientHistory
        }
    }

    /// One move is one event.
    ///
    /// Core reports a move twice, and correctly: the folder left one path and
    /// arrived at another, so both paths changed. On the card that reads as a loss
    /// and an unrelated gain of the same size. The arriving row already names where
    /// the folder came from, so it tells the whole story on its own and the
    /// departing row is dropped.
    ///
    /// Only when its partner is on the list. If the arrival fell outside the places
    /// Core reported, the departure is the only record of the event and it stays.
    static func oneRowPerEvent(_ attributions: [GrowthAttribution]) -> [GrowthAttribution] {
        let arrivals = Set(attributions.compactMap { attribution -> String? in
            guard case .movedIn = attribution.kind else { return nil }
            return attribution.path
        })
        return attributions.filter { attribution in
            guard case .movedOut(let destination) = attribution.kind else { return true }
            return !arrivals.contains(destination)
        }
    }
}

// MARK: - One place that changed

private struct AttributionRow: View {
    let attribution: GrowthAttribution
    let scale: Double
    let onReveal: (GrowthAttribution) -> Void

    var body: some View {
        if attribution.isRevealable {
            Button { onReveal(attribution) } label: { line }
                .buttonStyle(.plain)
                .hoverHighlight(radius: Token.Radius.row)
                .help("Open this folder in the Storage Explorer")
        } else {
            line
        }
    }

    private var line: some View {
        HStack(spacing: 8) {
            CategoryDot(color: attribution.segment.color, size: 8)

            HStack(spacing: 8) {
                Text(attribution.segment.displayName)
                    .font(.mcRowTitle)
                    .foregroundStyle(Token.Text.primary)
                    .fixedSize()
                Text(FileEntry.abbreviate(attribution.path))
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let badge = Self.badge(for: attribution.kind) {
                    Badge(text: badge.text)
                        .lineLimit(1)
                        .help(badge.detail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GrowthChangeBar(deltaBytes: attribution.deltaBytes, scale: scale, tint: Token.color(attribution.segment.color))
                .frame(width: 104, height: 34)
                .padding(.horizontal, 12)

            Text(ByteFormatting.signedString(attribution.deltaBytes))
                .font(.mcRowValue)
                .foregroundStyle(attribution.deltaBytes < 0 ? Token.textColor(.green) : Token.Text.secondary)
                .frame(width: 90, alignment: .trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minHeight: 34)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// A change that is not simply more or less. `grew` and `shrank` carry no badge:
    /// the signed figure beside them already says which one it is.
    private static func badge(
        for kind: GrowthAttribution.Kind
    ) -> (text: String, detail: String)? {
        switch kind {
        case .grew, .shrank:
            nil
        case .appeared:
            ("New", "This folder was not there at the earlier measurement.")
        case .disappeared:
            ("Gone", "This folder was there at the earlier measurement.")
        case .movedIn(let from):
            ("Moved from \(placeName(from))",
             "This folder was at \(FileEntry.abbreviate(from)).")
        case .movedOut(let to):
            ("Moved to \(placeName(to))",
             "This folder is now at \(FileEntry.abbreviate(to)).")
        }
    }

    /// Where a move came from or went to, named by the folder that held it.
    ///
    /// The full path goes in the tooltip. A badge carrying
    /// `~/Documents/Projects/Renewals/build` would be wider than the row it labels.
    private static func placeName(_ path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == NSHomeDirectory() { return "Home" }
        let name = (parent as NSString).lastPathComponent
        return name.isEmpty ? FileEntry.abbreviate(parent) : name
    }
}

/// Changes extend left or right from a shared zero line.
private struct GrowthChangeBar: View {
    let deltaBytes: Int64
    let scale: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let center = size.width / 2
            let width = min(1, abs(Double(deltaBytes)) / max(1, scale)) * center
            let bar = CGRect(
                x: deltaBytes < 0 ? center - width : center,
                y: size.height / 2 - 3.5,
                width: width,
                height: 7
            )
            let shape = UnevenRoundedRectangle(
                topLeadingRadius: deltaBytes < 0 ? 3.5 : 0,
                bottomLeadingRadius: deltaBytes < 0 ? 3.5 : 0,
                bottomTrailingRadius: deltaBytes > 0 ? 3.5 : 0,
                topTrailingRadius: deltaBytes > 0 ? 3.5 : 0
            )
            context.fill(shape.path(in: bar), with: .color(deltaBytes < 0 ? Token.color(.green) : tint))
            var zero = Path()
            zero.move(to: CGPoint(x: center, y: 0))
            zero.addLine(to: CGPoint(x: center, y: size.height))
            context.stroke(zero, with: .color(Token.Fill.controlBorder), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

@MainActor private let growthScanFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.dateTimeStyle = .named
    return formatter
}()

// MARK: - Previews

#Preview("What grew — report") {
    let gb: (Double) -> Int64 = { Int64($0 * Double(ByteFormatting.bytesPerGB)) }
    let home = NSHomeDirectory()

    GrowthCard(
        presentation: .report(GrowthCard.Report(
            baselineDate: Date(timeIntervalSinceNow: -7 * 24 * 60 * 60),
            usedDeltaBytes: gb(13.4),
            classDeltas: [
                .user: gb(11.2),
                .appDataAndCaches: gb(2.1),
                .macOS: gb(0.4),
                .applications: 0,
                .unmeasured: gb(-0.3)
            ],
            attributions: [
                GrowthAttribution(
                    path: home + "/Documents/Renewals/build",
                    segment: .documentsDesktop,
                    deltaBytes: gb(11.0),
                    kind: .grew
                ),
                GrowthAttribution(
                    path: home + "/Library/Caches/Homebrew",
                    segment: .packageBuildCaches,
                    deltaBytes: gb(1.6),
                    kind: .appeared
                ),
                GrowthAttribution(
                    path: home + "/Movies/Archive",
                    segment: .movies,
                    deltaBytes: gb(0.9),
                    kind: .movedIn(from: home + "/Desktop/Archive")
                )
            ]
        )),
        baseline: .sevenDays
    )
    .padding(24)
    .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth)
    .background(Token.pageBackground)
    .preferredColorScheme(.dark)
}

#Preview("What grew — collecting history") {
    GrowthCard(presentation: .insufficientHistory, baseline: .sevenDays)
    .padding(24)
    .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth)
    .background(Token.pageBackground)
    .preferredColorScheme(.dark)
}
