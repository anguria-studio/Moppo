import AppKit
import SwiftUI

/// Shares iCloud setup between Dashboard and Settings.
struct ICloudSetupView: View {
    let model: DashboardModel
    @State private var access: AccessModel
    @Environment(\.dismiss) private var dismiss

    init(model: DashboardModel, access: AccessModel? = nil) {
        self.model = model
        _access = State(initialValue: access ?? AccessModel())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Show iCloud storage")
                .font(.title2)
                .foregroundStyle(Token.Text.primary)
                .accessibilityAddTraits(.isHeader)
            Text("Moppo uses your existing iCloud account. Full Disk Access lets Moppo read its storage information.")
                .foregroundStyle(Token.Text.secondary)
            GroupedBox {
                VStack(spacing: 0) {
                    PrefRow(title: "Full Disk Access", description: "Moppo requires this access to measure iCloud storage.") {
                        Button(access.disk == .allowed ? "On" : "Enable") {
                            model.beginICloudSetup()
                            Task { await access.performAction(for: .disk) }
                        }
                        .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent), size: .compact))
                        .disabled(access.disk == .allowed || access.requesting != nil)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel("Full Disk Access")
                        .accessibilityValue(access.disk.label)
                        .accessibilityHint("Open Full Disk Access settings")
                    }
                    if model.iCloudState == .unavailable {
                        PrefDivider()
                        PrefRow(
                            title: "iCloud account",
                            description: "Check that you are signed in. For iCloud Drive options, select Drive. Check “Sync this Mac” there."
                        ) {
                            Button("Open Settings", action: ICloudCard.openICloudSettings)
                                .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                                .accessibilityLabel("Open iCloud settings")
                        }
                    }
                }
            }
            Text(feedback)
                .foregroundStyle(Token.Text.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("iCloudSetupFeedback")
            HStack {
                Link("Apple setup guide", destination: URL(string: "https://support.apple.com/en-us/118443")!)
                Spacer()
                Button("Close") {
                    model.finishICloudSetup()
                    dismiss()
                }
                .buttonStyle(PageActionButtonStyle(size: .small))
                .keyboardShortcut(.cancelAction)
            }
        }
        .font(.mcSubtitle)
        .padding(24)
        .frame(width: 560)
        .background(Token.pageBackground)
        .task {
            guard !access.isPreview else { return }
            model.beginICloudSetup()
            await access.refresh()
            guard !Task.isCancelled else { return }
            if model.iCloudState == .idle { await model.loadICloud() }
            if case .available = model.iCloudState { dismiss() }
        }
        .onChange(of: model.iCloudState) { _, state in
            if case .available = state { dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await checkStorage() }
        }
    }

    private var feedback: String {
        switch model.iCloudState {
        case .requiresAccess:
            "Enable Full Disk Access to continue."
        case .unavailable:
            "Moppo could not read iCloud storage. Check your account and connection. Moppo checks storage when you return."
        case .loading:
            "Reading iCloud storage…"
        case .idle, .available:
            "After you enable access, Moppo checks storage automatically."
        }
    }

    private func checkStorage() async {
        guard !access.isPreview else { return }
        await access.refresh()
        guard !Task.isCancelled else { return }
        await model.loadICloud()
    }
}

#Preview("iCloud setup") {
    ICloudSetupView(model: DashboardModel(), access: .preview())
}
