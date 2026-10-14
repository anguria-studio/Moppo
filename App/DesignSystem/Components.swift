import AppKit
import SwiftUI
import MoppoCore

/// Shows an explanation when the pointer enters the icon.
struct HoverHelpIcon: View {
    let systemName: String
    let text: String
    var color: Color = Token.Text.quaternary
    var hoverColor: Color? = nil
    @State private var isPresented = false

    var body: some View {
        Image(systemName: systemName)
            .foregroundStyle(isPresented ? hoverColor ?? color : color)
            .contentShape(Rectangle())
            .onHover { isPresented = $0 && !text.isEmpty }
            .popover(isPresented: $isPresented, arrowEdge: .top) {
                Text(text)
                    .font(.mcSubtitle)
                    .foregroundStyle(Token.Text.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(width: 280)
                    .presentationBackground(Token.chrome)
            }
            .accessibilityLabel(text)
    }
}

/// Gives cards immediate feedback while the mouse button is held.
struct CardPressButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = Token.Radius.card
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Token.Text.primary.opacity(configuration.isPressed ? 0.08 : 0))
                    .allowsHitTesting(false)
            }
            .animation(
                reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.12),
                value: configuration.isPressed
            )
    }
}

/// Animates the removal action without delaying its disabled state.
struct HeaderRemovalButtonStyle: ButtonStyle {
    var tint: Color
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 12)
            .frame(minHeight: 38)
            .foregroundStyle(isEnabled ? Color.white : Token.Text.disabled)
            .background(isEnabled ? tint : Token.Fill.controlDisabled, in: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled && configuration.isPressed ? 0.85 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// Keeps native checkbox behavior with colors that follow the current theme.
struct SelectionCheckbox: NSViewRepresentable {
    var title: String
    var detail: String? = nil
    var state: NSControl.StateValue
    var isEnabled = true
    var showsTitle = true
    var onChange: (Bool) -> Void
    @Environment(\.isEnabled) private var environmentEnabled

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.cell = SelectionCheckboxCell(textCell: "")
        button.setButtonType(.switch)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 14, weight: .medium)
        button.allowsMixedState = true
        button.target = context.coordinator
        button.action = #selector(Coordinator.toggle)
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        button.title = showsTitle ? title : ""
        button.imagePosition = showsTitle ? .imageLeading : .imageOnly
        button.setAccessibilityLabel(title)
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 14, weight: .medium)
        if showsTitle, let detail {
            let label = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ])
            label.append(NSAttributedString(string: "   " + detail, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor
            ]))
            button.attributedTitle = label
            button.setAccessibilityLabel("\(title), \(detail)")
        }
        button.state = state
        button.isEnabled = isEnabled && environmentEnabled
        button.invalidateIntrinsicContentSize()
        button.needsDisplay = true
        context.coordinator.onChange = { onChange(state != .on) }
    }

    final class Coordinator: NSObject {
        var onChange: (() -> Void)?

        @objc func toggle(_ sender: NSButton) { onChange?() }
    }
}

private final class SelectionCheckboxCell: NSButtonCell {
    override func drawImage(_ image: NSImage, withFrame frame: NSRect, in controlView: NSView) {
        let dark = controlView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let ink: NSColor = dark ? .white : .black
        let opposite: NSColor = dark ? .black : .white
        let alpha: CGFloat = isEnabled ? (isHighlighted ? 0.75 : 1) : 0.35
        let side: CGFloat = 15
        let box = NSRect(x: frame.midX - side / 2, y: frame.midY - side / 2,
                         width: side, height: side)
        let shape = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        if state == .off {
            (dark ? ink.withAlphaComponent(0.06 * alpha) : NSColor.white.withAlphaComponent(alpha)).setFill()
            shape.fill()
            ink.withAlphaComponent((dark ? 0.45 : 0.5) * alpha).setStroke()
            shape.lineWidth = 1
            shape.stroke()
        } else {
            let selectedFill = dark ? ink : NSColor(srgbRed: 0.145, green: 0.388, blue: 0.922, alpha: 1)
            selectedFill.withAlphaComponent(alpha).setFill()
            shape.fill()
            let mark = NSBezierPath()
            func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
                NSPoint(x: box.minX + side * x,
                        y: box.minY + side * (controlView.isFlipped ? y : 1 - y))
            }
            if state == .mixed {
                mark.move(to: point(0.25, 0.5))
                mark.line(to: point(0.75, 0.5))
            } else {
                mark.move(to: point(0.23, 0.51))
                mark.line(to: point(0.43, 0.72))
                mark.line(to: point(0.78, 0.28))
            }
            opposite.withAlphaComponent(alpha).setStroke()
            mark.lineWidth = 1.8
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.stroke()
        }
    }
}

