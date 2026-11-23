import SwiftUI

/// Keeps card visibility, setup, and the storage plan in one Settings section.
struct ICloudPreferences: View {
    @Bindable var settings: SettingsStore
    var dashboard: DashboardModel?
    var access: AccessModel?
    @State private var showsSetup = false

    var body: some View {
        PrefSection("iCloud") {
            PrefToggleRow(
                title: String(localized: "Show on Dashboard"), description: String(localized: "Display your iCloud storage in Moppo."),
                isOn: $settings.showICloudOnDashboard
            )
            PrefDivider()
            PrefRow(
                title: String(localized: "iCloud storage"),
                description: dashboard?.iCloudStorage == nil
                    ? String(localized: "Set up access to read your storage information.")
                    : String(localized: "Storage information is available.")
            ) {
                Button(dashboard?.iCloudStorage == nil ? String(localized: "Set Up") : String(localized: "Open Settings")) {
                    if dashboard?.iCloudStorage != nil {
                        ICloudCard.openICloudSettings()
                    } else {
                        settings.showICloudOnDashboard = true
                        showsSetup = true
                    }
                }
                .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                .disabled(dashboard == nil)
            }
            PrefDivider()
            PrefRow(
                title: String(localized: "Storage plan"),
                description: String(localized: "macOS does not report your plan size, so it is estimated.")
            ) {
                Menu {
                    Picker("Storage plan", selection: $settings.iCloudPlan) {
                        ForEach(ICloudPlan.allCases) { plan in
                            Text(plan.displayName).tag(plan)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    HStack(spacing: 7) {
                        Text(settings.iCloudPlan.displayName)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                }
                .menuStyle(.button)
                .buttonStyle(PageActionButtonStyle(size: .compact, fill: Token.Fill.buttonOnCard))
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Storage plan")
                .accessibilityValue(settings.iCloudPlan.displayName)
            }
        }
        .onChange(of: settings.showICloudOnDashboard) { _, _ in
            Task { await dashboard?.loadICloud() }
        }
        .onChange(of: settings.iCloudPlan) { _, _ in
            Task { await dashboard?.loadICloud() }
        }
        .sheet(isPresented: $showsSetup) {
            if let dashboard { ICloudSetupView(model: dashboard, access: access) }
        }
    }
}
