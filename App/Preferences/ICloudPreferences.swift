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
                title: "Show on Dashboard", description: "Display your iCloud storage in Moppo.",
                isOn: $settings.showICloudOnDashboard
            )
            PrefDivider()
            PrefRow(
                title: "iCloud storage",
                description: dashboard?.iCloudStorage == nil
                    ? "Set up access to read your storage information."
                    : "Storage information is available."
            ) {
                Button(dashboard?.iCloudStorage == nil ? "Set Up" : "Open Settings") {
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
                title: "Storage plan",
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
