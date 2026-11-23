import SwiftUI
import MoppoCore
import MoppoPlans

struct SavedPlanPresentation: ViewModifier {
    @Bindable var model: SavedPlanModel

    func body(content: Content) -> some View {
        content.background {
            FloatingDialogWindowPresenter(isPresented: model.isPresented, title: String(localized: "Saved cleanup plan"),
                size: NSSize(width: 620, height: 700), minimumSize: NSSize(width: 500, height: 420),
                canClose: model.canClose, onClose: model.cancel) {
                    SavedPlanReviewView(model: model)
                }
        }
    }
}

struct SavedPlanReviewView: View {
    @Bindable var model: SavedPlanModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title2.weight(.semibold))
            if let message = model.otherRequestMessage { Text(message).foregroundStyle(.orange) }
            if model.phase == .loading {
                ProgressView("Checking the saved plan…")
                Text("Moppo checks current exclusions, protection, and file identities before showing the proposal.")
                Spacer()
            } else if model.phase == .failed {
                Text(model.message ?? String(localized: "The plan is unavailable."))
                Spacer()
            } else if model.phase == .permanentConfirmation,
                      model.permanentEntries.indices.contains(model.permanentIndex) {
                Spacer()
                ConfirmationSheet(variant: .cleanUp(itemCount: model.review?.items.count ?? 0,
                    totalBytes: model.review?.scanAllocatedBytes ?? 0, protectedDataCount: 0, saving: nil),
                    toolCommandEntry: model.permanentEntries[model.permanentIndex],
                    toolCommandCount: model.permanentEntries.count,
                    onConfirm: model.confirmPermanentRemoval, onCancel: model.cancel)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                if model.phase == .confirming {
                    Text("Confirm removal of the listed items. Ordinary files move to the Trash. Tool removals need a separate confirmation.")
                        .foregroundStyle(.orange)
                } else if model.phase == .removing || model.phase == .stopping {
                    ProgressView(value: Double(model.completedItems), total: Double(max(1, model.review?.items.count ?? 1)))
                    Text(model.phase == .stopping ? String(localized: "The current item will finish before removal stops.") : String(localized: "Moppo checks each item again before removal."))
                } else if model.phase == .finished {
                    Text("The results are saved for the CLI. Cleanup History contains removal details and available Put Back actions.")
                } else {
                    Text("This proposal is separate from your current Cleanup selection. No removal starts until you confirm it.")
                }
                if let review = model.review {
                    if let bytes = review.scanAllocatedBytes { Text("Scanned allocation: \(ByteFormatting.localizedString(bytes))") }
                    Text("Recoverable space is unverified. Protected items remain excluded.")
                        .font(.callout).foregroundStyle(.secondary)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(Array(zip(review.items, review.entries)), id: \.0.id) { item, entry in
                                VStack(alignment: .leading, spacing: 8) {
                                    SavedPlanEntryRow(entry: entry)
                                    Text(item.localizedReason(for: entry)).font(.callout)
                                    if let detail = detail(for: entry) { Text(detail).font(.callout).foregroundStyle(.secondary) }
                                    if entry.toolCommand != nil {
                                        Label("Permanent removal. Put Back cannot restore these files.", systemImage: "exclamationmark.triangle.fill")
                                            .foregroundStyle(.orange)
                                    } else { Text("Recovery: Trash and available Put Back receipts.").font(.callout) }
                                    if let result = model.outcome?.items.first(where: { $0.itemId == item.id }) {
                                        Text(resultText(result)).font(.callout.weight(.semibold))
                                    }
                                }
                                Divider()
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if model.phase != .permanentConfirmation {
                HStack {
                    Spacer()
                    if model.phase == .removing {
                        Button("Stop After Current Item", action: model.stopRemoval)
                    } else if model.phase != .stopping {
                        Button(model.phase == .finished || model.phase == .failed ? String(localized: "Close") : String(localized: "Cancel"), action: model.cancel)
                            .keyboardShortcut(.cancelAction)
                    }
                    if model.phase == .reviewing {
                        Button("Review Removal…", action: model.acceptProposal).buttonStyle(.borderedProminent)
                    } else if model.phase == .confirming {
                        Button(model.permanentEntries.isEmpty ? String(localized: "Move to Trash") : String(localized: "Continue to Permanent Removal…"), action: model.confirmRemoval)
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Token.chrome)
    }

    private var title: String {
        switch model.phase {
        case .idle, .loading, .reviewing: String(localized: "Review Saved Cleanup Plan")
        case .confirming: String(localized: "Confirm Cleanup")
        case .permanentConfirmation: String(localized: "Confirm Permanent Removal")
        case .removing, .stopping: String(localized: "Removing Plan Items")
        case .finished: String(localized: "Plan Results")
        case .failed: String(localized: "Plan Unavailable")
        }
    }

    private func detail(for entry: FileEntry) -> String? {
        entry.localizedProtectionExplanation ?? entry.toolCommand?.localizedLockReason
            ?? entry.manualRemoval?.localizedExplanation ?? entry.localizedSafetyCaveat
    }

    private func resultText(_ result: PlanOutcome.Item) -> String {
        switch result.status {
        case .trashed: String(localized: "Moved to Trash.")
        case .deleted: String(localized: "Permanently removed.")
        case .partial: String(localized: "Some files were removed. Check Cleanup History for failures.")
        case .unknown: String(localized: "Result unknown. Check Cleanup History.")
        case .failed: String(localized: "Removal failed. Check Cleanup History.")
        case .skipped: String(localized: "Skipped because removal checks failed or no files were removed.")
        case .cancelled: String(localized: "Cancelled before this item started.")
        }
    }
}

private struct SavedPlanEntryRow: View {
    let entry: FileEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.localizedDisplayName).font(.headline)
                Spacer()
                Text(ByteFormatting.localizedString(entry.allocatedBytes)).monospacedDigit()
            }
            Text(entry.url.path).font(.caption.monospaced()).textSelection(.enabled)
            if let owner = entry.inUseBy {
                Text("\(owner.name) is using these files. Removal can interrupt that application.").foregroundStyle(.orange)
            }
            if !entry.children.isEmpty {
                DisclosureGroup("Included files (\(entry.children.count))") {
                    ForEach(entry.children) { child in SavedPlanEntryRow(entry: child).padding(.leading, 12) }
                }
            }
        }
    }
}
