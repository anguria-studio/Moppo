import AppKit
import SwiftUI
import MoppoCore

/// Preferences → Advanced: how removal behaves, the diagnostics, agent setup, and the reset.
struct AdvancedPane: View {

    @Bindable var settings: SettingsStore

    /// Rebuilding walks the disk, so the work belongs to whoever owns the scan
    /// coordinator. With no handler the button is disabled rather than inert — a
    /// control that looks live and does nothing is worse than one that admits it.
    var onRebuildIndex: (() -> Void)?
    /// Removes the dated measurements the Dashboard subtracts. A different file
    /// from the breakdown cache, and a different button.
    var onClearMeasurementHistory: (() -> Void)?
    /// Called after the store has been reset, for state the store does not own
    /// (selections, cached measurements).
    var onResetSettings: (() -> Void)?
    var onLanguageChange: (() -> Void)?
    var isLanguageRestartPending = false

    @State private var isConfirmingReset = false

    private enum Metrics {
        static let resetPaddingH: CGFloat = 14
        static let resetPaddingV: CGFloat = 12
    }

    var body: some View {
        PrefPane {
            removalBehaviour
            PrefSection(String(localized: "Photos and iCloud")) {
                PrefToggleRow(
                    title: String(localized: "Allow photo downloads from iCloud"),
                    description: String(localized: "On by default. Changes apply to new requests; active requests can finish."),
                    isOn: $settings.allowPhotoDownloads
                )
                PhotoAccessGuide().padding()
            }
            diagnostics
            AgentSetupSection()
            resetRow
        }
        .alert("Reset all settings?", isPresented: $isConfirmingReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                guard !isLanguageRestartPending else { return }
                let languageNeedsRestart = settings.resetToDefaults()
                onResetSettings?()
                if languageNeedsRestart { onLanguageChange?() }
            }
        } message: {
            if settings.appLanguage == .system {
                Text("Categories, exclusions and schedules return to their defaults. Nothing on disk is removed.")
            } else {
                Text("Reset restores the default settings and keeps your files. Moppo uses the macOS language setting after a restart.")
            }
        }
    }

    // MARK: - Removal behaviour

    private var removalBehaviour: some View {
        PrefSection(String(localized: "Removal behaviour")) {
            // Tool commands always require separate confirmation.
            PrefToggleRow(
                title: String(localized: "Confirm before every clean-up"),
                description: String(localized: "Tool commands always require confirmation."),
                isOn: $settings.confirmBeforeCleanup
            )
            PrefDivider()
            PrefToggleRow(
                title: String(localized: "Keep Put Back receipts"),
                description: String(localized: "Save original locations to restore items from the Trash within Moppo. Without receipts, Moppo cannot put back newly removed items. Tool command results always enter Cleanup History.", comment: "Put Back receipts store original paths so Moppo can move items back from the Trash."),
                isOn: $settings.keepReceipt
            )
            // "Follow symlinks while measuring" used to live here. It was removed
            // rather than repaired: following a link counts its target a second
            // time, under a name that does not own those bytes. That breaks the
            // capacity card's one contract — every byte of the disk accounted for
            // exactly once — and with it on, a 228 GB disk measured 274 GB, the
            // Unmeasured residual floored to zero and the bar ran off the card.
            // Scans must not follow links either (removing a link frees the link,
            // not its target), so the option had no correct consumer left. The
            // measurer still supports it as a primitive for anything that one day
            // genuinely wants "how big is this tree, links included".
        }
    }

    // MARK: - Diagnostics

    private var diagnostics: some View {
        PrefSection(String(localized: "Diagnostics")) {
            PrefRow(
                title: String(localized: "Keep a removal log"),
                description: RemovalLog.displayPath,
                descriptionIsPath: true
            ) {
                Button("Reveal in Finder") { RemovalLog.reveal() }
                    .buttonStyle(SecondaryButtonStyle(fill: Token.Fill.buttonOnCard))
            }
            PrefDivider()
            PrefRow(
                title: String(localized: "Rebuild the size index"),
                // The design's "Last built 16 Aug at 9:41 AM · 1.2M paths" needs a
                // timestamp nothing records yet; this says what the button does
                // instead of inventing the line.
                description: String(localized: "Discards the cached measurements and measures every folder again.")
            ) {
                Button("Rebuild") { onRebuildIndex?() }
                    .buttonStyle(SecondaryButtonStyle(fill: Token.Fill.buttonOnCard))
                    .disabled(onRebuildIndex == nil)
            }
            PrefDivider()
            PrefRow(
                title: String(localized: "Clear measurement history"),
                // Says what goes and what the cost is. The Dashboard's growth card
                // has nothing to subtract until two measurements exist again.
                description: String(localized: "Removes the stored measurements that the Dashboard compares. The next two measurements start a new history.")
            ) {
                Button("Clear") { onClearMeasurementHistory?() }
                    .buttonStyle(SecondaryButtonStyle(fill: Token.Fill.buttonOnCard))
                    .disabled(onClearMeasurementHistory == nil)
            }
        }
    }

    // MARK: - Reset

    /// Standalone and red: it belongs to no section because it undoes all of them.
    private var resetRow: some View {
        HStack(spacing: PrefMetrics.controlGap) {
            PrefLabel(
                title: String(localized: "Reset all settings"),
                description: String(localized: "Categories, exclusions and schedules return to defaults.")
            )

            Spacer(minLength: PrefMetrics.controlGap)

            Button("Reset") {
                settings.reloadAppLanguage()
                isConfirmingReset = true
            }
            .buttonStyle(DestructiveButtonStyle())
            .disabled(isLanguageRestartPending)
        }
        .padding(.horizontal, Metrics.resetPaddingH)
        .padding(.vertical, Metrics.resetPaddingV)
        .background(
            Token.color(.red).opacity(0.09),
            in: RoundedRectangle(cornerRadius: Token.Radius.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.well)
                .strokeBorder(Token.color(.red).opacity(0.30), lineWidth: Token.hairline)
        )
    }
}

// MARK: - Removal log

/// Where the removal log lives, and how to show it.
enum RemovalLog {

    static var url: URL {
        MoppoCore.RemovalLog().logFileURL
    }

    /// Tilde-abbreviated, as the design prints it.
    static var displayPath: String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }

    /// Selects the log in Finder, or the deepest folder on its way there.
    ///
    /// Nothing creates the file until the first removal, and
    /// `activateFileViewerSelecting` on a path that does not exist does nothing at all
    /// — a button that appears dead until the app has deleted something once.
    @MainActor
    static func reveal() {
        let fileManager = FileManager.default
        var target = url
        while !fileManager.fileExists(atPath: target.path(percentEncoded: false)),
              target.pathComponents.count > 1 {
            target = target.deletingLastPathComponent()
        }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

// MARK: - Preview

#Preview("Advanced") {
    AdvancedPane(
        settings: .preview(),
        onRebuildIndex: {},
        onClearMeasurementHistory: {},
        onResetSettings: {}
    )
    .background(Color(nsColor: .windowBackgroundColor))
    .preferredColorScheme(.dark)
}