// MARK: - Grouped box

/// The design's grouped box: a rounded, hairline-bordered container.
///
/// Deliberately not `GroupBox`. The stock control draws its own title area and
/// padding, which fights every layout here; the design's box is a plain surface.
struct GroupedBox<Content: View>: View {
    var radius: CGFloat = Token.Radius.box
    var fill: Color = Token.Fill.box
    @ViewBuilder var content: Content

    var body: some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Token.Fill.cardBorder, lineWidth: Token.hairline)
            )
    }
}

/// Shares the alert surface, close button, and dismissal animation.
struct NoticeBanner<Content: View>: View {
    let title: String
    var dismiss: (() -> Void)?
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GroupedBox(radius: Token.Radius.well) {
            HStack(spacing: 12) {
                content
                if let dismiss {
                    Button {
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.mcSubtitle)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Token.Text.secondary)
                    .accessibilityLabel("Dismiss \(title)")
                }
            }
            .padding(14)
        }
        .transition(reduceMotion ? .identity : .opacity.combined(with: .offset(y: -6)))
    }
}

/// A recessed well — expanded table bodies, callouts, the exclusion list.
struct Well<Content: View>: View {
    var radius: CGFloat = Token.Radius.well
    @ViewBuilder var content: Content

    var body: some View {
        content.background(Token.Fill.well, in: RoundedRectangle(cornerRadius: radius))
    }
}

// MARK: - Small parts

/// The 9pt rounded square identifying a category, matching its capacity-bar segment.
struct CategoryDot: View {
    let color: ColorToken
    var size: CGFloat = 9

    var body: some View {
        RoundedRectangle(cornerRadius: Token.Radius.dot)
            .fill(Token.color(color))
            .frame(width: size, height: size)
    }
}

struct Badge: View {
    enum Style { case neutral, safe, review, danger, positiveOutline }

    let text: String
    var style: Style = .neutral

    var body: some View {
        Text(text)
            .font(.mcBadge)
            // Text uses readable colors. The capsule uses a lighter fill.
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                background,
                in: Capsule()
            )
            .overlay {
                if style == .positiveOutline {
                    Capsule().strokeBorder(Token.textColor(.green).opacity(0.4), lineWidth: 1)
                }
            }
    }

    private var foreground: Color {
        switch style {
        case .neutral: Token.Text.secondary
        case .safe: Token.textColor(.green)
        case .review: Token.textColor(.orange)
        case .danger: Token.textColor(.red)
        case .positiveOutline: Token.textColor(.green).opacity(0.8)
        }
    }

    private var background: Color {
        switch style {
        case .neutral: Token.Fill.control
        case .safe: Token.Fill.safeBadge
        case .review: Token.color(.orange).opacity(0.16)
        case .danger: Token.color(.red).opacity(0.16)
        case .positiveOutline: .clear
        }
    }
}

// MARK: - Button styles

