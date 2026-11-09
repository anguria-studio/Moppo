import SwiftUI
import MoppoCore

/// Shows cached readings and native controls without starting work when the panel opens.
struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            storage
                .padding(.horizontal, 10)
                .padding(.top, 8)

            Divider().padding(.vertical, 8).padding(.horizontal, 8)

            readings
                .padding(.horizontal, 10)

            cleanupControl
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 8)

            if let status = model.menuBar.status, !model.isBusyWithDisk {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.isFailure ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.updatesFrequently)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            } else if model.isShowingWelcome {
                Text("Open Moppo and complete the welcome guide.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            Divider().padding(.horizontal, 8).padding(.bottom, 4)

            VStack(spacing: 2) {
                Button {
                    presentWindow { MainWindowPresenter.present { openWindow(id: "main") } }
                } label: {
                    commandLabel("Open Moppo")
                }
                Button {
                    presentWindow {
                        AppDelegate.setPolicy(.regular)
                        NSApp.activate(ignoringOtherApps: true)
                        openSettings()
                    }
                } label: {
                    commandLabel("Settings", shortcut: "⌘,")
                }
                .keyboardShortcut(",")
                Button {
                    NSApp.terminate(nil)
                } label: {
                    commandLabel("Quit Moppo", shortcut: "⌘Q")
                }
                .keyboardShortcut("q")
            }
            .buttonStyle(MenuItemButtonStyle())
        }
        .font(.body)
        .padding(6)
        .frame(width: 288)
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    if let volume = model.dashboard.volume {
                        Text("\(ByteFormatting.string(volume.freeBytes)) free")
                            .fontWeight(.medium)
                            .monospacedDigit()
                        Text("\(volume.name) · \(ByteFormatting.string(volume.capacityBytes))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Disk space unavailable")
                        Text("Reload to read disk space.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Button {
                    model.menuBar.refresh(in: model)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reload readings and scan for Cleanup items")
                .help("Refresh disk space, Trash, and the Cleanup scan.")
                .disabled(!model.menuBar.canStart(in: model))
            }
            if let volume = model.dashboard.volume {
                ProgressView(value: Double(volume.usedBytes), total: Double(max(volume.capacityBytes, 1)))
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Disk space")
                    .accessibilityValue("\(ByteFormatting.string(volume.freeBytes)) free of \(ByteFormatting.string(volume.capacityBytes))")
            }
        }
    }

    private var readings: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Safe to Remove")
                    if let results = model.cleanup.scanResults {
                        Text("Last scan result · \(results.finishedAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
                            .help(results.finishedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No scan result. Reload to scan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(model.cleanup.scanResults.map { ByteFormatting.string($0.safeToRemoveBytes) } ?? "—")
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trash")
                    if let error = model.recovery.trashReadError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let summary = model.recovery.trashSummary {
                        HStack(spacing: 3) {
                            Text("\(summary.itemCount) \(summary.itemCount == 1 ? "item" : "items")")
                            if let date = model.recovery.trashMeasuredAt {
                                Text("· \(date, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
                                    .help(date.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    } else {
                        Text(model.recovery.isLoadingTrash ? "Measuring…" : "Reload to measure Trash.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Text(model.recovery.trashSummary.map { ByteFormatting.string($0.totalBytes) } ?? "—")
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var cleanupControl: some View {
        if model.isBusyWithDisk || model.menuBar.isRefreshing {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if !model.cleanup.isScanning {
                        ProgressView().controlSize(.small)
                    }
                    Text(operationTitle)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if model.operations.canCancel {
                        Button("Stop") { model.operations.cancel() }
                            .disabled(model.cleanup.isInterruptingScan || model.cleanup.isInterruptingRemoval)
                    }
                }
                if model.cleanup.isScanning {
                    ProgressView(value: Double(model.cleanup.scanProgress), total: 100)
                        .progressViewStyle(.linear)
                    Text(model.cleanup.scanProgressDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Button {
                model.menuBar.deleteSafeToRemove(in: model)
            } label: {
                Text("Delete Safe to Remove")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!model.menuBar.canStart(in: model))
        }
    }

    private var operationTitle: String {
        if model.cleanup.isInterruptingScan || model.cleanup.isInterruptingRemoval { return "Stopping…" }
        if model.cleanup.isScanning { return "Scanning…" }
        if let activity = model.activity { return activity.title }
        return model.menuBar.isRefreshing ? "Refreshing readings…" : "Moppo is busy."
    }

    private func commandLabel(_ title: String, shortcut: String? = nil) -> some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut {
                Text(shortcut).foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    private func presentWindow(_ action: @escaping @MainActor () -> Void) {
        NSApp.keyWindow?.orderOut(nil)
        DispatchQueue.main.async(execute: action)
    }
}

/// Uses the system appearance for the menu bar symbol.
struct MenuBarLabel: View {
    var body: some View {
        Image(.menuBarIcon).renderingMode(.template)
    }
}
