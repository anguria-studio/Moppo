import SwiftUI
import MoppoCore

/// Shared colors and layout values.
/// Light mode uses neutral surfaces and blue-gray text. Dark mode keeps its neutral palette.
enum Token {

    // MARK: - Appearance

    /// A colour that answers differently in each appearance.
    ///
    /// `Color(nsColor:)` preserves an `NSColor`'s dynamism, so one token can hold both
    /// values and no view has to know which mode it is drawing in.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    /// The shape almost every literal below takes: the same mark in the opposite ink.
    /// White at some alpha over dark, black at some alpha over light.
    ///
    /// The two alphas are paired, not shared. Equal alphas do not read as equal
    /// weight, so each side is set against the surface it actually lands on.
    static func ink(light: CGFloat, dark: CGFloat) -> Color {
        dynamic(
            light: .black.withAlphaComponent(light),
            dark: .white.withAlphaComponent(dark)
        )
    }

    // MARK: - Category colours

    static func color(_ token: ColorToken) -> Color {
        switch token {
        // Follows the user's accent selection in System Settings.
        case .accent:    Color(nsColor: .controlAccentColor)
        case .green:     dynamic(light: NSColor(srgbRed: 0.207, green: 0.780, blue: 0.349, alpha: 1), dark: .systemGreen)
        case .orange:    dynamic(light: NSColor(srgbRed: 1, green: 0.620, blue: 0.180, alpha: 1), dark: .systemOrange)
        case .red:       Color(nsColor: .systemRed)
        case .yellow:    Color(nsColor: .systemYellow)
        case .purple:    dynamic(light: NSColor(srgbRed: 0.655, green: 0.365, blue: 0.980, alpha: 1), dark: .systemPurple)
        case .indigo:    Color(nsColor: .systemIndigo)
        case .teal:      dynamic(light: NSColor(srgbRed: 0.220, green: 0.741, blue: 0.973, alpha: 1), dark: .systemTeal)
        case .pink:      dynamic(light: NSColor(srgbRed: 1, green: 0.325, blue: 0.533, alpha: 1), dark: .systemPink)
        case .brown:     Color(nsColor: .systemBrown)
        case .gray:      dynamic(light: NSColor(srgbRed: 0.631, green: 0.659, blue: 0.859, alpha: 1), dark: .systemGray)

        // System Data uses slate in light mode and taupe in dark mode.
        case .warmGray:  dynamic(
            light: NSColor(srgbRed: 0.278, green: 0.333, blue: 0.412, alpha: 1),  // #475569
            dark:  NSColor(srgbRed: 0.557, green: 0.522, blue: 0.467, alpha: 1)   // #8E8577
        )

        // Unmeasured stays distinct from the system category and free space.
        case .darkGray:  dynamic(
            light: NSColor(srgbRed: 0.580, green: 0.639, blue: 0.722, alpha: 1),  // #94A3B8
            dark:  NSColor(srgbRed: 0.290, green: 0.290, blue: 0.306, alpha: 1)   // #4A4A4E
        )

        // Free. A tint of the surface either way, since empty space should read as
        // the track rather than as another category.
        case .freeSpace: dynamic(
            light: NSColor(srgbRed: 0.886, green: 0.910, blue: 0.941, alpha: 1),
            dark: .white.withAlphaComponent(0.14)
        )
        }
    }

    /// The same palette, for a colour that has to be *read* rather than filled.
    ///
    /// The system colours are tuned to be filled. `systemGreen` on light paper is
    /// about 1.6:1 and `systemOrange` about 1.9:1 — figures you can see but not read,
    /// which is fine for a 9pt dot and not fine for the free-space total or a badge.
    /// Dark does not have the problem, since the same colours sit against a dark
    /// surface, so this hands back the system colour there and a darkened shade of the
    /// same hue in light.
    ///
    /// Shapes keep `color(_:)`. Dots, bars, capsule fills and the capacity bar are
    /// what the system palette is for, and swapping them would break the match between
    /// a legend dot and its segment.
    static func textColor(_ token: ColorToken) -> Color {
        switch token {
        case .green:  dynamic(
            light: NSColor(srgbRed: 0.086, green: 0.478, blue: 0.184, alpha: 1),  // #167A2F
            dark: .systemGreen
        )
        case .orange: dynamic(
            light: NSColor(srgbRed: 0.604, green: 0.325, blue: 0.000, alpha: 1),  // #9A5300
            dark: .systemOrange
        )
        case .red:    dynamic(light: redInk, dark: .systemRed)
        // Accent stays the accent. A label in the user's chosen colour is what the
        // sidebar and the selection readout are saying, and macOS draws those the same
        // way at the same contrast.
        default:      color(token)
        }
    }