/// A sidebar row: the label, and nothing else.
///
/// `.buttonStyle(.plain)` fades its label while the mouse is held down. No Mac source
/// list does that — press a row in Finder and the only thing that moves is the
/// selection. The moving pill is the whole feedback here, so this style reads
/// `configuration.isPressed` nowhere.
///
/// The row's other half of the fix lives at the call site: the selection is made on
/// mouse *down*, because a `Button` alone acts on mouse up and the delay reads as lag.
struct SidebarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// A compact action for controls inside cards and rows.
struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mcControlLabel)
            .foregroundStyle(isEnabled ? Token.Text.primary : Token.Text.disabled)
            .padding(.horizontal, 12)
            .frame(minHeight: 28)
            .background(
                isEnabled ? (isHovering ? Token.Fill.buttonHover : Token.Fill.button) : Token.Fill.controlDisabled,
                in: Capsule()
            )
            .overlay {
                Capsule().strokeBorder(isEnabled ? Token.Fill.buttonBorder : .clear, lineWidth: Token.hairline)
            }
            .contentShape(Capsule())
            .opacity(isEnabled && configuration.isPressed ? 0.8 : 1)
            .onHover { isHovering = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
    }
}

/// Destructive button — red at low alpha with a tinted label, per the design's
/// Empty Trash and Reset controls.
struct DestructiveButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.mcControlLabel.weight(.medium))
            .foregroundStyle(isEnabled ? Token.Text.destructive : Token.Text.disabled)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(
                isEnabled ? Token.color(.red).opacity(isHovering ? 0.26 : 0.16) : Token.Fill.controlDisabled,
                in: RoundedRectangle(cornerRadius: Token.Radius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Token.Radius.control)
                    .strokeBorder(isEnabled ? Token.color(.red).opacity(0.40) : .clear, lineWidth: Token.hairline)
            )
            .brightness(isEnabled && configuration.isPressed ? -0.05 : 0)
            .onHover { isHovering = isEnabled && $0 }
    }
}

/// A row in the menu bar popover, highlighted the way a real `NSMenu` item is: the
/// whole row fills with the system selection blue under the pointer and the label
/// turns white.
///
/// `.buttonStyle(.plain)` gave the popover no hover state at all — the only feedback
/// was the label fading on mouse-down, which no menu on this platform does. The fill
/// is painted for a press as well as a hover, since a click that lands without the
/// pointer having moved (keyboard-driven, or a very fast click) still deserves one.
///
/// Disabled is handled here rather than left to the style's default: the fill must not
/// follow the pointer over "Scan for Junk" while a scan is already running, and a
/// hover recorded before the button was disabled must not survive into that state.
struct MenuItemButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = isEnabled && (isHovering || configuration.isPressed)
        return configuration.label
            // 13 pt, the size AppKit draws a menu item at — not the app's 12 pt
            // control label, because this reads as a menu and not as a control.
            .font(.mcRowTitleRegular)
            .foregroundStyle(
                highlighted ? Token.Text.onHighlight
                    : (isEnabled ? Token.Text.primary : Token.Text.disabled)
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(
                highlighted ? Token.Fill.menuHighlight : .clear,
                in: RoundedRectangle(cornerRadius: Token.Radius.control)
            )
            // The label alone is a narrow target; a menu row answers anywhere along
            // its width, so the shape the hover and the click use is the filled one.
            .contentShape(RoundedRectangle(cornerRadius: Token.Radius.control))
            .onHover { isHovering = isEnabled && $0 }
    }
}

// MARK: - Hover tip

/// The capacity bar's immediate tooltip, as a reusable chip. The native `.help()`
/// waits out a dwell delay and only fires on the key window; a bar the user is
/// already pointing at should answer at once.
struct HoverTip: View {
    var color: ColorToken?
    let primary: String
    var secondary: String?

