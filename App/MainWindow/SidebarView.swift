import SwiftUI
import AppKit
import MoppoCore

/// Shows navigation and storage information in a fixed sidebar.
struct SidebarView: View {
    @Bindable var model: AppModel
    var headerBand: CGFloat = 0

    /// Shows selection before the destination finishes its first layout.
    @State private var pendingView: AppModel.View?
    @State private var showsTrashMenu = false
    @State private var trashMenuAnchor = UnitPoint.trailing
    @State private var selectedTrashAction: TrashSidebarMenu.Action?
    @FocusState private var sidebarIsFocused: Bool
    @AccessibilityFocusState(for: .voiceOver) private var voiceOverView: AppModel.View?
    @Environment(\.isFocusEffectEnabled) private var showsKeyboardFocus

    var body: some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: headerBand)
                .background(WindowDragHandle())
                .accessibilityHidden(true)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AppModel.View.sidebarSections) { section in
                        if !section.title.isEmpty {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Token.Text.secondary)
                                .padding(.horizontal, 10)
                                .padding(.top, 16)
                                .padding(.bottom, 6)
                                .accessibilityAddTraits(.isHeader)
                        }
                        ForEach(section.views) { view in
                            navigationRow(view)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($sidebarIsFocused)
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                if showsTrashMenu { return handleTrashMenuKey(press) }
                let views = AppModel.View.sidebarViews
                guard let index = views.firstIndex(of: pendingView ?? model.view) else { return .ignored }
                let next = index + (press.key == .upArrow ? -1 : 1)
                if views.indices.contains(next) { select(views[next]) }
                return .handled
            }
            .onKeyPress(keys: [.space, .return]) { press in
                if showsTrashMenu { return handleTrashMenuKey(press) }
                guard sidebarIsFocused else { return .ignored }
                select(pendingView ?? model.view)
                return .handled
            }
            .onKeyPress(keys: [.escape], action: handleTrashMenuKey)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar")
        }
        .onAppear { sidebarIsFocused = true }
        .onChange(of: model.view) { _, view in
            pendingView = nil
            voiceOverView = view
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { capacityFooter }
    }

    @ViewBuilder
    private func navigationRow(_ view: AppModel.View) -> some View {
        if view == .trash {
            navigationButton(view)
                .overlay {
                    TrashMenuClickTarget { anchor in
                        sidebarIsFocused = true
                        trashMenuAnchor = anchor
                        selectedTrashAction = nil
                        showsTrashMenu = true
                    }
                }
                .accessibilityAction(named: "Show Trash Menu") {
                    sidebarIsFocused = true
                    trashMenuAnchor = .trailing
                    selectedTrashAction = nil
                    showsTrashMenu = true
                }
                .popover(isPresented: $showsTrashMenu, attachmentAnchor: .point(trashMenuAnchor), arrowEdge: .trailing) {
                    TrashSidebarMenu(
                        canEmptyTrash: model.canEmptyTrash,
                        selectedAction: $selectedTrashAction,
                        onKeyPress: handleTrashMenuKey
                    ) {
                        select(.trash)
                    } onEmptyTrash: {
                        model.requestEmptyTrash()
                    }
                }
        } else {
            navigationButton(view)
        }
    }

    private func navigationButton(_ view: AppModel.View) -> some View {
        Button {
            select(view)
        } label: {
            HStack(spacing: 10) {
                sidebarIcon(for: view)
                    .frame(width: 22)
                    .foregroundStyle(Token.Text.primary)
                    .accessibilityHidden(true)
                Text(view.title)
                    .font(.system(size: 13, weight: isSelected(view) ? .semibold : .regular))
                    .foregroundStyle(Token.Text.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count = count(for: view) {
                    Text(count, format: .number)
                        .font(.mcSidebarCount)
                        .foregroundStyle(Token.Text.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: Token.Size.sidebarRow, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarRowButtonStyle())
        // Mouse selection starts on press. The button also supports keyboard activation.
        // A right-click opens the menu without changing the page.
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 4) { isPressing in
            if isPressing, NSEvent.pressedMouseButtons & 2 == 0 {
                select(view)
            }
        } perform: {}
        // The sidebar provides one Tab stop. Arrow keys select its pages.
        .focusable(false)
        .accessibilityFocused($voiceOverView, equals: view)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.sidebarRow, style: .continuous)
                .fill(isSelected(view) ? Token.Fill.sidebarSelection : .clear)
        )
        .overlay {
            if showsKeyboardFocus, sidebarIsFocused, isSelected(view) {
                RoundedRectangle(cornerRadius: Token.Radius.sidebarRow, style: .continuous)
                    .strokeBorder(Token.color(.accent), lineWidth: 2)
            }
        }
        .accessibilityAddTraits(isSelected(view) ? .isSelected : [])
    }

    private func handleTrashMenuKey(_ press: KeyPress) -> KeyPress.Result {
        guard showsTrashMenu else { return .ignored }
        switch press.key {
        case .downArrow, .upArrow:
            selectedTrashAction = model.canEmptyTrash
                && (selectedTrashAction == .open || (selectedTrashAction == nil && press.key == .upArrow))
                ? .emptyTrash : .open
        case .return, .space:
            showsTrashMenu = false
            if selectedTrashAction == .emptyTrash {
                model.requestEmptyTrash()
            } else {
                select(.trash)
            }
        case .escape:
            showsTrashMenu = false
        default:
            return .ignored
        }
        return .handled
    }

    @ViewBuilder
    private func sidebarIcon(for view: AppModel.View) -> some View {
        if view == .scanner {
            Image(isSelected(view) ? "MoppoFilled" : "MoppoOutline")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
        } else {
            Image(systemName: isSelected(view) ? view.selectedSymbol : view.symbol)
                .font(.system(size: 18, weight: .regular))
                .imageScale(.medium)
                .symbolRenderingMode(.monochrome)
        }
    }

    private func select(_ view: AppModel.View) {
        sidebarIsFocused = true
        guard (pendingView ?? model.view) != view else { return }
        pendingView = view
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1))
            guard pendingView == view else { return }
            model.view = view
            pendingView = nil
        }
    }

    private func isSelected(_ view: AppModel.View) -> Bool {
        (pendingView ?? model.view) == view
    }

    /// Shows storage information below navigation without a separate card.
    private var capacityFooter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.dashboard.volume.map { "\(ByteFormatting.string($0.freeBytes)) free" } ?? "—")
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)
                .lineLimit(1)
            capacityBar
                .accessibilityHidden(true)
            Text(usedSummary ?? "—")
                .font(.mcCaption)
                .foregroundStyle(Token.Text.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .accessibilityElement(children: .combine)
    }

    private var capacityBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Token.ink(light: 0.08, dark: 0.10))
                Capsule()
                    .fill(Token.Text.secondary)
                    .frame(width: max(usedFraction > 0 ? Token.Size.sidebarCapacityBar : 0,
                                      geometry.size.width * usedFraction))
            }
        }
        .frame(height: Token.Size.sidebarCapacityBar)
    }

    private var usedFraction: Double {
        guard let volume = model.dashboard.volume, volume.capacityBytes > 0 else { return 0 }
        return Double(volume.usedBytes) / Double(volume.capacityBytes)
    }

    /// Shows a shared unit once. Shows both units when they differ.
    private var usedSummary: String? {
        guard let volume = model.dashboard.volume else { return nil }
        let used = ByteFormatting.string(volume.usedBytes)
        let capacity = ByteFormatting.string(volume.capacityBytes)
        guard let usedUnit = used.split(separator: " ").last,
              let capacityUnit = capacity.split(separator: " ").last,
              usedUnit == capacityUnit
        else { return "\(used) of \(capacity) used" }
        return "\(used.dropLast(usedUnit.count + 1)) of \(capacity) used"
    }

    /// Shows the item count beside Trash.
    private func count(for view: AppModel.View) -> Int? {
        switch view {
        case .trash:
            let items = model.recovery.trashSummary?.itemCount ?? 0
            return items > 0 ? items : nil
        default:
            return nil
        }
    }
}

