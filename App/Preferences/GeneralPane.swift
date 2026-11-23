import Combine
import SwiftUI
import MoppoCore

/// Shows language, appearance, startup, scan, alert, and iCloud settings.
struct GeneralPane: View {

    @Bindable var settings: SettingsStore
    var dashboard: DashboardModel?
    var access: AccessModel?
    var languageRestartAvailability: AppDelegate.LanguageRestartAvailability = .blocked
    var onLanguageChange: (() -> Void)?
    var onRestartLanguage: (() -> Void)?

    var body: some View {
        PrefPane {
            appearance
            startup
            scanning
            ICloudPreferences(settings: settings, dashboard: dashboard, access: access)
        }
        .onAppear { settings.reloadAppLanguage() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.reloadAppLanguage()
        }
    }

    private var appearance: some View {
        PrefSection(String(localized: "Appearance")) {
            PrefPickerRow(
                title: String(localized: "Appearance"),
                selection: $settings.appearance,
                label: \.displayName
            )
            PrefDivider()
            languagePicker
        }
    }

    private var languagePicker: some View {
        let title = String(localized: "Language")
        let showsRestart = onRestartLanguage != nil && settings.hasPendingAppLanguageChange
        let description = showsRestart ? languageRestartAvailability.message : nil
        return PrefRow(title: title, description: description) {
            Picker(title, selection: Binding(get: { settings.appLanguage }, set: { language in
                if settings.setAppLanguage(language) { onLanguageChange?() }
            })) {
                ForEach(AppLanguage.allCases) { language in
                    Text(verbatim: language.displayName).tag(language)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .disabled(languageRestartAvailability == .waitingForCleanup)
            if showsRestart, let onRestartLanguage {
                Button("Restart Moppo", action: onRestartLanguage)
                    .buttonStyle(SecondaryButtonStyle(fill: Token.Fill.buttonOnCard))
                    .disabled(!languageRestartAvailability.canRestart)
            }
        }
    }

    // MARK: - Startup

    private var startup: some View {
        PrefSection(String(localized: "Startup")) {
            PrefToggleRow(title: String(localized: "Open at login"), isOn: $settings.launchAtLogin)
            PrefDivider()
            PrefToggleRow(
                title: String(localized: "Show in menu bar"),
                description: String(localized: "Live free-space readout and a one-click cache purge."),
                isOn: $settings.showInMenuBar
            )
        }
    }

    // MARK: - Scanning

    private var scanning: some View {
        PrefSection(String(localized: "Scanning")) {
            PrefPickerRow(
                title: String(localized: "Scan automatically"),
                selection: $settings.scanSchedule,
                label: \.displayName
            )
            PrefDivider()
            PrefToggleRow(title: String(localized: "Only when plugged in and idle"), isOn: $settings.idleOnly)
            PrefDivider()
            PrefToggleRow(
                title: String(localized: "Show items smaller than 1 MB"),
                description: String(localized: "Cleanup shows these items after the next scan. Lists can become much longer."),
                isOn: $settings.showsSmallItems
            )
            PrefDivider()
            PrefToggleRow(title: String(localized: "Low-space alerts"), isOn: $settings.lowSpaceAlertsEnabled)
            PrefDivider()
            PrefRow(
                title: String(localized: "Warn me below"),
                description: String(localized: "Notify when free space drops under the threshold.")
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

            Text(ByteFormatting.localizedGigabytes(Double(settings.warnBelowGB)))
                .font(.mcControlLabel.monospacedDigit())
                .foregroundStyle(Token.Text.primary)
                // Keep the slider stable when the number of digits changes.
                .frame(minWidth: 44, alignment: .trailing)
        }
    }

    /// `Slider` wants a `Double`; the setting is whole gigabytes.
    private var warnBelowBinding: Binding<Double> {
        Binding(
            get: { Double(settings.warnBelowGB) },
            set: { settings.warnBelowGB = Int($0.rounded()) }
        )
    }

}

// MARK: - Preview

#Preview("General") {
    GeneralPane(settings: .preview())
        .background(Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(.dark)
}