    var body: some View {
        HStack(spacing: 7) {
            if let color { CategoryDot(color: color, size: 8) }
            Text(primary)
                .font(.mcRowTitle)
                .foregroundStyle(Token.Text.primary)
            if let secondary {
                Text(secondary)
                    .font(.mcRowValue)
                    .foregroundStyle(Token.Text.secondary)
            }
        }
        .fixedSize()
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        // A card, not a material: it floats over the page, and every other
        // surface in the app is now a colour of its own rather than a wash of
        // whatever is behind the window.
        .background(Token.Fill.box, in: RoundedRectangle(cornerRadius: Token.Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Token.Radius.control)
                .strokeBorder(Token.Fill.boxBorder, lineWidth: Token.hairline)
        )
        .shadow(color: Token.chipShadow, radius: 8, y: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Find field

/// The search field a list's header carries, and the receiving end of Edit › Find.
///
/// In the page header and not `.searchable`: the toolbar's principal item is already
/// the scan readout, and the Uninstaller's field set the precedent of sitting beside
/// the list it narrows. `findRequest` is `AppModel.findRequest`; every change to it
/// takes the focus, so ⌘F works again after the user has clicked away. Escape clears
/// the query first and gives up the focus second, as a search field in Finder does.
struct FindField: View {
    @Binding var text: String
    let findRequest: Int
    var prompt = "Search"

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(prompt, text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onChange(of: findRequest) { isFocused = true }
            .onExitCommand {
                if text.isEmpty { isFocused = false } else { text = "" }
            }
    }
}

// MARK: - Sortable column header

/// A sortable header with a button that covers the full cell.
/// The arrow appears only on the active column.
/// The surrounding row supplies the text style.
struct SortableColumnHeader: View {
    let title: String
    let isActive: Bool
    let ascending: Bool
    var alignment: Alignment = .leading
    var verticalPadding: CGFloat = 10
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if isActive {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .padding(.vertical, verticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isActive ? "Reverse the sort order" : "Sort by \(title.lowercased())")
    }
}

// MARK: - Rows

/// Keeps preview clicks separate from single-click actions.
struct PreviewClickTarget: NSViewRepresentable {
    let onClick: () -> Void
    let onPreview: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> ClickView {
        let view = ClickView()
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.isEnabled = isEnabled
        nsView.onClick = onClick
        nsView.onPreview = onPreview
    }

    final class ClickView: NSView {
        var isEnabled = true
        var onClick: (() -> Void)?
        var onPreview: (() -> Void)?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard isEnabled else { return }
            if event.clickCount == 1 { onClick?() }
            else if event.clickCount == 2 { onPreview?() }
        }
    }
}

/// Applies the design's hover fill to a list row.
struct HoverHighlight: ViewModifier {
    var radius: CGFloat = 0
    var fill: Color = Token.Fill.rowHover
    var restingFill: Color = .clear
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .background(
                isHovering ? fill : restingFill,
                in: RoundedRectangle(cornerRadius: radius)
            )
            .onHover { isHovering = $0 }
    }
}

extension View {
    func hoverHighlight(
        radius: CGFloat = 0,
        fill: Color = Token.Fill.rowHover,
        restingFill: Color = .clear
    ) -> some View {
        modifier(HoverHighlight(radius: radius, fill: fill, restingFill: restingFill))
    }

    /// Uppercased, tracked, quaternary — eyebrows and column headers.
    func mcEyebrowStyle(tracking: CGFloat = 0.055 * 11) -> some View {
        self.font(.mcEyebrow)
            .tracking(tracking)
            .textCase(.uppercase)
            .foregroundStyle(Token.Text.quaternary)
    }
}


// MARK: - Page header

/// The strip directly under the toolbar, on every view that has one.
///
/// It exists because each view had grown its own. Side padding was 18 in the Trash
/// and History, 16 in the Uninstaller and 14 in the Storage Explorer, while the
/// rows under every one of them are inset by 14 — so a header's own title sat out
/// of line with what it described, and no two views agreed on where the page
/// begins. The Scanner's scrolled away with the list, which is a fourth answer.
///
/// Pinned, never scrolling: three views put their search field here and four put
/// their selection controls here, and a control that scrolls out of reach is worse
/// than one that costs a little room.
struct PageHeader<Leading: View, Trailing: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 10) {
            leading
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, Token.Size.pageGutter)
        .padding(.vertical, 10)
        // A minimum rather than a fixed height: the Trash's header carries figures
        // at hero weight and is allowed to be taller than a line of caption text.
        .frame(minHeight: Token.Size.pageHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Token.separator)
                .frame(height: Token.hairline)
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(@ViewBuilder leading: () -> Leading) {
        self.init(leading: leading, trailing: { EmptyView() })
    }
}