private struct TrashSidebarMenu: View {
    let canEmptyTrash: Bool
    @Binding var selectedAction: Action?
    let onKeyPress: (KeyPress) -> KeyPress.Result
    let onOpen: () -> Void
    let onEmptyTrash: () -> Void
    @Environment(\.dismiss) private var dismiss
    enum Action { case open, emptyTrash }

    var body: some View {
        VStack(spacing: 4) {
            Button { activate(.open) } label: {
                Text("Open").padding(.horizontal, 4)
            }
            .buttonStyle(MenuItemButtonStyle(isHighlighted: selectedAction == .open))
            .onHover { hovering in
                if hovering { selectedAction = .open }
                else if selectedAction == .open { selectedAction = nil }
            }
            Divider().padding(.horizontal, 10)
            Button { activate(.emptyTrash) } label: {
                Text("Empty Trash").padding(.horizontal, 4)
            }
            .disabled(!canEmptyTrash)
            .buttonStyle(MenuItemButtonStyle(isHighlighted: selectedAction == .emptyTrash))
            .onHover { hovering in
                if hovering, canEmptyTrash { selectedAction = .emptyTrash }
                else if selectedAction == .emptyTrash { selectedAction = nil }
            }
        }
        .padding(6)
        .fixedSize()
        .onKeyPress(keys: [.upArrow, .downArrow, .return, .space, .escape], action: onKeyPress)
    }

    private func activate(_ action: Action) {
        guard action != .emptyTrash || canEmptyTrash else { return }
        dismiss()
        switch action {
        case .open: onOpen()
        case .emptyTrash: onEmptyTrash()
        }
    }
}

/// Receives secondary clicks and lets other input reach the navigation button.
private struct TrashMenuClickTarget: NSViewRepresentable {
    let onClick: (UnitPoint) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onClick = isEnabled ? onClick : nil
    }

    final class ClickView: NSView {
        var onClick: ((UnitPoint) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard onClick != nil, super.hitTest(point) != nil,
                  let event = NSApp.currentEvent,
                  event.type == .rightMouseDown
                    || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            else { return nil }
            return self
        }

        override func rightMouseDown(with event: NSEvent) { showMenu(for: event) }
        override func mouseDown(with event: NSEvent) { showMenu(for: event) }

        private func showMenu(for event: NSEvent) {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let point = convert(event.locationInWindow, from: nil)
            onClick?(UnitPoint(
                x: (point.x - bounds.minX) / bounds.width,
                y: 1 - (point.y - bounds.minY) / bounds.height
            ))
        }
    }
}
