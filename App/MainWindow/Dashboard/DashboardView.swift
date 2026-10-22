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
                if let volume = model.volume, model.showsSpaceWarning(warnBelowGB: warnBelowGB) {
                    lowSpaceBanner(volume)
                }

                if let notice = model.trashNotice {
                    trashBanner(notice)
                }

                if let volume = model.volume, model.isDashboardLoading {
                    // The totals are already known — `diskutil` answers before the
                    // category walk even starts — so only the parts the walk
                    // produces go to bones. The previous breakdown supplies the
                    // category names, which are stable; its figures are withheld:
                    // stale numbers under a pulse read as current.
                    CapacityCard(volume: volume, breakdown: model.breakdown, isMeasuring: true, warnBelowGB: warnBelowGB)
                } else if model.isDashboardLoading {
                    // Not even the totals yet: the moment before `diskutil` returns.
                    CapacityCardSkeleton()
                } else if let volume = model.volume, let breakdown = model.breakdown {
                    CapacityCard(volume: volume, breakdown: breakdown, warnBelowGB: warnBelowGB)
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
                        latestMeasurement: model.latestStorageMeasurement.map {
                            GrowthCard.Measurement(date: $0.measuredAt, usedBytes: $0.usedBytes)
                        },
                        lastScanAt: scanResults?.finishedAt ?? lastScanAt,
                        canCompareSinceCleanup: model.hasCleanupGrowthBaseline,
                        cleanupMeasurementState: model.cleanupMeasurementState,
                        cleanupBaselineDate: model.cleanupBaselineDate,
                        hasCleanupComparison: model.hasCleanupComparison,
                        sevenDayStart: model.sevenDayStart,
                        isRefreshing: model.isLoadingBreakdown,
                        onRefresh: { Task { await model.measureStorage() } },
                        onOpenDiskAccess: { Task { await access?.performAction(for: .disk) } },
                        onSelectBaseline: { model.growthBaseline = $0 },
                        onReveal: { onRevealGrowth($0) }
                    )
                }

                if !model.removableSnapshots.isEmpty {
                    SnapshotsDisclosureRow(
                        snapshots: model.snapshots,
                        isExpanded: $model.snapshotsExpanded
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

    private var warnBelowGB: Int { settings?.warnBelowGB ?? SettingsStore.Defaults.warnBelowGB }
    private var safeBytes: Int64 { scanResults?.safeToRemoveBytes ?? 0 }

    private func lowSpaceBanner(_ volume: VolumeInfo) -> some View {
        let critical = DashboardSpaceState(freeBytes: volume.freeBytes, warnBelowGB: warnBelowGB) == .critical
        let detail: String
        if critical {
            detail = "Only \(ByteFormatting.string(volume.freeBytes)) left. Apps may fail to save. "
                + (safeBytes > 0 ? "Clean safe items, then review large items." : "Review large items to make space.")
        } else {
            detail = "Below your \(warnBelowGB) GB threshold. "
                + (safeBytes > 0
                   ? "\(ByteFormatting.string(safeBytes)) is safe to move to Trash."
                   : "Review large items to make space.")
        }
        return statusBanner(
            title: critical ? "Almost out of space" : "Running low on space",
            detail: detail,
            symbol: "exclamationmark.triangle",
            color: critical ? .red : .orange,
            dismiss: critical ? nil : {
                model.dismissLowSpaceWarning()
            }
        )
    }

    private func trashBanner(_ notice: DashboardModel.TrashNotice) -> some View {
        statusBanner(
            title: notice.bytes.map { "Moved \(ByteFormatting.string($0)) to Trash" }
                ?? "Moved \(notice.count) \(notice.count == 1 ? "item" : "items") to Trash",
            detail: "Emptying the Trash permanently deletes its contents and can recover space.",
            symbol: "checkmark",
            color: .green,
            dismiss: { model.dismissTrashNotice(notice.id) }
        )
        .task(id: notice.id) {
            do { try await Task.sleep(for: .seconds(8)) }
            catch { return }
            model.dismissTrashNotice(notice.id)
        }
    }

    private func statusBanner(
        title: String, detail: String, symbol: String, color: ColorToken,
        dismiss: (() -> Void)?
    ) -> some View {
        NoticeBanner(title: title, dismiss: dismiss) {
            Image(systemName: symbol)
                .font(.mcControlLabel)
                .foregroundStyle(Token.textColor(color))
                .frame(width: 30, height: 30)
                .background(
                    color == .orange ? Token.Fill.warning : (color == .green ? Token.Fill.safeBadge : Token.color(.red).opacity(0.15)),
                    in: RoundedRectangle(cornerRadius: Token.Radius.control)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.mcControlLabel)
                    .fontWeight(.semibold)
                    .foregroundStyle(Token.Text.primary)
                Text(detail)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
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