extension View {
    /// The ordinary left-hand line of a page header: what this page is showing,
    /// in one line, in the quiet tone.
    func pageHeaderSummary() -> some View {
        font(.mcControlLabel)
            .foregroundStyle(Token.Text.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

extension View {
    /// The inset every toolbar button's label carries.
    ///
    /// Shared because Scan and Remove sit next to each other: one of them had it
    /// and the other did not, which made the pair differ in both width and height
    /// for no reason a reader could see.
    func toolbarButtonLabel() -> some View {
        font(.system(size: 14, weight: .medium))
            .padding(.vertical, 5)
            .padding(.horizontal, 8)
    }
}

// MARK: - Window shell

/// Keeps the sidebar opaque so the wallpaper cannot change its color.
struct SidebarBackground: View {
    var body: some View {
        Token.sidebar
            .accessibilityHidden(true)
    }
}

/// Uses native title bar layout to align the window controls with the header.
/// Native title bar dragging and WindowDragHandle keep empty header space movable.
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> ChromeView { ChromeView() }
    func updateNSView(_ nsView: ChromeView, context: Context) {}

    final class ChromeView: NSView {
        private static let toolbarIdentifier = NSToolbar.Identifier("MoppoWindowChrome")
        private weak var configured: NSWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, configured !== window else { return }
            configured = window
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovable = true
            window.isMovableByWindowBackground = false
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
            // The empty toolbar gives AppKit control of button placement during resizing and full-screen transitions.
            if window.toolbar?.identifier != Self.toolbarIdentifier {
                let toolbar = NSToolbar(identifier: Self.toolbarIdentifier)
                // Icon-only mode keeps the native title bar within the header band.
                toolbar.displayMode = .iconOnly
                toolbar.allowsUserCustomization = false
                toolbar.allowsDisplayModeCustomization = false
                window.toolbar = toolbar
            }
        }
    }
}

/// Moves the window on drag and zooms it on a double-click.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            if event.clickCount == 2 {
                window.performZoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// Uses the same action size and response across pages.
struct PageActionButtonStyle: ButtonStyle {
    enum Size {
        case regular, small, compact

        var fontSize: CGFloat {
            switch self {
            case .regular: 14
            case .small: 13
            case .compact: 12
            }
        }

        var horizontalPadding: CGFloat {
            switch self {
            case .regular: 20
            case .small: 13
            case .compact: 12
            }
        }

        var height: CGFloat {
            switch self {
            case .regular: 38
            case .small: Token.Size.tabControl
            case .compact: 28
            }
        }
    }

    var tint: Color? = nil
    var size: Size = .regular
    var foreground: Color? = nil
    var fill: Color = Token.Fill.button
    var border: Color = Token.Fill.buttonBorder
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.modifier(PageActionSurface(
            tint: tint, size: size, isPressed: configuration.isPressed,
            foreground: foreground, fill: fill, border: border
        ))
    }
}

/// Gives buttons and menus the same size, colors, and hover response.
struct PageActionSurface: ViewModifier {
    var tint: Color? = nil
    var size: PageActionButtonStyle.Size = .regular
    var isPressed = false
    var foreground: Color? = nil
    var fill: Color = Token.Fill.button
    var border: Color = Token.Fill.buttonBorder
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .font(.system(size: size.fontSize, weight: .medium))
            .padding(.horizontal, size.horizontalPadding)
            .frame(minHeight: size.height)
            .foregroundStyle(isEnabled ? (foreground ?? (tint == nil ? Token.Text.primary : Color.white)) : Token.Text.disabled)
            .background(isEnabled ? (tint ?? (isHovering ? Token.Fill.buttonHover : fill)) : Token.Fill.controlDisabled, in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isEnabled && tint == nil ? border : .clear,
                    lineWidth: Token.hairline
                )
            }
            .contentShape(Capsule())
            .opacity(isEnabled && isPressed ? 0.8 : 1)
            .onHover { isHovering = isEnabled && $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isEnabled)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: isPressed)
    }
}

/// Switches between related views without animating the page content.
struct PageSegmentedControl<Selection: Hashable>: View {
    struct Segment: Identifiable {
        let id: Selection
        let title: String
        let symbol: String
        var detail: String? = nil
        var tint: Tint = .blue
    }

