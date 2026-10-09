import SwiftUI
import MoppoCore

/// Shows navigation and storage information in a fixed sidebar.
struct SidebarView: View {
    @Bindable var model: AppModel
    var headerBand: CGFloat = 0

    /// Shows selection before the destination finishes its first layout.
    @State private var pendingView: AppModel.View?
    @FocusState private var focusedView: AppModel.View?

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
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                let views = AppModel.View.sidebarViews
                guard let index = views.firstIndex(of: focusedView ?? pendingView ?? model.view) else { return .ignored }
                let next = index + (press.key == .upArrow ? -1 : 1)
                if views.indices.contains(next) { select(views[next]) }
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sidebar")
        }
        .onChange(of: model.view) { pendingView = nil }
        .safeAreaInset(edge: .bottom, spacing: 0) { capacityFooter }
    }

    private func navigationRow(_ view: AppModel.View) -> some View {
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
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 4) { isPressing in
            if isPressing { select(view) }
        } perform: {}
        .focusable()
        .focusEffectDisabled()
        .focused($focusedView, equals: view)
        .background(
            RoundedRectangle(cornerRadius: Token.Radius.sidebarRow, style: .continuous)
                .fill(isSelected(view) ? Token.Fill.sidebarSelection : .clear)
        )
        .overlay {
            if focusedView == view, !isSelected(view) {
                RoundedRectangle(cornerRadius: Token.Radius.sidebarRow, style: .continuous)
                    .strokeBorder(Token.color(.accent), lineWidth: 2)
            }
        }
        .accessibilityAddTraits(isSelected(view) ? .isSelected : [])
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
        focusedView = view
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

    /// "220.36 of 245.11 GB used". The unit is written once when both figures land
    /// in it, which on any real startup volume they do; a pair that somehow split
    /// units keeps both, since dropping one would then be a lie about the smaller.
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
