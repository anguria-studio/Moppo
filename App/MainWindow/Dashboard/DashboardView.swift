import SwiftUI
import MoppoCore

/// The Dashboard.
///
/// A plain `ScrollView` inside the split view's detail column, which means its
/// content passes under the unified toolbar and blurs against it live. The handoff
/// is emphatic that this is the point — "do not pin content below the toolbar" — so
/// there is no manual top inset here; the platform provides it.
struct DashboardView: View {
    @Bindable var model: DashboardModel
    var scanResults: ScanResults?
    var lastScanAt: Date?
    var onShowScanner: (CleanupModel.ScanFilter) -> Void = { _ in }
    var onScan: () -> Void = {}
    var onRevealGrowth: (GrowthAttribution) -> Void = { _ in }
    /// Optional so previews and the Scanner's empty state need not supply one.
    var settings: SettingsStore?
    var access: AccessModel?
    @State private var showsICloudSetup = false

    var body: some View {
        ScrollView {
            VStack(spacing: Token.Size.pageGutter) {
                if let volume = model.volume, model.isDashboardLoading {
                    // The totals are already known — `diskutil` answers before the
                    // category walk even starts — so only the parts the walk
                    // produces go to bones. The previous breakdown supplies the
                    // category names, which are stable; its figures are withheld:
                    // stale numbers under a pulse read as current.
                    CapacityCard(volume: volume, breakdown: model.breakdown, isMeasuring: true)
                } else if model.isDashboardLoading {
                    // Not even the totals yet: the moment before `diskutil` returns.
                    CapacityCardSkeleton()
                } else if let volume = model.volume, let breakdown = model.breakdown {
                    CapacityCard(volume: volume, breakdown: breakdown)
                } else {
                    unmeasuredPlaceholder
                }

                StatTiles(
                    results: scanResults,
                    lastScanAt: lastScanAt,
                    iCloudState: model.showsICloudOnDashboard ? model.iCloudState : nil,
                    onICloudSetup: { showsICloudSetup = true },
                    onICloudRetry: { Task { await model.loadICloud() } },
                    onICloudHide: { settings?.showICloudOnDashboard = false },
                    // The tiles are a summary of the scan; the scan's own page is
                    // where its rows live, so a tile opens the Scanner on the list
                    // it counted rather than a page of its own.
                    onSafeTap: { onShowScanner(.safeToRemove) },
                    onAllTap: { onShowScanner(.all) },
                    onScan: { onScan() }
                )

                if let growth = model.growth {
                    GrowthCard(
                        presentation: GrowthCard.Presentation(growth),
                        baseline: model.growthBaseline,
                        hasMeasurement: model.latestStorageMeasurement != nil,
                        lastScanAt: scanResults?.finishedAt ?? lastScanAt,
                        baselineOptions: model.growthBaselineOptions,
                        sevenDayStart: model.sevenDayStart,
                        onSelectBaseline: { model.growthBaseline = $0 },
                        onReveal: { onRevealGrowth($0) }
                    )
                }

                if !model.removableSnapshots.isEmpty {
                    TimeMachineSnapshotsCard(
                        snapshots: model.removableSnapshots,
                        purgeableBytes: model.purgeableBytes,
                        isExpanded: $model.snapshotsExpanded,
                        onDelete: { try await model.deleteTimeMachineSnapshots() }
                    )
                }
            }
            // Breathing room wins over exact alignment with the toolbar's own inset:
            // at 5pt the cards aligned with the chevron capsule but sat almost
            // against the sidebar. The Scan button is inset to match this figure, so
            // the trailing edges still line up; the leading chevron group cannot be
            // moved (see MainWindow) and is left slightly proud.
            .padding(Token.Size.pageGutter)
        }
        .task(id: settings?.iCloudPlan) {
            model.iCloudPlanBytes = settings?.iCloudPlan.bytes
            await model.loadICloud()
            guard !Task.isCancelled else { return }
            if model.shouldResumeICloudSetup { showsICloudSetup = true }
        }
        .onChange(of: model.showsICloudOnDashboard) { _, _ in
            Task { await model.loadICloud() }
        }
        .sheet(isPresented: $showsICloudSetup) {
            ICloudSetupView(model: model, access: access)
        }
    }

    /// Keeps the Dashboard ready for a manual measurement when no saved figures exist.
    private var unmeasuredPlaceholder: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(spacing: 10) {
                Image(systemName: "externaldrive")
                    .foregroundStyle(Token.Text.secondary)
                Text("Storage has not been measured")
                    .font(.mcControlLabel)
                    .foregroundStyle(Token.Text.secondary)
                Text("Use Refresh Dashboard to measure storage.")
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }
}
