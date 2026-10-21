import SwiftUI
import MoppoCore

/// Cleanup totals and iCloud usage share one row.
struct StatTiles: View {

    private let safeToRemoveBytes: Int64?
    private let totalBytes: Int64?
    private let lastScanAt: Date?
    private let iCloudState: DashboardModel.ICloudState?
    private let onICloudSetup: () -> Void
    private let onICloudRetry: () -> Void
    private let onICloudHide: () -> Void
    /// Tap targets for the two counting tiles. A first-run placeholder stays inert.
    /// A saved scan time gives both tiles a fresh-scan action.
    private let onSafeTap: (() -> Void)?
    private let onAllTap: (() -> Void)?
    /// Starts a fresh scan when only a saved timestamp remains.
    private let onScan: (() -> Void)?

    /// `nil` results means no scan has run this session: the two counting tiles fall
    /// back to placeholders. A saved scan time enables the Scan Again action.
    init(
        results: ScanResults?,
        lastScanAt: Date? = nil,
        iCloudState: DashboardModel.ICloudState? = nil,
        onICloudSetup: @escaping () -> Void = {},
        onICloudRetry: @escaping () -> Void = {},
        onICloudHide: @escaping () -> Void = {},
        onSafeTap: (() -> Void)? = nil,
        onAllTap: (() -> Void)? = nil,
        onScan: (() -> Void)? = nil
    ) {
        self.safeToRemoveBytes = results?.safeToRemoveBytes
        self.totalBytes = results?.totalBytes
        self.lastScanAt = results?.finishedAt ?? lastScanAt
        self.iCloudState = iCloudState
        self.onICloudSetup = onICloudSetup
        self.onICloudRetry = onICloudRetry
        self.onICloudHide = onICloudHide
        self.onSafeTap = onSafeTap
        self.onAllTap = onAllTap
        self.onScan = onScan
    }

    /// Supplies totals for previews.
    init(
        safeToRemoveBytes: Int64?,
        totalBytes: Int64?,
        lastScanAt: Date?
    ) {
        self.safeToRemoveBytes = safeToRemoveBytes
        self.totalBytes = totalBytes
        self.lastScanAt = lastScanAt
        self.iCloudState = nil
        self.onICloudSetup = {}
        self.onICloudRetry = {}
        self.onICloudHide = {}
        self.onSafeTap = nil
        self.onAllTap = nil
        self.onScan = nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Token.Size.pageGutter) {
            Grid(alignment: .topLeading, horizontalSpacing: Token.Size.pageGutter, verticalSpacing: 0) {
                GridRow {
                    linkedTile(
                        label: "Safe to Remove",
                        value: safeToRemoveBytes.map { ByteFormatting.string($0) },
                        emptyValue: savedScanNeedsRefresh ? "Scan Again" : nil,
                        action: onSafeTap,
                        emptyAction: savedScanNeedsRefresh ? onScan : nil
                    )
                    linkedTile(
                        label: "All",
                        value: totalBytes.map { ByteFormatting.string($0) },
                        emptyValue: savedScanNeedsRefresh ? "Scan Again" : nil,
                        action: onAllTap,
                        emptyAction: savedScanNeedsRefresh ? onScan : nil
                    )
                    if let iCloudState {
                        ICloudDashboardCard(
                            state: iCloudState, onSetup: onICloudSetup,
                            onRetry: onICloudRetry, onHide: onICloudHide
                        )
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A timestamp is safe to keep. File removal candidates are not safe to keep
    /// across a relaunch because files can change or move.
    private var savedScanNeedsRefresh: Bool {
        safeToRemoveBytes == nil && totalBytes == nil && lastScanAt != nil
    }

    @ViewBuilder
    private func linkedTile(
        label: String,
        value: String?,
        emptyValue: String?,
        action: (() -> Void)?,
        emptyAction: (() -> Void)?
    ) -> some View {
        if let activeAction = value != nil ? action : emptyAction {
            Button(action: activeAction) {
                StatTile(
                    label: label,
                    value: value,
                    emptyValue: emptyValue,
                    showsChevron: true
                )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(value == nil ? "Run a new scan" : "Show these items")
        } else {
            StatTile(
                label: label,
                value: value,
                emptyValue: emptyValue
            )
        }
    }

}

// MARK: - One tile

private struct StatTile: View {
    let label: String
    /// `nil` before the first scan. Use an em dash in the disabled tone. "0 B"
    /// would incorrectly claim that a scan found no files.
    let value: String?
    /// Used in place of the em dash where the empty state has a word for itself.
    var emptyValue: String?
    /// Set on a tile that opens a list, so the affordance is visible before hover.
    var showsChevron: Bool = false

    private var isPlaceholder: Bool { value == nil }

    var body: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    Text(label)
                        .font(.mcSectionHeader)
                        .foregroundStyle(Token.Text.secondary)
                    if showsChevron {
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Token.Text.quaternary)
                    }
                }

                Text(value ?? emptyValue ?? "—")
                    .animatedTotal(value)
                    .font(.mcStatValue)
                    // A bare placeholder is disabled. A named empty value is an
                    // instruction, and it stays readable as the tile's action.
                    .foregroundStyle(
                        isPlaceholder && emptyValue == nil
                            ? Token.Text.quaternary
                            : Token.Text.primary
                    )
                    .lineLimit(1)
                    // A narrow window must not truncate the figure to "5.6…".
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel(value ?? emptyValue ?? "Not measured yet")
                    .padding(.top, 4)
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 16)
            // Flexible in both axes: the grid has already sized the cell to the widest
            // column and the tallest tile, and this fills it so the box matches.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Stat tiles — scanned and pre-scan") {
    VStack(spacing: 24) {
        StatTiles(
            safeToRemoveBytes: 6_023_000_000,
            totalBytes: 72_735_000_000,
            lastScanAt: Calendar.current.date(byAdding: .day, value: -2, to: .now)
        )
        StatTiles(results: nil)
        StatTiles(
            results: nil,
            lastScanAt: Calendar.current.date(byAdding: .minute, value: -20, to: .now),
            onScan: {}
        )
    }
    .padding(24)
    .frame(width: Token.Size.windowWidth - Token.Size.sidebarWidth)
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
