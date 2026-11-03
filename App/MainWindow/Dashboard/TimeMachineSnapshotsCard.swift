import SwiftUI
import AppKit
import MoppoCore

/// The Dashboard's Time Machine snapshots card.
///
/// Time Machine keeps local snapshots on the startup disk while the backup disk is
/// away. macOS deletes them when it needs space. The card tells the user what they
/// are, shows the space that macOS can free, and lets the user delete them sooner.
///
/// The card never adds snapshots to Safe to Remove. A local snapshot can be the only
/// recent backup, so deletion always asks for confirmation first.
///
/// macOS boots from a sealed snapshot of the System volume. That snapshot is macOS
/// itself, so the card does not list it. A help popover tells why.
struct TimeMachineSnapshotsCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Snapshots other than the boot snapshot, newest Time Machine snapshot first.
    private let snapshots: [SnapshotInfo]
    private let purgeableBytes: Int64?
    @Binding private var isExpanded: Bool
    private let onDelete: () async throws -> Void

    @State private var isShowingHelp = false
    @State private var isConfirmingDelete = false
    @State private var isDeleting = false
    @State private var deleteFailure: String?

    init(
        snapshots: [SnapshotInfo],
        purgeableBytes: Int64?,
        isExpanded: Binding<Bool>,
        onDelete: @escaping () async throws -> Void = {}
    ) {
        self.snapshots = snapshots
            .filter { !$0.isBootSnapshot }
            .sorted { ($0.timeMachineDate ?? .distantPast) > ($1.timeMachineDate ?? .distantPast) }
        self.purgeableBytes = purgeableBytes
        self._isExpanded = isExpanded
        self.onDelete = onDelete
    }

    private var timeMachineCount: Int { snapshots.filter { $0.timeMachineStamp != nil }.count }

    var body: some View {
        GroupedBox(radius: Token.Radius.card) {
            VStack(alignment: .leading, spacing: 0) {
                header
                divider.padding(.top, 16)
                if isExpanded { rows.padding(.top, 8) }
                footer.padding(.top, isExpanded ? 8 : 12)
            }
            .padding(.vertical, 22)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .alert(confirmationTitle, isPresented: $isConfirmingDelete) {
            Button("Delete Snapshots", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If you did not connect your backup disk recently, these snapshots can be your only recent backup. "
                 + "You cannot undo this action. macOS also deletes them automatically when it needs space.")
        }
        .alert(
            "Moppo could not delete all snapshots",
            isPresented: Binding(get: { deleteFailure != nil }, set: { if !$0 { deleteFailure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteFailure ?? "")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Time Machine snapshots")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Token.Text.primary)
                Text(Self.summary(snapshots, now: .now))
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let purgeableBytes {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ByteFormatting.string(purgeableBytes))
                        .font(.mcSecondaryHero)
                        .foregroundStyle(Token.Text.emphasis)
                        .lineLimit(1)
                    Text("Purgeable · estimate")
                        .font(.mcSubtitle)
                        .foregroundStyle(Token.Text.tertiary)
                }
                .fixedSize()
                .help("macOS can free this space when it needs it. The estimate includes these snapshots and some system caches.")
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// "1 local snapshot from today at 15:00. macOS deletes it when it needs space."
    static func summary(_ snapshots: [SnapshotInfo], now: Date) -> String {
        let dates = snapshots.compactMap(\.timeMachineDate).sorted()
        let others = snapshots.count - dates.count
        var parts: [String] = []
        switch dates.count {
        case 0: break
        case 1: parts.append("1 local snapshot from \(when(dates[0], now: now)).")
        default: parts.append("\(dates.count) local snapshots. The oldest is from \(when(dates[0], now: now)).")
        }
        if others > 0 {
            parts.append(others == 1 ? "1 snapshot from another app." : "\(others) snapshots from other apps.")
        }
        if !dates.isEmpty {
            parts.append("macOS deletes \(dates.count == 1 ? "it" : "them") when it needs space.")
        }
        return parts.joined(separator: " ")
    }

    private static func when(_ date: Date, now: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "yesterday at \(time)" }
        return "\(date.formatted(.dateTime.day().month(.abbreviated))) at \(time)"
    }

    // MARK: - Snapshot rows

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(snapshots) { snapshot in
                HStack(spacing: 8) {
                    CategoryDot(color: snapshot.timeMachineDate == nil ? .gray : .green, size: 8)
                    if let date = snapshot.timeMachineDate {
                        Text(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                            .font(.mcRowTitle)
                            .foregroundStyle(Token.Text.primary)
                    } else {
                        Text("Snapshot from another app")
                            .font(.mcRowTitle)
                            .foregroundStyle(Token.Text.primary)
                        Text("Moppo does not delete it")
                            .font(.mcSubtitle)
                            .foregroundStyle(Token.Text.tertiary)
                    }
                    Spacer(minLength: 12)
                    if let date = snapshot.timeMachineDate {
                        // The relative time changes each minute.
                        TimelineView(.periodic(from: .now, by: 60)) { _ in
                            Text(date.formatted(.relative(presentation: .named, unitsStyle: .wide)))
                                .font(.mcRowValue)
                                .foregroundStyle(Token.Text.secondary)
                        }
                    }
                }
                .frame(minHeight: 34)
                .padding(.horizontal, 6)
                .help(snapshot.name)
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Text(isExpanded ? "Hide snapshots" : "Show snapshots")
                }
                .font(.mcControlLabel)
                .foregroundStyle(Token.Text.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            HelpButton(label: "About the boot snapshot") { isShowingHelp.toggle() }
                .popover(isPresented: $isShowingHelp) {
                    bootSnapshotHelp.presentationBackground(Token.chrome)
                }

            Spacer(minLength: 12)

            if timeMachineCount > 0 {
                Button(isDeleting ? "Deleting…" : "Delete Snapshots…") { isConfirmingDelete = true }
                    .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                    .disabled(isDeleting)
                    .fixedSize()
            }
        }
    }

    private var confirmationTitle: String {
        timeMachineCount == 1
            ? "Delete 1 Time Machine snapshot?"
            : "Delete \(timeMachineCount) Time Machine snapshots?"
    }

    private func delete() {
        isDeleting = true
        Task {
            defer { isDeleting = false }
            do { try await onDelete() } catch { deleteFailure = error.localizedDescription }
        }
    }

    private var bootSnapshotHelp: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Why the boot snapshot is not here")
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)

            Text("macOS starts from a sealed, read-only snapshot of the System volume. "
                 + "Its name starts with com.apple.os.update-, but it is not an update leftover. "
                 + "It is the copy of macOS that runs now.")

            Text("You cannot delete it from Recovery Mode or with System Integrity Protection off. "
                 + "Deleting it would free no space, so Moppo does not show it.")
        }
        .font(.mcSubtitle)
        .foregroundStyle(Token.Text.secondary)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Token.Fill.boxBorder)
            .frame(height: Token.hairline)
    }
}