    enum Tint {
        case blue, green, amber

        var fill: Color {
            switch self {
            case .blue: Token.Segments.blueFill
            case .green: Token.Segments.greenFill
            case .amber: Token.Segments.amberFill
            }
        }

        var border: Color {
            switch self {
            case .blue: Token.Segments.blueBorder
            case .green: Token.Segments.greenBorder
            case .amber: Token.Segments.amberBorder
            }
        }

        var foreground: Color {
            switch self {
            case .blue: Token.Segments.blueText
            case .green: Token.textColor(.green)
            case .amber: Token.textColor(.orange)
            }
        }

        var icon: Color {
            switch self {
            case .blue: Token.Segments.blueText
            case .green: Token.color(.green)
            case .amber: Token.color(.orange)
            }
        }
    }

    @Binding var selection: Selection
    let segments: [Segment]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                segmentButton(segment, index: index)
                    .anchorPreference(key: SegmentBoundsKey.self, value: .bounds) { [index: $0] }
            }
        }
        .backgroundPreferenceValue(SegmentBoundsKey.self) { bounds in
            GeometryReader { geometry in
                if let index = segments.firstIndex(where: { $0.id == selection }), let anchor = bounds[index] {
                    let rect = geometry[anchor]
                    let tint = segments[index].tint
                    RoundedRectangle(cornerRadius: 7)
                        .fill(tint.fill)
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tint.border, lineWidth: 1))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: selection)
                }
            }
            .allowsHitTesting(false)
        }
        .padding(2)
        .background(Token.Segments.track, in: RoundedRectangle(cornerRadius: 9))
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityElement(children: .contain)
    }

    private func segmentButton(_ segment: Segment, index: Int) -> some View {
        let selected = segment.id == selection
        return Button { selection = segment.id } label: {
            HStack(spacing: 6) {
                Image(systemName: segment.symbol)
                    .foregroundStyle(segment.tint == .blue && !selected ? Token.Text.secondary : segment.tint.icon)
                    .accessibilityHidden(true)
                Text(segment.title)
                    .foregroundStyle(selected ? segment.tint.foreground : Token.Text.primary)
                if let detail = segment.detail {
                    Text(detail)
                        .monospacedDigit()
                        .foregroundStyle(Token.Text.secondary)
                }
            }
            .font(.mcControlLabel)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: Token.Size.tabControl - 4)
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        .help("\(segment.title) (⌘\(index + 1))")
        .accessibilityLabel(segment.title)
        .accessibilityValue(segment.detail ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SegmentBoundsKey: PreferenceKey {
    static let defaultValue: [Int: Anchor<CGRect>] = [:]

    static func reduce(value: inout [Int: Anchor<CGRect>], nextValue: () -> [Int: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Keeps operation progress visible for one second. Cancellation ends the wait immediately.
struct OperationPresentationDuration: Sendable {
    private var deadline = ContinuousClock.now.advanced(by: .seconds(1))

    /// Keeps a deletion on screen until Moppo finishes the first pass of its rays.
    /// Call it when the progress appears. With Reduce Motion on, nothing changes because Moppo does not move.
    @MainActor mutating func extend(toShow icon: PageProgressView.Icon) {
        guard case .mascot(let mode) = icon, let pass = mode.firstPassDuration,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        else { return }
        deadline = max(deadline, ContinuousClock.now.advanced(by: pass))
    }

    func wait() async throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { return }
        try await ContinuousClock().sleep(until: deadline)
    }
}

/// Confirms a stop request in buttons and status controls.
struct ScanInterruptionView: View {
    static let title = "Interrupting Scan"

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(Self.title)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.title)
    }
}

/// Shows progress in the content area with an optional stop action.
struct PageProgressView: View {
    enum Icon {
        case hourglass
        case mascot(MoppoMascotView.Mode)

        /// Moppo destroys only very large deletions, as a rare surprise. Other deletions keep the hourglass.
        static func deletion(bytes: Int64) -> Icon {
            bytes > 5 * ByteFormatting.bytesPerGB ? .mascot(.destroying) : .hourglass
        }
    }

    let title: String
    var detail: String? = nil
    var progress: Double? = nil
    var isInterrupting = false
    var icon: Icon = .hourglass
    var onStop: (() -> Void)? = nil

    private var displayedTitle: String { isInterrupting ? ScanInterruptionView.title : title }

    var body: some View {
        PageStateLayout(title: displayedTitle) {
            switch icon {
            case .hourglass: PageStateSymbol(name: "hourglass")
            case .mascot(let mode):
                MoppoMascotView(mode: mode)
                    .frame(width: PageStateMetrics.iconAreaSize, height: PageStateMetrics.iconAreaSize)
            }
        } detail: {
            VStack(spacing: 18) {
                if let detail {
                    Text(detail)
                        .opacity(isInterrupting ? 0 : 1)
                        .accessibilityHidden(isInterrupting)
                }
                OperationProgressBar(progress: isInterrupting ? nil : progress)
                    .accessibilityLabel(displayedTitle)
            }
            .frame(maxWidth: .infinity)
        } actions: {
            if let onStop {
                Button(action: onStop) { Label("Stop", systemImage: "stop.fill") }
                    .disabled(isInterrupting)
            }
        }
    }
}

/// Reveals results after work ends without replaying on page navigation.
private struct OperationResultAnimation: ViewModifier {
    let isRunning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = true

    func body(content: Content) -> some View {
        content
            .opacity(isRunning || isVisible ? 1 : 0)
            .offset(y: isRunning || isVisible || reduceMotion ? 0 : 6)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24), value: isVisible)
            .task(id: isRunning) {
                if isRunning { isVisible = false; return }
                guard !isVisible else { return }
                if !reduceMotion {
                    do { try await Task.sleep(for: .milliseconds(30)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                isVisible = true
            }
            .onDisappear { isVisible = true }
    }
}

extension View {
    func operationResultAnimation(isRunning: Bool) -> some View {
        modifier(OperationResultAnimation(isRunning: isRunning))
    }
}

/// Animates changing totals without moving the surrounding layout.
private struct AnimatedTotal<Value: Equatable>: ViewModifier {
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: value)
    }
}

extension View {
    func animatedTotal<Value: Equatable>(_ value: Value) -> some View {
        modifier(AnimatedTotal(value: value))
    }
}

/// Shows a completed scan with no matching items.
struct ScanCompletionView: View {
    let title: String
    var detail: String? = nil
    var animate = false

    var body: some View {
        PageCompletionView(title: title, animate: animate) {
            if let detail { Text(detail) }
        } actions: {
            EmptyView()
        }
    }
}

struct CompletionMark: View {
    var animate = true
    var isSuccess = true
    var size: CGFloat = 60
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size / 4)
                .fill(Token.color(isSuccess ? .green : .orange).opacity(0.12))
            RoundedRectangle(cornerRadius: size / 4)
                .strokeBorder(Token.textColor(isSuccess ? .green : .orange).opacity(0.3), lineWidth: 1)
            if isSuccess {
                CheckmarkStroke()
                    .trim(from: 0, to: drawn || !animate ? 1 : 0)
                    .stroke(Token.textColor(.green), style: StrokeStyle(lineWidth: size / 20, lineCap: .round, lineJoin: .round))
                    .padding(size * 14 / 60)
            } else {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: size * 26 / 60, weight: .medium))
                    .foregroundStyle(Token.textColor(.orange))
            }
        }
        .frame(width: size, height: size)
        .scaleEffect(drawn || !animate || reduceMotion ? 1 : 0.94)
        .opacity(drawn || !animate ? 1 : 0)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: drawn)
        .task(id: animate) {
            guard animate else { return }
            if !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(30)) }
                catch { return }
            }
            drawn = true
        }
        .accessibilityHidden(true)
    }
}

private struct CheckmarkStroke: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.4, y: rect.minY + rect.height * 0.75))
            path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.88, y: rect.minY + rect.height * 0.22))
        }
    }
}