    /// One dark red for light mode, shared by `textColor(.red)` and the destructive
    /// control's label so the app has a single red to read.
    fileprivate static let redInk = NSColor(srgbRed: 0.702, green: 0.149, blue: 0.118, alpha: 1)  // #B3261E

    // MARK: - Text.

    /// Blue-gray text in light mode and neutral text in dark mode.
    enum Text {
        /// Table names stay distinct from the softer metadata columns.
        static let tableName = Token.dynamic(
            light: NSColor(white: 0.20, alpha: 1), dark: .labelColor
        )
        static let tableDetail = Token.dynamic(
            light: NSColor(white: 0.50, alpha: 1), dark: .white.withAlphaComponent(0.62)
        )
        static let tablePath = Token.dynamic(
            light: NSColor(white: 0.50, alpha: 1), dark: .white.withAlphaComponent(0.52)
        )
        static let tableSize = Token.dynamic(
            light: NSColor(white: 0.50, alpha: 1), dark: .labelColor
        )
        static let primary = Token.dynamic(
            light: NSColor(srgbRed: 0.090, green: 0.125, blue: 0.200, alpha: 1), dark: .labelColor
        )
        static let secondary = Token.dynamic(
            light: NSColor(srgbRed: 0.278, green: 0.333, blue: 0.412, alpha: 1), dark: .white.withAlphaComponent(0.62)
        )
        static let tertiary = Token.dynamic(
            light: NSColor(srgbRed: 0.365, green: 0.424, blue: 0.522, alpha: 1), dark: .white.withAlphaComponent(0.52)
        )
        static let quaternary = Token.dynamic(
            light: NSColor(srgbRed: 0.459, green: 0.506, blue: 0.592, alpha: 1), dark: .white.withAlphaComponent(0.44)
        )
        static let disabled = Token.dynamic(
            light: NSColor(srgbRed: 0.580, green: 0.639, blue: 0.722, alpha: 1), dark: .white.withAlphaComponent(0.34)
        )
        /// The one hero number per view. A step past `labelColor`, which is 0.85 in
        /// both modes.
        static let emphasis = Token.dynamic(
            light: NSColor(srgbRed: 0.059, green: 0.090, blue: 0.165, alpha: 1), dark: .white.withAlphaComponent(0.96)
        )
        static let duplicateAvailableStorage = Token.dynamic(
            light: NSColor(srgbRed: 0.839, green: 0.373, blue: 0, alpha: 1), dark: .labelColor
        )

        /// The destructive control's label, on its own red-tinted fill.
        ///
        /// `systemRed` itself cannot do this job in either mode: it is too dark to
        /// carry a label on the dark tint and too light to carry one on the light
        /// tint. So the label gets a shade of red per appearance instead — the dark
        /// one is the design's #FF7A70, the light one the same red every other red
        /// label uses.
        static let destructive = Token.dynamic(
            light: Token.redInk,
            dark: NSColor(srgbRed: 1.000, green: 0.478, blue: 0.439, alpha: 1)   // #FF7A70
        )

        /// A label sitting on a highlighted menu row. `selectedMenuItemTextColor`
        /// is the one AppKit token that tracks the highlight fill: it is white
        /// while a row is filled and reverts if the system ever draws that fill
        /// lighter, which is more than a white literal would do.
        static let onHighlight = Color(nsColor: .selectedMenuItemTextColor)
    }

    static let separator = Color(nsColor: .separatorColor)

    // MARK: - Surfaces
    //
    // Three authored darks, one per depth: the page, the surfaces grouped on it,
    // and the cards standing off those.
    //
    // **Neutral, and deliberately so.** The first set of three carried a blue
    // channel raised above the other two — #18181D is (24, 24, 29), #202026 is
    // (32, 32, 38), #282830 is (40, 40, 48) — and five to eight points on one
    // channel is enough to read as a purple cast across a whole window. The greys
    // are equal now, and the scale sits nine or so points lower, nearer black.
    // Each step is eight, which is what separates a surface from the one above it. They are opaque on purpose. The previous
    // dark canvas was measured off the App Store and the surfaces above it were
    // white at low alpha, which meant every one of them took a wash of whatever
    // wallpaper the window sat over — the Storage Explorer's table made that
    // visible enough to report, and it was true of every card in the app.
    //
    // Light keeps its own scheme. These three values are authored for dark.

