import SwiftUI
import MoppoCore

/// Design tokens.
///
/// The handoff is explicit that platform semantics beat its literals: "prefer the
/// platform's semantic colors (`NSColor.controlAccentColor`, `.systemGreen`,
/// `.separatorColor`, `.quaternaryLabelColor`) over these literals where an
/// equivalent exists, so the app follows the user's accent choice and Increase
/// Contrast setting."
///
/// So almost everything here resolves to a system colour, and those adapt to the
/// user's appearance for free. What is left is a short list of literals with no
/// AppKit equivalent. Each of those now carries a pair: the design's authored dark
/// value, and a light value derived from it. The design was drawn dark and light is
/// read off it; the system decides which one the user sees.
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
        case .green:     Color(nsColor: .systemGreen)
        case .orange:    Color(nsColor: .systemOrange)
        case .red:       Color(nsColor: .systemRed)
        case .yellow:    Color(nsColor: .systemYellow)
        case .purple:    Color(nsColor: .systemPurple)
        case .teal:      Color(nsColor: .systemTeal)
        case .pink:      Color(nsColor: .systemPink)
        case .brown:     Color(nsColor: .systemBrown)
        case .gray:      Color(nsColor: .systemGray)

        // No AppKit equivalent for these three — kept as design literals, so they are
        // also the only category colours that need a light value drawn by hand.
        //
        // All three share a track with `systemGray`, which is #8E8E93 in light and
        // #98989D in dark, so the light values are chosen for separation from it as
        // much as for fidelity to the dark ones.

        // System Data. Warm taupe, and in light it has to go darker than `systemGray`
        // rather than lighter: the two sit next to each other at the head of the bar.
        case .warmGray:  dynamic(
            light: NSColor(srgbRed: 0.435, green: 0.392, blue: 0.333, alpha: 1),  // #6F6455
            dark:  NSColor(srgbRed: 0.557, green: 0.522, blue: 0.467, alpha: 1)   // #8E8577
        )

        // Unmeasured. The honest residual, so it stays quiet — which in dark means
        // near the background and in light means a mid grey, not a dark one. It has
        // to stay legible between `Other` (`systemGray`) on one side and `Free` on
        // the other, and #9E9E9E was too close to `systemGray` light to tell apart,
        // so it sits a little above the midpoint of that pair.
        case .darkGray:  dynamic(
            light: NSColor(srgbRed: 0.659, green: 0.659, blue: 0.678, alpha: 1),  // #A8A8AD
            dark:  NSColor(srgbRed: 0.290, green: 0.290, blue: 0.306, alpha: 1)   // #4A4A4E
        )

        // Free. A tint of the surface either way, since empty space should read as
        // the track rather than as another category.
        case .freeSpace: ink(light: 0.10, dark: 0.14)
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
            light: NSColor(srgbRed: 0.078, green: 0.404, blue: 0.165, alpha: 1),  // #14672A
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

    /// The text ramp.
    ///
    /// The top two steps use AppKit semantics, which match the design closely and
    /// respond to Increase Contrast. The bottom two do not: AppKit's
    /// `tertiaryLabelColor` and `quaternaryLabelColor` sit near 0.25 and 0.10 alpha,
    /// well below the design's 0.42 and 0.34, and on a dark translucent surface they
    /// were genuinely hard to read — eyebrows, tile descriptions and the status bar
    /// all disappeared. Those two are explicit values, set slightly brighter than the
    /// design's own, since the prototype was measured against an opaque mock rather
    /// than live window glass.
    ///
    /// Light inherits the argument, not the numbers. AppKit's light ramp is black at
    /// 0.50, 0.26 and 0.10 for the bottom three steps, so the two that were the
    /// problem in dark are again set well clear of the platform's. The pairs are not
    /// mirrored — equal alphas do not read as equal weight — so each side is set
    /// against its own surface.
    enum Text {
        static let primary = Color(nsColor: .labelColor)
        static let secondary = Token.ink(light: 0.60, dark: 0.62)
        static let tertiary = Token.ink(light: 0.55, dark: 0.52)
        static let quaternary = Token.ink(light: 0.48, dark: 0.44)
        static let disabled = Token.ink(light: 0.34, dark: 0.34)
        /// The one hero number per view. A step past `labelColor`, which is 0.85 in
        /// both modes.
        static let emphasis = Token.ink(light: 0.92, dark: 0.96)

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

    /// The content area behind everything else.
    ///
    /// Light paints the System Settings grey so that white cards stand off the
    /// page; the detail pane's own background is white there, which left them
    /// invisible.
    static let pageBackground = Token.dynamic(
        light: NSColor(srgbRed: 0.949, green: 0.949, blue: 0.957, alpha: 1),  // #F2F2F4
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
    static let sidebarTop = Token.dynamic(
        light: NSColor(white: 0.96, alpha: 1),
        dark: NSColor(white: 28 / 255, alpha: 1)  // #1C1C1C
    )
    static let sidebarBottom = Token.dynamic(
        light: NSColor(white: 0.91, alpha: 1),
        dark: NSColor(white: 18 / 255, alpha: 1)  // #121212
    )

    /// The surface for onboarding and popovers.
    static let chrome = Token.dynamic(
        light: NSColor.windowBackgroundColor,
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
        /// Shared card color. Dark mode matches the expanded Cleanup file lists.
        static let box = Token.dynamic(
            light: .white.withAlphaComponent(0.85),
            dark: NSColor(white: 23 / 255, alpha: 1)  // #171717
        )
        /// Also the row rule in every table and the capacity bar's track. Deliberately
        /// weaker than `separatorColor`, which is roughly 0.10 in light: repeated every
        /// 38pt down a table, the system separator draws a grid rather than a hint.
        static let boxBorder = Token.ink(light: 0.06, dark: 0.07)
        /// The specular top edge on a secondary button. In light there is no specular
        /// edge to draw, so it becomes the outline that makes the control look raised,
        /// and it needs more weight than the box hairline to do that.
        static let controlBorder = Token.ink(light: 0.13, dark: 0.10)
        /// An inset surface for file lists, callouts, and exclusions.
        static let well = Token.dynamic(
            light: .black.withAlphaComponent(0.04),
            dark: NSColor(white: 23 / 255, alpha: 1)  // #171717
        )
        static let control = Token.ink(light: 0.07, dark: 0.09)
        /// Disabled controls have less contrast than active controls.
        static let controlDisabled = Token.ink(light: 0.035, dark: 0.04)
        /// Hover darkens the control in light and lightens it in dark. Same gesture,
        /// opposite direction, which is what `ink` already does.
        static let controlHover = Token.ink(light: 0.12, dark: 0.14)
        static let rowHover = Token.ink(light: 0.04, dark: 0.03)
        /// A neutral selection fill over the sidebar gradient.
        static let sidebarSelection = Token.ink(light: 0.09, dark: 0.12)

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
        static let sidebarCapacityBar: CGFloat = 5
        /// The design's window size. Resizable; the sidebar stays fixed.
        static let windowWidth: CGFloat = 1268
        static let windowHeight: CGFloat = 734
        /// Below roughly this, the tables crowd.
        static let minimumContentWidth: CGFloat = 760
    }

    /// Hairlines are 0.5px in the design — one physical pixel on a Retina display.
    static var hairline: CGFloat { 1 / (NSScreen.main?.backingScaleFactor ?? 2) }
}
