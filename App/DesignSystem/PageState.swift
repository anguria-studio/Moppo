import SwiftUI

/// Shares icon, text, and action placement across page states.
struct PageState<Actions: View>: View {
    let title: String
    let symbol: String
    var detail: String? = nil
    var iconColor: Color? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        PageStateLayout(title: title) {
            PageStateSymbol(name: symbol, color: iconColor)
        } detail: {
            if let detail { Text(detail) }
        } actions: {
            actions()
        }
    }
}

extension PageState where Actions == EmptyView {
    init(title: String, symbol: String, detail: String? = nil, iconColor: Color? = nil) {
        self.init(title: title, symbol: symbol, detail: detail, iconColor: iconColor) { EmptyView() }
    }
}

/// Supports longer messages and short windows without hiding actions.
struct PageStateLayout<Icon: View, Detail: View, Actions: View>: View {
    let title: String
    @ViewBuilder var icon: () -> Icon
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ContentUnavailableView {
                Label {
                    Text(title)
                } icon: {
                    // Every state screen uses the same icon area, so the title does not move between screens.
                    // Smaller icons sit at the bottom of the area, near the title.
                    icon()
                        .frame(width: PageStateMetrics.iconAreaSize, height: PageStateMetrics.iconAreaSize,
                               alignment: .bottom)
                }
                .labelStyle(PageStateLabelStyle())
            } description: {
                detail()
                    .lineSpacing(PageStateMetrics.detailLineSpacing)
            }

            // Keep actions outside the message's limited width.
            actions()
                .buttonStyle(PageStateButtonStyle())
                .controlSize(.large)
                // ContentUnavailableView adds bottom space. Move actions closer to the message.
                .padding(.top, -16)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(PageStateMetrics.padding)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}

private struct PageStateLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: PageStateMetrics.iconTitleSpacing) {
            configuration.icon
                .foregroundStyle(.tertiary)
            configuration.title
                .font(.system(size: PageStateMetrics.titleSize, weight: .bold))
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, PageStateMetrics.titleBottomPadding)
    }
}

struct PageStateSymbol: View {
    let name: String
    var color: Color? = nil

    var body: some View {
        if let color { image.foregroundStyle(color) }
        else { image }
    }

    private var image: some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: PageStateMetrics.iconSize, height: PageStateMetrics.iconSize)
    }
}

/// Keeps short actions equal in width and allows longer labels to grow.
struct PageStateButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var foreground: Color? = nil
    @Environment(\.pageStateActionsStacked) private var isStacked

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fixedSize(horizontal: true, vertical: false)
            .frame(
                minWidth: PageStateMetrics.actionLabelWidth,
                maxWidth: isStacked ? .infinity : nil
            )
            .padding(.horizontal, 8)
            .modifier(PageActionSurface(tint: tint, isPressed: configuration.isPressed, foreground: foreground))
    }
}

/// Places actions in a column when a row does not fit.
struct PageStateActions<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { content() }
            VStack(spacing: 10) { content() }
                // Use the widest action as the column width.
                .fixedSize(horizontal: true, vertical: false)
                .environment(\.pageStateActionsStacked, true)
        }
    }
}

private extension EnvironmentValues {
    @Entry var pageStateActionsStacked = false
}

/// Uses the shared page layout for completed operations and their actions.
struct PageCompletionView<Detail: View, Actions: View>: View {
    let title: String
    var isSuccess = true
    var animate = true
    @ViewBuilder var detail: () -> Detail
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        PageStateLayout(title: title) {
            CompletionMark(animate: animate, isSuccess: isSuccess, size: PageStateMetrics.iconSize)
        } detail: {
            detail()
        } actions: {
            actions()
        }
    }
}

enum PageStateMetrics {
    static let iconSize: CGFloat = 44
    /// The icon area holds the animated Moppo. Symbols keep `iconSize` and sit at the bottom of it.
    static let iconAreaSize: CGFloat = 88
    static let titleSize: CGFloat = 18
    static let iconTitleSpacing: CGFloat = 20
    static let titleBottomPadding: CGFloat = 6
    static let detailLineSpacing: CGFloat = 4
    static let actionLabelWidth: CGFloat = 104
    static let padding: CGFloat = 32
}

#Preview("Permission") {
    PageState(
        title: "Allow Photos access",
        symbol: "exclamationmark.triangle",
        detail: "Open System Settings to allow access to Photos.",
        iconColor: Token.textColor(.orange)
    ) {
        Button("Open Settings") {}
            .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
    }
    .frame(width: 760, height: 480)
}

#Preview("Short window") {
    PageState(title: "The folder could not be read", symbol: "folder.badge.questionmark",
              detail: "Connect the volume or choose another folder.") {
        PageStateActions {
            Button("Try Again") {}
                .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
            Button {} label: {
                Label("Choose Another Folder", systemImage: "folder")
            }
        }
    }
    .frame(width: 380, height: 260)
}

#Preview("Stopped measurement") {
    PageState(title: "Measurement stopped", symbol: "stop.circle",
              detail: "Measure this folder again or choose another location.") {
        PageStateActions {
            Button("Measure Again") {}
                .buttonStyle(PageStateButtonStyle(tint: Token.color(.accent)))
            Button {} label: {
                Label("Choose Another Folder", systemImage: "folder")
            }
        }
    }
    .frame(width: 760, height: 480)
}
