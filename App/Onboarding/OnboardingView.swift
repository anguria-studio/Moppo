import AppKit
import SwiftUI
import MoppoCore

struct OnboardingView: View {
    typealias Step = OnboardingProgress.Step
    @State private var step: Step
    @State private var isChoosingFolder = false
    @Bindable var settings: SettingsStore
    let access: AccessModel
    let progress: OnboardingProgress?
    let onFinish: (URL?) -> Void

    init(
        settings: SettingsStore, access: AccessModel, step: Step = .welcome,
        progress: OnboardingProgress? = nil, onFinish: @escaping (URL?) -> Void
    ) {
        self.settings = settings
        self.access = access
        self.progress = progress
        _step = State(initialValue: progress?.pendingStep ?? step)
        self.onFinish = onFinish
    }

    static var launchAccess: LaunchAccess {
        OnboardingProgress(defaults: .standard).launchAccess(
            hasFullDiskAccess: FullDiskAccess.isGranted,
            forceWelcome: isRequestedAtLaunch
        )
    }

    static var isRequestedAtLaunch: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--show-onboarding")
        #else
        false
        #endif
    }

    private var isWelcome: Bool { step == .welcome }

    var body: some View {
        VStack(spacing: 0) {
            WindowDragHandle().frame(height: Token.Size.headerBand)
            ScrollView {
                VStack(spacing: 12) {
                    // Moppo stays in place between the steps. Only the content below it changes.
                    OnboardingMascot(isWelcome: isWelcome)
                    VStack(spacing: 24) {
                        heading
                        Group {
                            if isWelcome {
                                AccessList(access: access, animateEntrance: true)
                            } else {
                                preferences
                            }
                        }
                        .frame(maxWidth: 540)
                    }
                    .id(step)
                    .transition(.identity)
                }
                .frame(maxWidth: 620)
                .padding(.horizontal, 32)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: 470)
            }
            .defaultScrollAnchor(.center, for: .alignment)
            footer
        }
        // Focus outlines show only during keyboard input, as in the main window.
        .modifier(KeyboardFocusVisibility())
        .background(Token.chrome.ignoresSafeArea())
        .ignoresSafeArea(.container, edges: .top)
        .background {
            if !access.isPreview { WindowChrome() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await access.refresh() }
        }
    }

    private var heading: some View {
        VStack(spacing: 12) {
            Text(isWelcome ? "Welcome to Moppo" : "Set Your Preferences")
                .font(.mcSecondaryHero)
                .foregroundStyle(Token.Text.primary)
                .accessibilityAddTraits(.isHeader)
                .modifier(OnboardingEntrance(index: 1))
            Text(isWelcome
                 ? "Make room for what matters.\nFiles go to Trash first, so you can always restore them."
                 : "You can change these settings at any time in Settings.")
                .font(.system(size: 15))
                .foregroundStyle(Token.Text.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 36)
                .modifier(OnboardingEntrance(index: 2))
        }
    }

    private var preferences: some View {
        VStack(spacing: 10) {
            preferenceRow("Scan automatically", detail: scanDetail, symbol: "calendar", index: 3) {
                Picker("Scan automatically", selection: $settings.scanSchedule) {
                    ForEach(ScanSchedule.allCases) { schedule in
                        Text(schedule.displayName).tag(schedule)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 238)
                .disabled(access.disk != .allowed)
            }
            preferenceRow(
                "Low-space alerts",
                detail: access.notifications.permitsAccess
                    ? "Notify me below \(settings.warnBelowGB) GB free."
                    : "Enable notifications on Welcome to receive alerts.",
                symbol: "bell", index: 4
            ) {
                Toggle("Low-space alerts", isOn: $settings.lowSpaceAlertsEnabled)
                    .toggleStyle(.switch).labelsHidden()
            }
            preferenceRow("Show in menu bar", detail: "See free space at a glance.", symbol: "menubar.rectangle", index: 5) {
                Toggle("Show in menu bar", isOn: $settings.showInMenuBar)
                    .toggleStyle(.switch).labelsHidden()
            }
        }
    }

    private var scanDetail: String {
        if access.disk != .allowed { return "Requires Full Disk Access. Manual folder scans remain available." }
        return settings.idleOnly ? "When plugged in and idle." : "Uses your saved scan schedule."
    }

    private func preferenceRow<Control: View>(
        _ title: String, detail: String, symbol: String, index: Int, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Token.Text.primary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Token.Text.primary)
                Text(detail).font(.system(size: 13)).foregroundStyle(Token.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
        .frame(minHeight: 40)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Token.Fill.well, in: RoundedRectangle(cornerRadius: Token.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Token.Radius.card)
            .strokeBorder(Token.Fill.boxBorder, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .modifier(OnboardingEntrance(index: index))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                HStack {
                    if !isWelcome {
                        Button("Back") { changeStep(to: .welcome) }
                            .buttonStyle(PageActionButtonStyle())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 12) {
                    stepButton(1, title: "Welcome", destination: .welcome)
                    Rectangle().fill(Token.separator).frame(width: 24, height: 1)
                    stepButton(2, title: "Preferences", destination: .preferences)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Setup steps")
                HStack(spacing: 12) {
                    if !isWelcome, access.disk != .allowed {
                        Button("Skip for Now") { onFinish(nil) }
                            .buttonStyle(PageActionButtonStyle())
                    }
                    Button(isWelcome ? "Continue" : (access.disk == .allowed ? "Get Started" : "Choose Folder")) {
                        if isWelcome { changeStep(to: .preferences) }
                        else if access.disk == .allowed { onFinish(nil) }
                        else { chooseFolder() }
                    }
                    .buttonStyle(PageActionButtonStyle(tint: Token.color(.accent)))
                    .keyboardShortcut(.defaultAction)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .disabled(isChoosingFolder)
            .padding(.vertical, 20)
        }
        .padding(.horizontal, 32)
    }

    private func chooseFolder() {
        guard !access.isPreview else { return }
        isChoosingFolder = true
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder"
        panel.message = "Moppo will measure only the folder you select."
        panel.prompt = "Choose Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        Task { @MainActor in
            defer { isChoosingFolder = false }
            guard await panel.presentAsSheet() == .OK, let url = panel.url else { return }
            onFinish(url)
        }
    }

    private func stepButton(_ number: Int, title: String, destination: Step) -> some View {
        let active = step == destination
        return Button {
            changeStep(to: destination)
        } label: {
            HStack(spacing: 8) {
                Text("\(number)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Token.Text.secondary)
                    .frame(width: 26, height: 26)
                    .background(active ? Token.color(.accent) : Token.Fill.control, in: Circle())
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? Token.Text.primary : Token.Text.secondary)
            }
            .fixedSize()
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Step \(number) of 2: \(title)")
        .accessibilityValue(active ? "Current step" : "")
        .help("Show \(title)")
    }

    private func changeStep(to step: Step) {
        guard self.step != step else { return }
        progress?.save(step)
        self.step = step
    }
}

/// Shows Moppo above the onboarding content. On Welcome, Moppo looks around.
/// On Preferences, Moppo turns into the settings icon. With Reduce Motion on, the app icon and the slider symbol show.
private struct OnboardingMascot: View {
    let isWelcome: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !reduceMotion, MoppoMascotGeometry.shared != nil {
                MoppoMascotView(mode: .search, shape: isWelcome ? nil : .settings)
                    .frame(width: 113, height: 113)
                    .foregroundStyle(.tertiary)
            } else if isWelcome {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 96, height: 96)
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(Token.Text.primary)
                    .frame(width: 96, height: 96)
            }
        }
        .accessibilityHidden(true)
        .modifier(OnboardingEntrance(index: 0))
    }
}

#Preview("Welcome light") {
    OnboardingView(settings: .preview(), access: .preview()) { _ in }
        .frame(width: 1000, height: 640).preferredColorScheme(.light)
}

#Preview("Welcome dark") {
    OnboardingView(settings: .preview(), access: .preview(disk: true)) { _ in }
        .frame(width: 1000, height: 640).preferredColorScheme(.dark)
}

#Preview("Preferences light") {
    OnboardingView(settings: .preview(), access: .preview(disk: true, notifications: .allowed), step: .preferences) { _ in }
        .frame(width: 1000, height: 640).preferredColorScheme(.light)
}

#Preview("Preferences dark") {
    OnboardingView(settings: .preview(), access: .preview(), step: .preferences) { _ in }
        .frame(width: 1000, height: 640).preferredColorScheme(.dark)
}