    /// The white light canvas separates gray cards from the page.
    static let pageBackground = Token.dynamic(
        light: .white,  // #FFFFFF
        dark: NSColor(white: 14 / 255, alpha: 1)  // #0E0E0E
    )

    /// The shell: one continuous surface under the whole window, title-bar area
    /// included, and the colour of every gutter the panels do not cover.
    ///
    /// The same value as `pageBackground`, and a separate name because they are
    /// separate responsibilities — the shell is what shows through the gaps, the
    /// page is what the content scrolls on. They are free to part company.
    static let shell = pageBackground

    /// The opaque sidebar stays slightly lighter than the page in dark mode.
    static let sidebar = Token.dynamic(
        light: NSColor(white: 236 / 255, alpha: 1),  // #ECECEC
        dark: NSColor(white: 23 / 255, alpha: 1)  // #171717
    )

    /// The surface for onboarding and popovers.
    static let chrome = Token.dynamic(
        light: NSColor(white: 250 / 255, alpha: 1),
        dark: NSColor(white: 23 / 255, alpha: 1)  // #171717
    )

    // MARK: - Fills
    //
    // Low-alpha tints with no AppKit name. Kept as constants so no view carries a
    // magic number.
    //
    // Dark lifts a surface with white; light seats it with black. The exception is
    // `well`, which is black in both — a recess reads as darker than what surrounds
    // it whichever way round the window is.

    enum Fill {
        static let previewBackdrop = Token.dynamic(
            light: .black.withAlphaComponent(0.12),
            dark: .black.withAlphaComponent(0.28)
        )
        static let groupHeader = Token.dynamic(
            light: NSColor(white: 244 / 255, alpha: 1),
            dark: .clear
        )
        static let cardContent = Token.dynamic(
            light: .white, dark: NSColor(white: 23 / 255, alpha: 1)
        )
        static let safeBadge = Token.dynamic(
            light: NSColor(srgbRed: 0.784, green: 0.937, blue: 0.800, alpha: 1),
            dark: .systemGreen.withAlphaComponent(0.16)
        )
        static let keepIndicator = Token.dynamic(
            light: NSColor(srgbRed: 0.141, green: 0.643, blue: 0.271, alpha: 1),
            dark: .systemGreen
        )
        /// Shared card color. Dark mode matches the expanded Cleanup file lists.
        static let box = Token.dynamic(
            light: NSColor(white: 246 / 255, alpha: 1),
            dark: NSColor(white: 23 / 255, alpha: 1)  // #171717
        )
        static let warning = Token.dynamic(
            light: NSColor(srgbRed: 1.000, green: 0.890, blue: 0.627, alpha: 1),  // #FFE3A0
            dark: .systemOrange.withAlphaComponent(0.10)
        )
        /// Table rules use a faint neutral line.
        static let boxBorder = Token.ink(light: 0.06, dark: 0.07)
        /// Card outlines are slightly stronger than the table rules in light mode.
        static let cardBorder = Token.ink(light: 0.12, dark: 0.07)
        /// The specular top edge on a secondary button. In light there is no specular
        /// edge to draw, so it becomes the outline that makes the control look raised,
        /// and it needs more weight than the box hairline to do that.
        static let controlBorder = Token.ink(light: 0.13, dark: 0.10)
        /// An inset surface for file lists, callouts, and exclusions.
        static let well = Token.dynamic(
            light: NSColor(white: 242 / 255, alpha: 1),
            dark: NSColor(white: 23 / 255, alpha: 1)  // #171717
        )
        static let control = Token.dynamic(
            light: NSColor(white: 240 / 255, alpha: 1), dark: .white.withAlphaComponent(0.09)
        )
        /// Neutral action buttons stay distinct from the page background.
        static let button = Token.dynamic(
            light: NSColor(white: 244 / 255, alpha: 1), dark: .white.withAlphaComponent(0.09)
        )
        static let buttonOnCard = Token.dynamic(
            light: .white, dark: .white.withAlphaComponent(0.09)
        )
        static let buttonHover = Token.dynamic(
            light: NSColor(white: 234 / 255, alpha: 1), dark: .white.withAlphaComponent(0.14)
        )
        static let buttonBorder = Token.dynamic(light: .black.withAlphaComponent(0.07), dark: .clear)
        /// Disabled controls have less contrast than active controls.
        static let controlDisabled = Token.ink(light: 0.035, dark: 0.04)
        /// Hover slightly darkens neutral surfaces in light mode.
        static let controlHover = Token.dynamic(
            light: NSColor(white: 230 / 255, alpha: 1), dark: .white.withAlphaComponent(0.14)
        )
        static let rowSelection = Token.ink(light: 0.14, dark: 0.12)
        static let rowHover = Token.dynamic(
            light: NSColor(white: 249 / 255, alpha: 1), dark: .white.withAlphaComponent(0.03)
        )
        /// Cleanup content is white in light mode.
        static let cleanupRow = Token.dynamic(
            light: .white, dark: .clear
        )
        static let cleanupRowHover = Token.dynamic(
            light: NSColor(white: 249 / 255, alpha: 1), dark: .white.withAlphaComponent(0.03)
        )
        /// The selected sidebar row uses neutral gray in light mode.
        static let sidebarSelection = Token.dynamic(
            light: NSColor(white: 218 / 255, alpha: 1), dark: .white.withAlphaComponent(0.12)
        )

