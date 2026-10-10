import Combine
import SwiftUI
import MoppoCore

/// Shows startup, scan, alert, and iCloud settings.
struct GeneralPane: View {

    @Bindable var settings: SettingsStore

    var body: some View {
        PrefPane {
            startup
            scanning
            iCloud
        }

    }

    // MARK: - Startup

    private var startup: some View {
        PrefSection("Startup") {
            PrefToggleRow(title: "Open at login", isOn: $settings.launchAtLogin)
            PrefDivider()
            PrefToggleRow(
                title: "Show in menu bar",
                description: "Live free-space readout and a one-click cache purge.",
                isOn: $settings.showInMenuBar
            )
        }
    }

    // MARK: - Scanning

    private var scanning: some View {
        PrefSection("Scanning") {
            PrefPickerRow(
                title: "Scan automatically",
                selection: $settings.scanSchedule,
                label: \.displayName
            )
            PrefDivider()
            PrefToggleRow(title: "Only when plugged in and idle", isOn: $settings.idleOnly)
            PrefDivider()
            PrefToggleRow(title: "Low-space alerts", isOn: $settings.lowSpaceAlertsEnabled)
            PrefDivider()
            PrefRow(
                title: "Warn me below",
                description: "Notify when free space drops under the threshold."
            ) {
                warnBelowControl
            }
        }
    }

    private var warnBelowControl: some View {
        HStack(spacing: 10) {
            Slider(
                value: warnBelowBinding,
                in: Double(SettingsStore.warnBelowRange.lowerBound)
                    ... Double(SettingsStore.warnBelowRange.upperBound),
                step: 5
            )
            .frame(width: 112)
            .accessibilityLabel("Warn me below")
            .accessibilityValue("\(settings.warnBelowGB) gigabytes")

            Text("\(settings.warnBelowGB) GB")
                .font(.mcControlLabel.monospacedDigit())
                .foregroundStyle(Token.Text.primary)
                // Fixed width so the slider does not shift sideways as the readout
                // crosses from one digit to two.
                .frame(width: 44, alignment: .trailing)
        }
    }

    /// `Slider` wants a `Double`; the setting is whole gigabytes.
    private var warnBelowBinding: Binding<Double> {
        Binding(
            get: { Double(settings.warnBelowGB) },
            set: { settings.warnBelowGB = Int($0.rounded()) }
        )
    }

    // MARK: - iCloud

    /// The plan size is the only figure on the Dashboard's iCloud card with no source
    /// at all — `brctl` reports free space but never the plan it is free within — so
    /// it is estimated, and this is where a wrong estimate gets corrected.
    private var iCloud: some View {
        PrefSection("iCloud") {
            PrefRow(
                title: "Storage plan",
                // One line: the row has a fixed height, and the longer version was
                // clipped at both ends.
                description: "macOS does not report your plan size, so it is estimated."
            ) {
                Picker("Storage plan", selection: $settings.iCloudPlan) {
                    ForEach(ICloudPlan.allCases) { plan in
                        Text(plan.displayName).tag(plan)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }


}

// MARK: - Preview

#Preview("General") {
    GeneralPane(settings: .preview())
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}
