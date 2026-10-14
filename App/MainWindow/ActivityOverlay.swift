import SwiftUI
import MoppoCore

/// Keeps one opaque surface between removal progress and its result.
struct RemovalOperationSurface: View {
    @Bindable var model: AppModel
    var fadesOnDismiss = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsActivity: Bool {
        model.activity != nil && !(model.view == .scanner && model.isCleaningUp)
    }

    private var isPresented: Bool {
        showsActivity || model.photoDuplicates.isDeleting || model.removalCompletion?.destination == model.view
    }

    private var cancelApplicationQuit: (() -> Void)? {
        guard model.cleanup.isWaitingForApplications else { return nil }
        return { model.cleanup.cancelApplicationQuit() }
    }

    var body: some View {
        Group {
            if isPresented {
                ZStack {
                    Token.pageBackground
                    if showsActivity, let activity = model.activity {
                        ActivityOverlay(
                            activity: activity,
                            onCancel: cancelApplicationQuit,
                            isCancelling: model.cleanup.isInterruptingApplicationQuit
                        )
                            // Keep operation controls active above the disabled page.
                            .environment(\.isEnabled, true)
                            .transition(.opacity)
                    } else if model.photoDuplicates.isDeleting {
                        PageProgressView(title: "Deleting photos", detail: "Waiting for Photos to finish.")
                            .transition(.opacity)
                    } else if let completion = model.removalCompletion, completion.destination == model.view {
                        RemovalCompletionView(
                            title: completion.title,
                            detail: completion.detail,
                            isSuccess: completion.isSuccess,
                            showsActions: !completion.dismissesAutomatically,
                            canContinue: !model.isBusyWithDisk && !model.uninstaller.isLoadingApplicationLeftovers,
                            onContinue: model.dismissRemovalCompletion,
                            onViewDashboard: { model.view = .dashboard },
                            onShowInFinder: completion.finderURLs.isEmpty ? nil : {
                                NSWorkspace.shared.activateFileViewerSelecting(completion.finderURLs)
                            }
                        )
                        .id(completion.id)
                        .task(id: completion.id) {
                            await model.automaticallyDismissRemovalCompletion(completion.id)
                        }
                        .transition(.opacity)
                    }
                }
                .contentShape(Rectangle())
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.removalCompletion?.id)
                .transition(fadesOnDismiss
                    ? .asymmetric(insertion: .identity, removal: .opacity)
                    : .identity)
            }
        }
        .animation(fadesOnDismiss && !reduceMotion ? .easeOut(duration: 0.24) : nil, value: isPresented)
    }
}

/// Blocks page input while a removal operation runs.
struct ActivityOverlay: View {
    let activity: AppModel.Activity
    var onCancel: (() -> Void)? = nil
    var isCancelling = false

    var body: some View {
        ZStack {
            Token.pageBackground
            PageProgressView(
                title: activity.title, detail: activity.detail, icon: activity.progressIcon,
                onCancel: onCancel, isCancelling: isCancelling
            )
        }
        // The colour fill is what catches the clicks. Without a content shape the
        // ZStack would let a click on the transparent card margins fall through.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel(activity.title)
    }
}

#Preview("Cleaning up") {
    ZStack {
        Token.pageBackground
        ActivityOverlay(activity: .cleaningUp(itemCount: 12, totalBytes: 3_400_000_000))
    }
    .frame(width: 760, height: 480)
    .preferredColorScheme(.dark)
}

#Preview("Emptying the Trash") {
    ZStack {
        Token.pageBackground
        ActivityOverlay(activity: .emptyingTrash(itemCount: 214, totalBytes: 9_040_000_000))
    }
    .frame(width: 760, height: 480)
}

extension AppModel.Activity {
    /// Moppo appears for deletions and for waits that can take a while.
    /// Restoring an item and uninstalling one app are usually short, so they keep the hourglass.
    var progressIcon: PageProgressView.Icon {
        switch self {
        case .cleaningUp(_, let bytes),
             .emptyingTrash(_, let bytes),
             .removingDuplicateFiles(_, let bytes),
             .removingStorageItems(_, let bytes):
            return .deletion(bytes: bytes)
        case .reviewingStorageItems, .waitingForApplicationsToQuit:
            return .mascot(.search)
        case .restoringTrashItem, .uninstalling:
            return .hourglass
        }
    }
}