        /// The fill under the pointer in the menu bar popover — the same blue a
        /// real `NSMenu` row takes. `selectedContentBackgroundColor` is that
        /// exact colour and it follows the user's accent choice, so a Mac set to
        /// Graphite gets grey here rather than a blue the rest of the system
        /// stopped using.
        static let menuHighlight = Color(nsColor: .selectedContentBackgroundColor)
    }

    /// The drop shadow under a floating chip — the capacity bar's tooltip and the
    /// proportion bar's. Dark needs a deep shadow to lift the chip off the surface
    /// below it. Light needs a fraction of that, or the chip reads as hovering an
    /// inch above the page.
    static let chipShadow = Token.dynamic(
        light: .black.withAlphaComponent(0.18),
        dark: .black.withAlphaComponent(0.40)
    )

    /// Bright Cleanup filters retain dark text on pastel surfaces in light mode.
    enum CleanupTabs {
        static let all = PageTabPill.LightPalette(
            foreground: Color(red: 0.333, green: 0.180, blue: 0.690),
            selectedBackground: Color(red: 0.843, green: 0.776, blue: 1),
            border: Color(red: 0.690, green: 0.557, blue: 0.910).opacity(0.45)
        )
        static let safe = PageTabPill.LightPalette(
            foreground: Color(red: 0.086, green: 0.392, blue: 0.165),
            selectedBackground: Color(red: 0.725, green: 0.922, blue: 0.757),
            border: Color(red: 0.467, green: 0.792, blue: 0.525).opacity(0.45)
        )
        static let review = PageTabPill.LightPalette(
            foreground: Color(red: 0.471, green: 0.259, blue: 0.016),
            selectedBackground: Color(red: 1, green: 0.847, blue: 0.541),
            border: Color(red: 0.890, green: 0.643, blue: 0.220).opacity(0.45)
        )
    }

    // MARK: - Geometry

    enum Radius {
        static let dot: CGFloat = 2.5
        static let checkbox: CGFloat = 4
        static let control: CGFloat = 6
        static let row: CGFloat = 7
        static let well: CGFloat = 8
        static let box: CGFloat = 10
        static let card: CGFloat = 11
        /// A sidebar navigation row's pill.
        static let sidebarRow: CGFloat = 7
        static let window: CGFloat = 12
    }

    enum Size {
        static let toolbar: CGFloat = 52
        static let sidebarRow: CGFloat = 36
        static let control: CGFloat = 24
        static let tabControl: CGFloat = 32
        /// The side inset every page uses, header and content alike. The headers
        /// had drifted to 18, 16 and 14 while the rows beneath them stayed at 14,
        /// so each title sat out of line with what it described.
        static let pageGutter: CGFloat = 14

        // MARK: Window layout

        /// The header leaves space for the window controls.
        static let headerBand: CGFloat = 52
        /// Navigation keeps a fixed width as the window changes size.
        static let sidebarWidth: CGFloat = 220
        /// Tall enough for the tallest thing a header carries — the Explorer's
        /// 26pt path control — with the 10pt of breathing room above and below.
        static let pageHeader: CGFloat = 46
        static let fileRow: CGFloat = 38
        static let largeFileRow: CGFloat = 36
        static let trashRow: CGFloat = 40
        static let capacityBar: CGFloat = 13
        /// The storage bar stays secondary to the free-space value.
        static let sidebarCapacityBar: CGFloat = 8
        /// The design's window size. Resizable; the sidebar stays fixed.
        static let windowWidth: CGFloat = 1268
        static let windowHeight: CGFloat = 734
        /// Below roughly this, the tables crowd.
        static let minimumContentWidth: CGFloat = 760
    }

    /// Hairlines are 0.5px in the design — one physical pixel on a Retina display.
    static var hairline: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }
}