// MARK: - Help button

/// SwiftUI has no help-button style on macOS 26, so this is the AppKit control itself
/// — the round `?` from every system dialog. A hand-drawn circle would read as a
/// mystery glyph sitting next to native chrome.
private struct HelpButton: NSViewRepresentable {
    let label: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .helpButton
        button.title = ""
        button.controlSize = .small
        button.target = context.coordinator
        button.action = #selector(Coordinator.fire)
        button.setAccessibilityLabel(label)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) { self.action = action }

        @objc func fire() { action() }
    }
}

// MARK: - Preview

#Preview("Time Machine snapshots") {
    @Previewable @State var collapsed = false
    @Previewable @State var expanded = true

    let snapshots = ["2026-08-17-131500", "2026-08-16-094100"].map {
        SnapshotInfo(uuid: $0, name: "com.apple.TimeMachine.\($0).local", purgeable: true,
                     limitingContainerShrink: false, isBootSnapshot: false, volumeDisk: "disk3s5")
    }

    VStack(spacing: 16) {
        TimeMachineSnapshotsCard(snapshots: Array(snapshots.prefix(1)), purgeableBytes: 3_400_000_000, isExpanded: $collapsed)
        TimeMachineSnapshotsCard(snapshots: snapshots, purgeableBytes: 3_400_000_000, isExpanded: $expanded)
    }
    .padding(24)
    .frame(width: 940)
    .background(Color(nsColor: .windowBackgroundColor))
}
