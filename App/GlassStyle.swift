// The window's look (dark mode only): colors, motion, cards, the window glass and small controls.
import AppKit
import SwiftUI

/// The single place for macOS 26 feature gates. Call sites still need `if #available(macOS 26, *)` for the
/// compiler; this adds the DEBUG `--force-fallbacks` override on top, so pre-26 paths can be checked on 26+.
enum PlatformFeatures {
    static let forceFallbacks: Bool = {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("--force-fallbacks")
        #else
        return false
        #endif
    }()

    static var liquidGlass: Bool {
        if #available(macOS 26, *) { return !forceFallbacks }
        return false
    }
}

/// The app colors. Histq is dark mode only: each token has one value, made for the dark window.
enum Palette {
    /// The tint over the window's blur (`WindowGlass`). #1C1C1E at 0.6.
    static let windowTint = NSColor(srgbRed: 28 / 255, green: 28 / 255, blue: 30 / 255, alpha: 0.6)
    static let hoverFill = color(.white.withAlphaComponent(0.1))
    static let pressedFill = color(.white.withAlphaComponent(0.2))
    /// The selected sidebar row's capsule and its 1 pt edge: neutral, no accent.
    static let selectedFill = color(.white.withAlphaComponent(0.14))
    static let selectedBorder = color(.white.withAlphaComponent(0.12))
    /// A hovered unselected tab's fill (the selected tab is the sheet's `sheet`), and other faint chips.
    static let tabFill = color(.white.withAlphaComponent(0.06))
    /// The capsule bars of a loading placeholder (`SkeletonLine`), on a `surface` card.
    static let skeletonFill = color(.white.withAlphaComponent(0.10))
    /// Darkens a pressed button over its own fill.
    static let pressedOverlay = color(.black.withAlphaComponent(0.2))
    /// Dims the window behind an open modal or the command palette (`ModalScrim`), over the content's light blur
    /// (`ModalBackdrop`). 0.55: a little darker than the 0.45 before task 9.6, so the card stands out from the blur.
    static let scrim = color(.black.withAlphaComponent(0.55))
    /// Text and glyphs on the blue accent fill: primary buttons, the selected tab (user decision 2026-11-13: white).
    /// The accent (`AccentColor`, the logo's mid blue #2F86FB) holds white at 3.54:1, enough for its pills' labels.
    static let onAccent = color(.white)
    /// The fill of primary buttons (Commit, Save, Keep File): the logo's deep blue, so their white label reads at
    /// 5.82:1 (WCAG AA for body text). Not the accent: #2F86FB under white text is only 3.54:1, enough for the
    /// selected pills, but not for a button's body text. #115CDE
    static let primaryFill = color(srgb(0x115CDE))
    /// The fill of a destructive confirmation's button (Delete Branch, Discard): a deep red, so its white label reads
    /// at 5.9:1 like the primary blue's. #C0282D
    static let destructiveFill = color(srgb(0xC0282D))
    /// The WIP panel's Stage All button: a green, under a white label. #2E9E5B
    static let stageAllFill = color(srgb(0x2E9E5B))
    /// The WIP panel's Discard All and Unstage All buttons: a mid red (between `destructiveFill` and the old light
    /// red #E0706C), under a white label. #D04C4D
    static let wipRedFill = color(srgb(0xD04C4D))
    /// The WIP panel's Conflicted card: its title and icon, and the tint of its fill and edge (`SectionCard.tone`). The
    /// conflict editor's gold. #F2B630
    static let conflictTone = color(srgb(0xF2B630))
    /// A primary button's label shadow: lifts the white text off the blue so it stands out more (user, 2026-11-13).
    static let onPrimaryShadow = Color.black.opacity(0.4)
    static let switchOffFill = color(.white.withAlphaComponent(0.22))
    /// The shadow of the switch's white knob.
    static let knobShadow = Color.black.opacity(0.2)
    /// Cards and panels, a step above the window. #2C2C2E
    static let surface = color(srgb(0x2C2C2E))
    /// bg_card: the outer container of the modals, the palette and the vertical tabs (`PanelContainer`), between the
    /// window and the cards on it, so the three read as separate calm levels (EchoDiar's panels on the window glass).
    /// Opaque like `surface`: one `WindowGlass` per window, no second translucent layer on it. #252527
    static let bgCard = color(srgb(0x252527))
    /// The page's sheet: one container around the selected tab's page (MainView), joined to the selected tab
    /// (`TabSheetShape`): glass like the toolbar's buttons, a light tint over the window glass (#343436 on it). The
    /// tab and the sheet touch without overlapping, so the tint never doubles where they meet. White 0.09
    static let sheet = color(.white.withAlphaComponent(0.09))
    /// The cards on the sheet: a step darker, at 0.9 so the sheet's glass shows a little through them. #232325 at 0.9
    static let sheetCard = color(srgb(0x232325).withAlphaComponent(0.9))
    /// The 1 pt edge of the cards on the sheet: lighter than the sheet around them, so each card stands out. White 0.14
    static let sheetCardBorder = color(.white.withAlphaComponent(0.14))
    /// What a `sheetCard` looks like on the sheet, for AppKit views that must paint opaque inside a card (the graph's
    /// header and hollow nodes, the terminal, a pull request's page). #252527
    static let sheetCardOpaque = srgb(0x252527)
    /// Controls on a card, a step above `surface`. #3A3A3C
    static let inputSurface = color(srgb(0x3A3A3C))
    /// The field of a single-input modal (`.textFieldStyle(.modal)`): darker than the modal's `bgCard`, set into it; also
    /// the track of `CapsuleTabs(compact:)` on a card, so it does not blend into the card's fill. #1A1A1C
    static let modalInput = color(srgb(0x1A1A1C))
    /// The fill behind inline code (a branch name) in a modal's title and message. White 0.1
    static let inlineCodeFill = color(.white.withAlphaComponent(0.1))
    /// The 1 pt edge of cards and panels.
    static let surfaceBorder = color(.white.withAlphaComponent(0.08))
    /// The edge of a raised card: bright at the top, dim on the sides, a faint highlight at the bottom.
    static let raisedRim = LinearGradient(
        stops: [
            .init(color: color(.white.withAlphaComponent(0.24)), location: 0),
            .init(color: color(.white.withAlphaComponent(0.05)), location: 0.45),
            .init(color: color(.white.withAlphaComponent(0.10)), location: 1),
        ],
        startPoint: .top, endPoint: .bottom)
    /// The light at the top of a raised button's fallback capsule.
    static let buttonSheen = LinearGradient(
        colors: [color(.white.withAlphaComponent(0.08)), .clear],
        startPoint: .top, endPoint: .center)
    /// The light at the top of a raised card.
    static let cardSheen = LinearGradient(
        colors: [color(.white.withAlphaComponent(0.05)), .clear],
        startPoint: .top, endPoint: .center)
    /// The shadow under a raised card (radius 6, y 3).
    static let cardShadow = color(.black.withAlphaComponent(0.35))
    /// The shadow under a raised button's fallback capsule (radius 3, y 1.5).
    static let buttonShadow = color(.black.withAlphaComponent(0.35))

    // MARK: Commit graph (AppKit: the graph draws in `draw(_:)`, so these are `NSColor`s)

    /// The 8 lane colors, in palette order (`GraphRow.color`): blue, orange, green, pink, cyan, yellow, lilac, coral.
    /// Lane 0 (the top level) is the brand blue, a touch lighter than the accent so thin lines read; the other hues sit
    /// far from it and from each other (OKLab ΔE ≥ 0.12, also apart under deuteranopia and protanopia), and each
    /// neighbour jumps ~135° in hue so adjacent lanes stay apart. All bright on `surface` #2C2C2E (≥ 4.4:1).
    /// #4091FD #FC9F30 #58CD78 #E8519F #44D4E2 #E9DD3C #C58FF3 #EF6856
    private static let laneValues: [NSColor] = [
        srgb(0x4091FD), srgb(0xFC9F30), srgb(0x58CD78), srgb(0xE8519F),
        srgb(0x44D4E2), srgb(0xE9DD3C), srgb(0xC58FF3), srgb(0xEF6856),
    ]
    /// The graph's lane colors (`GraphLayout.colorCount` of them): lines, nodes, the badge connectors.
    static let graphLanes: [NSColor] = laneValues
    /// The faint band from a node to the graph column's edge: its lane color at 0.09, so the lane lines over it
    /// stay easy to see (user, 2026-11-19).
    static let graphLaneBands: [NSColor] = laneValues.map { $0.withAlphaComponent(0.09) }
    /// The selected row's band: its lane color at 0.28, so the selection reads at a glance (user, 2026-11-19).
    static let graphLaneSelectedBands: [NSColor] = laneValues.map { $0.withAlphaComponent(0.28) }
    /// A stash row's node, band and line to its base, outside the lane colors: a neutral grey. #8E8E93 / at 0.09
    static let graphStash = srgb(0x8E8E93)
    static let graphStashBand = graphStash.withAlphaComponent(0.09)
    static let graphStashSelectedBand = graphStash.withAlphaComponent(0.28)
    /// Another worktree's WIP badge: the grey at a branch badge's 0.38.
    static let graphStashBadgeFill = graphStash.withAlphaComponent(0.38)
    /// A branch badge's fill: its row's lane color at 0.38.
    static let graphBadgeFills: [NSColor] = laneValues.map { $0.withAlphaComponent(0.38) }
    /// The checked-out branch's badge: brighter, its lane color at 0.6.
    static let graphHeadBadgeFills: [NSColor] = laneValues.map { $0.withAlphaComponent(0.6) }
    /// Text and icons on a badge: pure white, so they read on the dark fills (user, 2026-11-17). White
    static let graphBadgeText = NSColor.white
    /// A tag badge's neutral fill. White 0.14
    static let graphTagFill = NSColor.white.withAlphaComponent(0.14)
    /// A branch badge's pull request chip: GitHub's open green, or its draft grey, solid so it reads on any lane fill.
    /// #238636 / #6E7681
    static let graphPullOpenFill = srgb(0x238636)
    static let graphPullDraftFill = srgb(0x6E7681)
    /// The faded ("ghost") badge of the branch a selected commit is on, and its line to the node: drawn whole at this
    /// opacity.
    static let graphGhostAlpha: CGFloat = 0.4
    /// Another worktree's WIP row (badge, node, band, text): faded so it does not read as this worktree's changes.
    static let graphOtherWorktreeAlpha: CGFloat = 0.45
    /// Initials on a node, dark on the bright lanes. #1C1C1E
    static let graphNodeText = srgb(0x1C1C1E)
    /// The inside of a hollow node (WIP, stash), so the lines under it do not show: `sheetCardOpaque`. #252527
    static let graphSurface = sheetCardOpaque
    /// The selected rows: a neutral fill (graph and diff rows) and its 1 pt edge (diff rows), like `selectedFill` /
    /// `selectedBorder`.
    /// White 0.11 / white 0.10
    static let graphSelection = NSColor.white.withAlphaComponent(0.11)
    static let graphSelectionBorder = NSColor.white.withAlphaComponent(0.10)

    // MARK: Diff (AppKit: the diff table draws its rows in `draw(_:)`)

    /// An added line's row and the changed part of it (intraline), green on `surface`. #5CC98A at 0.14 / 0.36
    static let diffAddedFill = srgb(0x5CC98A).withAlphaComponent(0.14)
    static let diffAddedEmphasis = srgb(0x5CC98A).withAlphaComponent(0.36)
    /// A removed line's row and the changed part of it, red on `surface`. #F0605C at 0.15 / 0.38
    static let diffRemovedFill = srgb(0xF0605C).withAlphaComponent(0.15)
    static let diffRemovedEmphasis = srgb(0xF0605C).withAlphaComponent(0.38)
    /// The `+` and `−` gutter signs. #5CC98A / #F0605C
    static let diffAddedSign = srgb(0x5CC98A)
    static let diffRemovedSign = srgb(0xF0605C)
    /// A commit's Revert Hunk button: orange (undo), apart from Stage's green, Discard's red and conflicts' amber.
    /// #F08A3C
    static let diffRevertTint = srgb(0xF08A3C)
    /// A hunk header row's band: a faint brand blue, apart from the code rows, with a hairline above and below.
    /// #6E9BF5 at 0.14, white 0.08
    static let diffHunkFill = srgb(0x6E9BF5).withAlphaComponent(0.14)
    static let diffHunkEdge = NSColor.white.withAlphaComponent(0.08)
    /// The line numbers in the gutters. White 0.45
    static let diffLineNumber = NSColor.white.withAlphaComponent(0.45)
    /// Code text without a token: white, not grey (user, 2026-11-17). White 0.97
    static let diffText = NSColor.white.withAlphaComponent(0.97)
    /// Selected text in a diff line, under the glyphs: the accent, see-through so the band and syntax colors show.
    /// #2F86FB at 0.45
    static let diffTextSelection = srgb(0x2F86FB).withAlphaComponent(0.45)

    // MARK: Conflict editor (AppKit: its panes draw their rows in `draw(_:)`)

    /// Side A (ours, stage 2): its badge, a conflict line's edge bar, the line's band and a ticked line's band.
    /// #5E9CF0 / at 0.16 / at 0.34
    static let conflictA = srgb(0x5E9CF0)
    static let conflictAFill = srgb(0x5E9CF0).withAlphaComponent(0.16)
    static let conflictATickedFill = srgb(0x5E9CF0).withAlphaComponent(0.34)
    /// Side B (theirs, stage 3), gold. #F2B630 / at 0.14 / at 0.32
    static let conflictB = srgb(0xF2B630)
    static let conflictBFill = srgb(0xF2B630).withAlphaComponent(0.14)
    static let conflictBTickedFill = srgb(0xF2B630).withAlphaComponent(0.32)
    /// An unresolved conflict in Output (it still shows the base text): its edge bar and band. #E260B0 / at 0.22
    static let conflictUnresolved = srgb(0xE260B0)
    static let conflictUnresolvedFill = srgb(0xE260B0).withAlphaComponent(0.22)
    /// Output lines the user typed (a manual edit). White 0.07
    static let conflictEditedFill = NSColor.white.withAlphaComponent(0.07)

    // MARK: Syntax (Xcode's Default (Dark) family, on `surface`)

    /// #FC5FA3
    static let syntaxKeyword = srgb(0xFC5FA3)
    /// #FC6A5D
    static let syntaxString = srgb(0xFC6A5D)
    /// #D0BF69
    static let syntaxNumber = srgb(0xD0BF69)
    /// #98A5B2
    static let syntaxComment = srgb(0x98A5B2)
    /// #5DD8FF
    static let syntaxType = srgb(0x5DD8FF)
    /// White 0.8
    static let syntaxPunctuation = NSColor.white.withAlphaComponent(0.8)

    // MARK: Terminal (AppKit: SwiftTerm draws its own cells)

    /// The terminal's background: `sheetCardOpaque`, so the cells and the card's padding read as one. #252527
    static let terminalBackground = sheetCardOpaque
    /// Text without a color of its own, like the diff's code. White 0.86
    static let terminalForeground = NSColor.white.withAlphaComponent(0.86)
    /// The caret: the accent (`AccentColor` #2F86FB).
    static let terminalCaret = srgb(0x2F86FB)
    /// Selected text's band, like the graph's selected rows but a step brighter so it reads over colored output.
    /// White 0.22
    static let terminalSelection = NSColor.white.withAlphaComponent(0.22)
    /// The 16 ANSI colors (black, red, green, yellow, blue, magenta, cyan, white, then their bright forms), in the
    /// graph lanes' hues so the terminal matches the rest of the window.
    /// #1C1C1E #F0605C #5CC98A #F2B630 #5E8EF0 #E260B0 #4FB8D6 #D1D1D6
    /// #636366 #FF7B77 #7FE0A5 #FFCB5C #82A9FF #F07FC4 #74CFE8 #FFFFFF
    static let terminalANSI: [NSColor] = [
        srgb(0x1C1C1E), srgb(0xF0605C), srgb(0x5CC98A), srgb(0xF2B630),
        srgb(0x5E8EF0), srgb(0xE260B0), srgb(0x4FB8D6), srgb(0xD1D1D6),
        srgb(0x636366), srgb(0xFF7B77), srgb(0x7FE0A5), srgb(0xFFCB5C),
        srgb(0x82A9FF), srgb(0xF07FC4), srgb(0x74CFE8), srgb(0xFFFFFF),
    ]

    /// An opaque sRGB color from `0xRRGGBB`.
    private static func srgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }

    /// A SwiftUI color of `value`.
    private static func color(_ value: NSColor) -> Color {
        Color(nsColor: value)
    }
}

/// The app's shared animations.
enum Motion {
    /// Pages, tabs, panels, lists and the pill: a quick spring, its small bounce invisible at this length.
    static let standard = Animation.snappy(duration: 0.25)
    /// Hover highlights.
    static let hover = Animation.easeOut(duration: 0.12)
    /// Sheets and the search bar opening: a touch slower than `standard`.
    static let sheet = Animation.snappy(duration: 0.3)
    /// A view leaving: a short fade, quicker than its entrance.
    static let exit = Animation.easeOut(duration: 0.1)
    /// A button going down and back up.
    static let press = Animation.snappy(duration: 0.12)
    /// Switches and disclosure chevrons.
    static let toggle = Animation.snappy(duration: 0.2)
}

/// A raised button like the toolbar's: `height` tall (a circle for an icon, with no `horizontalPadding`). Liquid Glass
/// on macOS 26; before, a capsule lit from above with a soft shadow, like `GlassCard(raised:)`. Lighter on hover,
/// darker while pressed, dimmed when disabled. `tint` colors the glass (or the capsule's fill).
struct RaisedButtonStyle: ButtonStyle {
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 0
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        Raised(configuration: configuration, height: height, horizontalPadding: horizontalPadding, tint: tint)
    }

    private struct Raised: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let horizontalPadding: CGFloat
        let tint: Color?
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let fill = configuration.isPressed ? Palette.pressedOverlay : hovered && isEnabled ? Palette.hoverFill : .clear
            configuration.label
                .foregroundStyle(.primary)
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: height, minHeight: height, maxHeight: height)
                .modifier(RaisedCapsule(tint: tint))
                .overlay(Capsule().fill(fill).allowsHitTesting(false))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }

    private struct RaisedCapsule: ViewModifier {
        let tint: Color?

        func body(content: Content) -> some View {
            if #available(macOS 26, *), PlatformFeatures.liquidGlass {
                content.glassEffect(.regular.tint(tint), in: Capsule())
            } else {
                content
                    .background {
                        Capsule().fill(tint ?? Palette.inputSurface)
                            .overlay(Capsule().fill(Palette.buttonSheen))
                            .shadow(color: Palette.buttonShadow, radius: 3, y: 1.5)
                    }
                    .overlay(Capsule().strokeBorder(Palette.raisedRim, lineWidth: 1).allowsHitTesting(false))
            }
        }
    }
}

extension EnvironmentValues {
    /// Inside a `ModalCard`'s footer: its `formRow` buttons take the footer's larger size (`ModalFooterMetrics`).
    @Entry var isModalFooter = false
    /// The fill of the cards (`GlassCard`) and the sidebar's tab track: `Palette.sheetCard` on the page's sheet, `surface` in
    /// the modals and the vertical tabs.
    @Entry var cardSurface = Palette.surface
    /// The 1 pt edge of the cards (`GlassCard`): `Palette.sheetCardBorder` on the page's sheet, `surfaceBorder` elsewhere.
    @Entry var cardBorder = Palette.surfaceBorder
    /// Added to a `SectionCard`'s padding around its header and its body (not to a body without padding, such as the
    /// graph's table): roomier cards on the page's sheet, the modals' cards as they were. Left and right, then top and
    /// bottom.
    @Entry var cardExtraPadding: CGFloat = 0
    @Entry var cardExtraVerticalPadding: CGFloat = 0
}

/// The buttons of a modal's footer (user, 2026-11-13): roomier and a bit bigger than a form row's.
enum ModalFooterMetrics {
    static let buttonHeight: CGFloat = 30
    static let buttonPadding: CGFloat = 16
    static let buttonFont: Font = .system(size: 14, weight: .medium)
    static let spacing: CGFloat = 12
    /// Above the buttons (under the last card) and below them; with the container's own padding about 16 pt each.
    static let verticalPadding: CGFloat = 10
    /// From the container's trailing edge, with its padding: the same 16 pt.
    static let trailingPadding: CGFloat = 10
}

/// A small text button of a card row: a capsule of the input color, lighter on hover, darker while pressed.
/// `formRow`: as tall as a compact `CapsuleTabs` item, for a form row; in a modal's footer, the footer's size
/// (`ModalFooterMetrics`). `prominent`: `Palette.primaryFill` with white text (`PrimaryLabelShadow`).
/// `compact`: a smaller monospaced badge (a commit's parents).
struct RowTextButtonStyle: ButtonStyle {
    var formRow = false
    var prominent = false
    /// With `prominent`: the red `Palette.destructiveFill` (a confirmation's Delete), not the blue.
    var destructive = false
    var compact = false
    /// A colored fill under a white label (the WIP panel's Stage All / Unstage All), as `prominent` but in this color.
    var fill: Color?

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, formRow: formRow, prominent: prominent || fill != nil,
                  destructive: destructive, compact: compact, fill: fill)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let formRow: Bool
        let prominent: Bool
        let destructive: Bool
        let compact: Bool
        let fill: Color?
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isModalFooter) private var isModalFooter

        var body: some View {
            let footer = formRow && isModalFooter
            configuration.label
                .font(footer ? ModalFooterMetrics.buttonFont : formRow ? .body
                      : compact ? .caption.monospaced().weight(.medium) : .callout.weight(.medium))
                .foregroundStyle(prominent ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
                .modifier(PrimaryLabelShadow(isOn: prominent))
                .padding(.horizontal, footer ? ModalFooterMetrics.buttonPadding : formRow ? 12 : compact ? 6 : 8)
                .padding(.vertical, formRow ? 0 : compact ? 2 : 4)
                .frame(height: footer ? ModalFooterMetrics.buttonHeight : formRow ? 24 : nil)
                .background(
                    Capsule()
                        .fill(prominent
                              ? AnyShapeStyle(fill ?? (destructive ? Palette.destructiveFill : Palette.primaryFill))
                              : AnyShapeStyle(Palette.inputSurface))
                        .overlay(Capsule().fill(
                            configuration.isPressed ? Palette.pressedOverlay : hovered && isEnabled ? Palette.hoverFill : .clear)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// The icon buttons of a row: a round highlight on hover, darker and a bit smaller while pressed, dimmed when
/// disabled. The highlight reaches past the label without changing the row's layout. A switch that is on keeps the
/// selected fill.
struct RowIconButtonStyle: ButtonStyle {
    /// A capsule highlight, for a label wider than an icon (an icon and a menu chevron).
    var capsule = false
    /// A switch that is on (Ignore Whitespace, Wrap Lines).
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, capsule: capsule, isOn: isOn)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let capsule: Bool
        let isOn: Bool
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let fill = configuration.isPressed ? Palette.pressedFill : hovered && isEnabled ? Palette.hoverFill
                : isOn ? Palette.selectedFill : .clear
            configuration.label
                .background {
                    if capsule {
                        Capsule().fill(fill).padding(-5)
                    } else {
                        Circle().fill(fill).padding(-5)
                    }
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.95 : 1)
                .animation(reduceMotion ? nil : Motion.press, value: configuration.isPressed)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// A row of a settings sidebar: the selected row is a neutral capsule (`Palette.selectedFill`) with a 1 pt
/// `Palette.selectedBorder` edge and full-strength title and icon; the others have secondary title and icon and get a
/// hover capsule. Rows sit in a `VStack(spacing: SidebarItemStyle.spacing)` instead of a `List(.sidebar)`, whose
/// selection fills the whole row height, so neighbors touch however much padding the rows get.
struct SidebarItemStyle: ButtonStyle {
    var selected: Bool
    /// Gap between two rows' capsules.
    static let spacing: CGFloat = 6
    /// Height of a row's capsule (a body line with 6 pt above and below); a taller label grows it.
    static let height: CGFloat = 28

    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration, selected: selected)
    }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovered = false

        var body: some View {
            let fill: Color = selected ? Palette.selectedFill
                : configuration.isPressed ? Palette.pressedFill
                : hovered ? Palette.hoverFill : .clear
            configuration.label
                .labelStyle(SidebarLabelStyle(emphasized: selected))
                .padding(.horizontal, 10)
                .frame(minHeight: SidebarItemStyle.height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(selected ? Palette.selectedBorder : .clear, lineWidth: 1))
                .contentShape(Capsule())
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }

    private struct SidebarLabelStyle: LabelStyle {
        /// Full-strength text: the selected row.
        let emphasized: Bool

        func makeBody(configuration: Configuration) -> some View {
            HStack(spacing: 8) {
                configuration.icon
                    .frame(width: 20)
                    .foregroundStyle(emphasized ? Color.primary : Color.secondary)
                configuration.title
                    .foregroundStyle(emphasized ? Color.primary : Color.secondary)
            }
        }
    }
}

/// The white label of a primary (`Palette.primaryFill`) button gets a faint dark shadow, so it stands out from the blue.
/// On the label only, before the fill, so the capsule itself casts nothing.
private struct PrimaryLabelShadow: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        content.shadow(color: isOn ? Palette.onPrimaryShadow : .clear, radius: 1, y: 0.75)
    }
}

/// A button of a bottom bar: `height` tall (a circle for an icon, with no `horizontalPadding`), a capsule of the input
/// color, or `Palette.primaryFill` when `prominent`; lighter on hover, darker while pressed, dimmed when disabled.
struct BottomBarButtonStyle: ButtonStyle {
    /// Every control of the bottom bars: buttons, menus, chips and a one-line text field.
    static let height: CGFloat = 34

    var height = Self.height
    var prominent = false
    var horizontalPadding: CGFloat = 14
    /// A menu's trigger: it stays pressed while its menu is open, and shows the hover look then, not the darker one.
    var menu = false

    func makeBody(configuration: Configuration) -> some View {
        Highlight(configuration: configuration, height: height, prominent: prominent,
                  horizontalPadding: horizontalPadding, menu: menu)
    }

    private struct Highlight: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        let prominent: Bool
        let horizontalPadding: CGFloat
        let menu: Bool
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.body.weight(prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? AnyShapeStyle(Palette.onAccent) : AnyShapeStyle(.primary))
                .modifier(PrimaryLabelShadow(isOn: prominent))
                .padding(.horizontal, horizontalPadding)
                .frame(minWidth: height, minHeight: height, maxHeight: height)
                .background(
                    Capsule()
                        .fill(prominent ? AnyShapeStyle(Palette.primaryFill) : AnyShapeStyle(Palette.inputSurface))
                        .overlay(Capsule().fill(
                            configuration.isPressed && !menu ? Palette.pressedOverlay
                                : (hovered || configuration.isPressed) && isEnabled ? Palette.hoverFill : .clear)))
                .contentShape(Capsule())
                .opacity(isEnabled ? 1 : 0.45)
                .animation(Motion.hover, value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// A toolbar button alone in its capsule: on macOS 26 AppKit gives it no hover highlight (only buttons of a group get
/// one), so it draws the same small round highlight itself. `help` is its tooltip and accessibility label.
struct ToolbarIconButton: View {
    let systemImage: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            Button(action: action) {
                label
                    .labelStyle(.iconOnly)
                    .font(.body)
                    .imageScale(.large)
            }
            .buttonStyle(Highlight())
            .help(help)
        } else {
            Button(action: action) { label }
                .help(help)
        }
    }

    private var label: some View {
        Label {
            Text(help)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    /// AppKit pads the item less on the sides than above and below: 36 by 24 makes the capsule round. The highlight
    /// is as big as a group button's.
    private struct Highlight: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            HoverCircle(configuration: configuration)
        }

        private struct HoverCircle: View {
            let configuration: ButtonStyleConfiguration
            @State private var hovered = false

            var body: some View {
                configuration.label
                    .frame(width: 36, height: 24)
                    .background {
                        Circle()
                            .fill(configuration.isPressed ? Palette.pressedFill : hovered ? Palette.hoverFill : .clear)
                            .frame(width: 28, height: 28)
                    }
                    .contentShape(Rectangle())
                    .animation(Motion.hover, value: hovered)
                    .onHover { hovered = $0 }
            }
        }
    }
}

/// The arrow of a menu button.
struct MenuChevron: View {
    /// The space between a menu button's title and its arrow.
    static let gap: CGFloat = 8

    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 11, weight: .bold))
            .accessibilityHidden(true)
    }
}

/// A dropdown of a form row (the Settings choices longer than a few options): a capsule like
/// `RowTextButtonStyle(formRow:)` showing `title` (the current choice) and a `MenuChevron`, opening a menu of `content`
/// with a check on the selected entry. Replaces `Picker(.menu)`, whose AppKit pop-up button is a rounded rectangle on
/// every macOS, so every button of the app is a capsule (user, 2026-11-13). `content` is the picker's entries, each
/// `.tag`ged with its value as in a `Picker`; `footer` (actions, not choices) goes below them after a divider.
struct CapsuleMenuPicker<Value: Hashable, Content: View, Footer: View>: View {
    let label: String
    @Binding var selection: Value
    let title: Text
    @ViewBuilder let content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        Menu {
            Picker(label, selection: $selection, content: content)
                .pickerStyle(.inline)
                .labelsHidden()
            if Footer.self != EmptyView.self {
                Divider()
                footer()
            }
        } label: {
            HStack(spacing: MenuChevron.gap) {
                title.lineLimit(1)
                MenuChevron()
            }
        }
        .menuStyle(.button)
        .buttonStyle(BottomBarButtonStyle(height: 24, horizontalPadding: 12, menu: true))
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(Text(label))
        .accessibilityValue(title)
    }
}

extension CapsuleMenuPicker where Footer == EmptyView {
    init(label: String, selection: Binding<Value>, title: Text, @ViewBuilder content: @escaping () -> Content) {
        self.init(label: label, selection: selection, title: title, content: content, footer: { EmptyView() })
    }
}

/// A `CapsuleMenuPicker` for a long list of names (branches): the same capsule, opening a popover with a filter field
/// over the list. Typing keeps the entries whose title holds every word typed; Up/Down move the highlight, Return picks
/// it, Escape closes. The current choice is checked, highlighted and scrolled to on open.
struct FilterCapsulePicker: View {
    let label: String
    @Binding var selection: String
    let items: [String]
    var title: (String) -> String = { $0 }
    @State private var isOpen = false

    var body: some View {
        Button { isOpen.toggle() } label: {
            HStack(spacing: MenuChevron.gap) {
                Text(title(selection)).lineLimit(1)
                MenuChevron()
            }
        }
        .buttonStyle(BottomBarButtonStyle(height: 24, horizontalPadding: 12, menu: true))
        .fixedSize()
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(title(selection)))
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            FilterPickerList(label: label, selection: $selection, items: items, title: title, isOpen: $isOpen)
        }
    }
}

/// The popover of a `FilterCapsulePicker`.
private struct FilterPickerList: View {
    let label: String
    @Binding var selection: String
    let items: [String]
    let title: (String) -> String
    @Binding var isOpen: Bool
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var focused: Bool

    private static let maxHeight: CGFloat = 320

    var body: some View {
        let matches = self.matches
        VStack(alignment: .leading, spacing: 8) {
            TextField(label, text: $query, prompt: Text("Filter"))
                .textFieldStyle(.settings)
                .labelsHidden()
                .autocorrectionDisabled()
                .focused($focused)
                .onSubmit(pickHighlighted)
                .onKeyPress(.downArrow) { move(by: 1, in: matches) }
                .onKeyPress(.upArrow) { move(by: -1, in: matches) }
                .padding(.horizontal, 10)
            if matches.isEmpty {
                Text(items.isEmpty ? "None" : "No match for \"\(query)\"")
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                    .frame(minHeight: SidebarItemStyle.height)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(matches, id: \.self) { item in
                                Button { pick(item) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .bold))
                                            .opacity(item == selection ? 1 : 0)
                                            .accessibilityHidden(true)
                                        Text(title(item))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                                .buttonStyle(SidebarItemStyle(selected: item == highlighted))
                                .help(title(item))
                                .id(item)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    .frame(height: min(Self.maxHeight, CGFloat(matches.count) * (SidebarItemStyle.height + 2)))
                    .onChange(of: highlighted) { _, item in
                        if let item { proxy.scrollTo(item) }
                    }
                    .onAppear {
                        if let highlighted { proxy.scrollTo(highlighted, anchor: .center) }
                    }
                }
            }
        }
        // Vertical only: the rows' inset is inside the scroll view, so its scroller runs along the popover's edge.
        .padding(.vertical, 10)
        .frame(width: 300)
        .onAppear {
            highlighted = items.contains(selection) ? selection : items.first
            // Next run-loop turn, once the popover's window exists.
            DispatchQueue.main.async { focused = true }
        }
        .onChange(of: query) { _, _ in
            let matches = self.matches
            highlighted = matches.contains(selection) && query.isEmpty ? selection : matches.first
        }
    }

    /// The items whose title holds every word of the query (case- and diacritic-insensitive); all for an empty one.
    private var matches: [String] {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in
            let text = title(item)
            return words.allSatisfy { text.localizedStandardContains($0) }
        }
    }

    private func pick(_ item: String) {
        selection = item
        isOpen = false
    }

    private func pickHighlighted() {
        let matches = self.matches
        guard let item = highlighted.flatMap({ matches.contains($0) ? $0 : nil }) ?? matches.first else { return }
        pick(item)
    }

    /// Up/Down: moves the highlight, stopping at the ends.
    private func move(by step: Int, in matches: [String]) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        let index = highlighted.flatMap { matches.firstIndex(of: $0) } ?? (step > 0 ? -1 : matches.count)
        highlighted = matches[min(max(index + step, 0), matches.count - 1)]
        return .handled
    }
}

/// Tabs for a toolbar item, as tall as its buttons' highlights, in the toolbar's capsule on macOS 26 (a surface capsule
/// before): the selected tab is an accent capsule that slides between the tabs (no slide under Reduce Motion).
/// `compact`: smaller, always on a surface capsule, for a form row or a card header; it has the sidebar's look (the
/// pill inset `fillInset` from the track's edge, caption text), so every segmented choice in the app matches the
/// Branches / Tags / PRs tabs (user, 2026-11-13). `fillsWidth`: the track takes the width it is offered and each tab
/// gets its label's width plus an equal share of the rest (`ContentWidthRow`), inset `fillInset` from its edge so the
/// pill floats inside it; with `systemImage`, each tab shows its icon and title, or its icon alone when the title
/// does not fit (never truncated). Every shape is a true capsule (`.circular`: radius = half the height), so the pill and the track are concentric.
/// A compact track on a card is `Palette.modalInput`, set into the card (its fill is the card's own, so it blended in);
/// the sidebar's `fillsWidth` track keeps `cardSurface`, a step darker than the panel it sits on. `small`: a compact
/// track a little lower, for a card header (the open file's Diff / Full file, a PR's Comment / Review), so it clears
/// the header's edges.
struct CapsuleTabs<Tab: Hashable>: View {
    @Binding var selection: Tab
    let tabs: [Tab]
    let title: (Tab) -> Text
    var compact = false
    var small = false
    /// A tab's tooltip (and its accessibility label when it has an icon).
    var help: ((Tab) -> String)?
    var fillsWidth = false
    /// A tab's SF Symbol, drawn before its title.
    var systemImage: ((Tab) -> String)?
    /// With `compact`: the track is filled lighter than the card it sits on (`Palette.inputSurface`), so it reads as a
    /// control on a dark card instead of vanishing into the card's own color (a pull request's tabs, user 2026-11-17).
    var raisedTrack = false
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = fillsWidth ? AnyLayout(ContentWidthRow(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
        layout {
            ForEach(tabs, id: \.self) { tab in
                Item(tab: tab, title: title(tab), help: help?(tab), systemImage: systemImage?(tab),
                     selected: tab == selection, compact: compact, small: small, fillsWidth: fillsWidth,
                     namespace: namespace) {
                    withAnimation(animation) { selection = tab }
                }
            }
        }
        // One pill that follows the selected item's frame, so it slides instead of fading between items.
        .background {
            Capsule(style: .circular)
                .fill(Color.accentColor)
                .matchedGeometryEffect(id: selection, in: namespace, isSource: false)
        }
        // Also animates a selection set from code (menus, shortcuts).
        .animation(animation, value: selection)
        .modifier(SurfaceTrack(compact: compact, small: small, fillsWidth: fillsWidth, raised: raisedTrack))
    }

    /// The gap between a `fillsWidth` (or `compact`) track's edge and its tabs, on every side.
    static var fillInset: CGFloat { 6 }

    /// The `fillsWidth` row (user, 2026-11-13): each tab as wide as its label plus the same padding, then an equal share
    /// of the spare width, so a longer label (Branches) gets a wider tab and the track still fills its width. When the
    /// labels do not fit, equal shares (the tabs then show their icons alone).
    private struct ContentWidthRow: Layout {
        let spacing: CGFloat

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let natural = sizes.reduce(0) { $0 + $1.width } + gaps(subviews)
            return CGSize(width: proposal.width ?? natural, height: sizes.map(\.height).max() ?? 0)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
            let available = bounds.width - gaps(subviews)
            let spare = available - ideal.reduce(0, +)
            let count = CGFloat(max(subviews.count, 1))
            var x = bounds.minX
            for (index, subview) in subviews.enumerated() {
                let width = spare >= 0 ? ideal[index] + spare / count : available / count
                subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: width, height: bounds.height))
                x += width + spacing
            }
        }

        private func gaps(_ subviews: Subviews) -> CGFloat {
            spacing * CGFloat(max(subviews.count - 1, 0))
        }
    }

    private var animation: Animation? { reduceMotion ? nil : Motion.standard }

    /// Before macOS 26 the toolbar draws no capsule around its items; a form never does.
    private struct SurfaceTrack: ViewModifier {
        let compact: Bool
        let small: Bool
        let fillsWidth: Bool
        let raised: Bool
        @Environment(\.cardSurface) private var surface

        func body(content: Content) -> some View {
            if #available(macOS 26, *), PlatformFeatures.liquidGlass, !compact {
                content
            } else {
                content
                    .padding(small ? 4 : fillsWidth || compact ? CapsuleTabs.fillInset : 3)
                    .background(Capsule(style: .circular).fill(raised ? Palette.inputSurface
                        : compact && !fillsWidth ? Palette.modalInput : surface))
                    .overlay(Capsule(style: .circular).strokeBorder(Palette.surfaceBorder, lineWidth: 1)
                        .allowsHitTesting(false))
            }
        }
    }

    private struct Item: View {
        let tab: Tab
        let title: Text
        let help: String?
        let systemImage: String?
        let selected: Bool
        let compact: Bool
        let small: Bool
        let fillsWidth: Bool
        let namespace: Namespace.ID
        let action: () -> Void
        @State private var hovered = false
        /// A toolbar button's highlight; a form row's control when compact; a card header's when small.
        private var height: CGFloat { small ? 22 : compact ? 24 : 28 }

        var body: some View {
            Button(action: action) {
                label
                    .font(fillsWidth || compact ? .settingsCaption : .callout)
                    .lineLimit(1)
                    .foregroundStyle(selected ? Palette.onAccent : Color.secondary)
                    .padding(.horizontal, fillsWidth ? 4 : compact ? 10 : 12)
                    // Takes the width `ContentWidthRow` gives it; its label's width is its ideal.
                    .frame(minWidth: fillsWidth ? 0 : nil, maxWidth: fillsWidth ? .infinity : nil)
                    .frame(height: height)
                    .background {
                        if hovered && !selected { Capsule(style: .circular).fill(Palette.hoverFill) }
                    }
                    .matchedGeometryEffect(id: tab, in: namespace)
                    .contentShape(Capsule(style: .circular))
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }
            // An empty tooltip shows nothing.
            .help(help.map { Text($0) } ?? Text(verbatim: ""))
            .accessibilityLabel(systemImage != nil ? help.map { Text($0) } ?? title : title)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }

        /// The title, or the icon and title (the icon alone when the title does not fit).
        @ViewBuilder
        private var label: some View {
            if let systemImage {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 4) {
                        IconImage(systemImage, size: 13)
                        title
                    }
                    .fixedSize()
                    IconImage(systemImage, size: 13)
                }
            } else {
                title
            }
        }
    }
}

/// A small on/off switch, dimmed when disabled; the system switch stays wide even at `.mini` on macOS 26.
struct CompactSwitch: ToggleStyle {
    static let height: CGFloat = 19

    func makeBody(configuration: Configuration) -> some View {
        Switch(configuration: configuration)
    }

    private struct Switch: View {
        let configuration: ToggleStyleConfiguration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            // A Button, not a tap gesture: keyboard navigation reaches it and Space toggles it.
            Button { configuration.isOn.toggle() } label: {
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Palette.switchOffFill)
                    .frame(width: 34, height: CompactSwitch.height)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .shadow(color: Palette.knobShadow, radius: 0.5, y: 0.5)
                            .padding(1.5)
                    }
                    .animation(reduceMotion ? nil : Motion.toggle, value: configuration.isOn)
                    .contentShape(Capsule())
            }
            .buttonStyle(Bare())
            .opacity(isEnabled ? 1 : 0.45)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }
    }

    /// The label as is: `.plain` dims a disabled label on top of the switch's own dimming.
    private struct Bare: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View { configuration.label }
    }
}

/// A disclosure row whose chevron sits on the title's line, not halfway down a title with a subtitle. A click anywhere
/// on the header row toggles it, not only on the chevron; the row's own controls (its switch) keep their clicks.
struct TitleChevronDisclosureStyle: DisclosureGroupStyle {
    /// The chevron's width: content inset by it lines up with the title.
    nonisolated static let indent: CGFloat = 18

    func makeBody(configuration: Configuration) -> some View {
        TitleChevronDisclosure(configuration: configuration)
    }
}

private struct TitleChevronDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .frame(width: TitleChevronDisclosureStyle.indent, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(configuration.isExpanded ? "Collapse" : "Expand")
                configuration.label
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            if configuration.isExpanded { configuration.content }
        }
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : Motion.toggle) {
            configuration.$isExpanded.wrappedValue.toggle()
        }
    }
}

/// The translucent window background, blurring what is behind the window (toolbar included), under a tint so only a
/// little shows through.
struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        let tint = TintView(frame: view.bounds)
        tint.autoresizingMask = [.width, .height]
        view.addSubview(tint)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}

    /// Sets the tint in `updateLayer()`, the layer-backed view's drawing pass.
    private final class TintView: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            wantsLayer = true
        }

        override var wantsUpdateLayer: Bool { true }

        override func updateLayer() {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = Palette.windowTint.cgColor
            }
        }
    }
}

/// A card or panel: solid `Palette.surface` with a 1 pt `Palette.surfaceBorder` edge, on every macOS version, so it
/// stands out from the window background. Raised (a sidebar, an entry card) looks like the toolbar's capsules: a rim
/// lit from above, a faint sheen at the top and a soft shadow under it. Radii: 20 raised (sidebar, modal, entry card),
/// 14 content cards (`SettingsMetrics.cardRadius`), 10 inputs (`SettingsInputMetrics.cornerRadius`).
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 14
    var raised = false
    @Environment(\.cardSurface) private var surface
    @Environment(\.cardBorder) private var border

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if raised {
            content
                .background {
                    shape.fill(surface)
                        .overlay(shape.fill(Palette.cardSheen))
                        .shadow(color: Palette.cardShadow, radius: 6, y: 3)
                }
                .overlay(shape.strokeBorder(Palette.raisedRim, lineWidth: 1).allowsHitTesting(false))
        } else {
            content
                .background(shape.fill(surface))
                .overlay(shape.strokeBorder(border, lineWidth: 1).allowsHitTesting(false))
        }
    }
}

/// A notice on a `SectionCard` (the operation banner, a toast): the card's fill tinted with its tone and a
/// faint edge in it, so it stands out from the cards around it and keeps their shape.
struct NoticeTint: ViewModifier {
    let tone: Color
    @Environment(\.cardSurface) private var surface

    func body(content: Content) -> some View {
        content
            .environment(\.cardSurface, surface.mix(with: tone, by: 0.12))
            .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(tone.opacity(0.3), lineWidth: 1)
                .allowsHitTesting(false))
    }
}

/// On macOS 26+ (unless `--force-fallbacks`), scrolled content stops hard at the top edge instead of fading under
/// the transparent title bar.
struct HardTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
    }
}

extension ToolbarContent {
    /// On macOS 26+ (unless `--force-fallbacks`), the toolbar draws no glass behind this item, so it does not share
    /// the capsule of the items next to it.
    @ToolbarContentBuilder
    func hiddenSharedBackground() -> some ToolbarContent {
        if #available(macOS 26, *), PlatformFeatures.liquidGlass {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Spacing of the settings pages (a 4 pt scale). In the Settings modal the sidebar card starts under the header card,
/// and the page beside it starts at the same top edge: its first element (a card's title, or the card itself) is
/// top-aligned with the sidebar card. Only the tab layout, which has no sidebar, starts its page `contentTopOffset`
/// lower.
enum SettingsMetrics {
    /// Corner radius of a content card (`GlassCard`'s default).
    static let cardRadius: CGFloat = 14
    /// Inner padding of a card: its rows' sides, a card header, a modal header.
    static let cardPadding: CGFloat = 12
    /// Gap between two cards of a page.
    static let cardSpacing: CGFloat = 16
    /// Space above and below each row of a `SettingsGroup` (a divider sits in the middle of two rows' padding).
    static let rowPadding: CGFloat = 10
    /// Outer padding of a page's scroll content (trailing, bottom, and leading without a sidebar).
    static let pagePadding: CGFloat = 20
    /// The sidebar card: width, rows' inset inside it.
    static let sidebarWidth: CGFloat = 200
    static let sidebarRowsPadding: CGFloat = 10
    /// The gap from the sidebar card to the page, and under the page's last card.
    static let sidebarInset: CGFloat = 12
    /// Tab layout only: the page's top gap under the top of the content area (about 20 pt under the header's
    /// capsules). Never in the sidebar layout, whose page is top-aligned with the sidebar card.
    static let contentTopOffset: CGFloat = 12
}

extension Font {
    /// Small text in the Settings window: row hints, warnings and errors, footers, banners, badges and small button
    /// labels. One step above the system caption (11 pt, not 10) and still below row titles (13 pt).
    static let settingsCaption: Font = .subheadline
}

/// A titled card of settings rows, with an optional description above the card (secondary body text, like a page
/// intro). It replaces a grouped `Form`, which macOS
/// caps at about 700 pt and centers; these cards fill the column. Separate the rows with `SettingsDivider()`, and give
/// the page `.labeledContentStyle(.settingsRow)`.
struct SettingsGroup<Content: View>: View {
    let title: String?
    let description: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String?, description: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.description = description
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
            }
            if let description {
                Text(description)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SettingsMetrics.cardPadding)
                    .padding(.bottom, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, SettingsMetrics.cardPadding)
            .padding(.vertical, SettingsMetrics.rowPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
            .environment(\.settingsGroupTitle, title)
        }
        // A search result for the whole group, or for one of its rows that is not on the page.
        .modifier(SettingsSearchAnchor(title: nil, groupTitle: title))
    }
}

/// The divider between two rows of a `SettingsGroup`, with the rows' vertical padding around it.
struct SettingsDivider: View {
    var body: some View {
        Divider()
            .padding(.vertical, SettingsMetrics.rowPadding)
    }
}

/// A row of a `SettingsGroup` for `LabeledContent`: the label (a title, then an optional `.settingsCaption` `.secondary` hint)
/// leading, the control trailing. The label dims like the controls when the row is disabled.
struct SettingsRowStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                configuration.label
            }
            .fixedSize(horizontal: false, vertical: true)
            .modifier(DimmedWhenDisabled())
            Spacer(minLength: 12)
            configuration.content
        }
    }

    private struct DimmedWhenDisabled: ViewModifier {
        @Environment(\.isEnabled) private var isEnabled

        func body(content: Content) -> some View {
            content.opacity(isEnabled ? 1 : 0.45)
        }
    }
}

extension LabeledContentStyle where Self == SettingsRowStyle {
    /// Title and hint leading, control trailing (see `SettingsRowStyle`).
    static var settingsRow: SettingsRowStyle { SettingsRowStyle() }
}

/// The text inputs on a card: a rounded field of the input color with a 1 pt edge; the focused field gets an accent
/// edge instead of the system's square focus ring. The text sits inside the fill, clear of the rounded corners.
enum SettingsInputMetrics {
    /// The small inset-card radius.
    static let cornerRadius: CGFloat = 10
    /// As tall as a 28 pt row button; a multi-line field grows past it.
    static let minHeight: CGFloat = 28
}

/// `TextField` / `SecureField` style: `.textFieldStyle(.settings)`. A main-actor conformance: the protocol's `_body` is
/// not isolated, and the field view it builds is.
@MainActor
struct SettingsTextFieldStyle: @MainActor TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        Field(configuration: configuration)
    }

    private struct Field: View {
        let configuration: TextField<SettingsTextFieldStyle._Label>
        @FocusState private var focused: Bool

        var body: some View {
            configuration
                .textFieldStyle(.plain)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minHeight: SettingsInputMetrics.minHeight)
                .modifier(SettingsInputChrome(focused: focused))
        }
    }
}

extension TextFieldStyle where Self == SettingsTextFieldStyle {
    static var settings: SettingsTextFieldStyle { SettingsTextFieldStyle() }
}

/// The one field of a single-input modal (Set Alias…, Rename Group…, Set Emoji…): `.textFieldStyle(.modal)`, straight
/// on the modal's container with no card around it (user, 2026-11-18). Larger than `.settings`, on a darker fill, with
/// no focus ring: the caret shows the focus.
@MainActor
struct ModalTextFieldStyle: @MainActor TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
        configuration
            .textFieldStyle(.plain)
            .font(.system(size: 15))
            .focusEffectDisabled()
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(minHeight: 38)
            .background(shape.fill(Palette.modalInput))
            .overlay(shape.strokeBorder(Palette.surfaceBorder, lineWidth: 1))
    }
}

extension TextFieldStyle where Self == ModalTextFieldStyle {
    static var modal: ModalTextFieldStyle { ModalTextFieldStyle() }
}

extension View {
    /// The `.textFieldStyle(.settings)` look for a multi-line `TextEditor`: its own background hidden and the text
    /// inset, so the first line, the caret and the scroller sit inside the rounded corners.
    func settingsTextEditor() -> some View {
        modifier(SettingsTextEditorStyle())
    }
}

private struct SettingsTextEditorStyle: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .focused($focused)
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            .modifier(SettingsInputChrome(focused: focused))
    }
}

/// The rounded fill, the edge (accent while focused) and the disabled dimming shared by both input styles.
struct SettingsInputChrome: ViewModifier {
    let focused: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: SettingsInputMetrics.cornerRadius, style: .continuous)
        content
            .focusEffectDisabled()
            .background(shape.fill(Palette.inputSurface))
            .overlay(shape.strokeBorder(focused ? Color.accentColor : Palette.surfaceBorder, lineWidth: focused ? 1.5 : 1))
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Motion.hover, value: focused)
    }
}

// MARK: - Modals

/// The window content behind an open modal or the command palette (task 9.6).
enum ModalBackdropMetrics {
    /// A light Gaussian blur of the content (user, 2026-11-13: visibly blurred, not only dimmed): the panels, cards
    /// and graph lanes keep their shapes and colors under the scrim, the small text does not stay legible.
    static let blurRadius: CGFloat = 3
}

/// The window content behind an open modal: blurred a little (`ModalBackdropMetrics.blurRadius`), disabled (so its
/// keyboard shortcuts, such as the diff's Escape or the commit's ⌘Return, never fire under the modal) and hidden from
/// accessibility. A render effect on the content as it is: nothing in it is rebuilt. The blur fades in with
/// `Motion.sheet` and out with `Motion.exit` (also under Reduce Motion: it is not movement), animated alone.
struct ModalBackdrop: ViewModifier {
    let isActive: Bool
    /// Follows `isActive` just after the modal shows, at once when it closes: disabling re-evaluates every view of
    /// the content that reads `isEnabled` (4-5 ms with a repo tab), which would delay the modal's first frame. The
    /// scrim takes every click meanwhile, and the focus only moves into the modal on the next turn.
    @State private var isDisabled = false
    /// The latest `isActive`, for the delayed update (the struct's own value is captured as it was). Never read by
    /// `body`, so writing it re-evaluates nothing.
    @State private var wantsDisabled = false

    func body(content: Content) -> some View {
        content
            .disabled(isDisabled)
            .accessibilityHidden(isActive)
            .animation(isActive ? Motion.sheet : Motion.exit) { view in
                view.blur(radius: isActive ? ModalBackdropMetrics.blurRadius : 0, opaque: false)
            }
            .onChange(of: isActive, initial: true) { _, active in
                wantsDisabled = active
                guard active else { return isDisabled = false }
                // A timer, not the next main-queue turn, so the modal's frame is drawn first.
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(1)) { isDisabled = wantsDisabled }
            }
    }
}

/// The scrim of an open modal or the command palette: `Palette.scrim` over the window content (under the toolbar,
/// which stays live). A click runs `onTap` (closing the palette or a confirmation; a form ignores it).
struct ModalScrim: View {
    var onTap: () -> Void = {}

    var body: some View {
        Rectangle()
            .fill(Palette.scrim)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .accessibilityHidden(true)
    }
}

@MainActor
enum ModalMetrics {
    /// The command palette's container: `PanelContainer`'s radius around 14 pt cards.
    static let cornerRadius: CGFloat = SettingsMetrics.cardRadius + PanelContainerMetrics.padding
    /// Between the window content's edges and the card, so a tall card (the rebase rows) stays inside the window.
    static let margin: CGFloat = 24
    /// Added to the container's padding on both sides of the header and the cards, so they don't hug the modal's edge:
    /// the cards line up with the footer's buttons (16 pt from the edge).
    static let bodyInset: CGFloat = ModalFooterMetrics.trailingPadding
}

/// Every modal's card, decorated like the command palette (task 9.6): a `PanelContainer` (bg_card, radius 20, 1 pt
/// edge) with the palette's shadow, holding cards of `Palette.surface` (radius 14). The header has the title and an
/// optional subtitle (a confirmation's message) as plain text on the container, no card (user, 2026-11-13), padded
/// like a card's content so it lines up with the cards' text; then the caller's cards (`ModalSection`, `SectionCard`), then the
/// buttons at the bottom of the container. `takesFocus`: a card with no text field takes the focus on the next turn,
/// so the keyboard (Escape, Return) reaches it and not the view behind.
struct ModalCard<Content: View, Actions: View>: View {
    let title: String
    var subtitle: String?
    /// The header's icon: an SF Symbol or a Lucide asset (`IconImage`).
    var systemImage: String?
    var width: CGFloat = 440
    var takesFocus = false
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions
    @FocusState private var focused: Bool

    var body: some View {
        PanelContainer(cornerRadius: ModalMetrics.cornerRadius) {
            VStack(alignment: .leading, spacing: PanelContainerMetrics.padding) {
                Group {
                    header
                    content()
                }
                .padding(.horizontal, ModalMetrics.bodyInset)
                HStack(spacing: ModalFooterMetrics.spacing) {
                    Spacer(minLength: 0)
                    actions()
                }
                .environment(\.isModalFooter, true)
                .padding(.trailing, ModalFooterMetrics.trailingPadding)
                .padding(.vertical, ModalFooterMetrics.verticalPadding)
            }
        }
        .frame(width: width)
        .shadow(color: Palette.cardShadow, radius: 16, y: 6)
        .modifier(ModalCardFocus(enabled: takesFocus, focused: $focused))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                IconImage(systemImage)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.inlineCode(title))
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(Self.inlineCode(subtitle))
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// `text` with each part between backticks (a branch name) as inline code: monospaced, in the primary color, on
    /// `Palette.inlineCodeFill`, so names stand out from the words around them.
    private static func inlineCode(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            guard !index.isMultiple(of: 2) else {
                result += AttributedString(String(part))
                continue
            }
            // Narrow no-break spaces pad the fill and keep it on the name's line.
            var code = AttributedString("\u{202F}\(part)\u{202F}")
            code.inlinePresentationIntent = .code
            code.foregroundColor = .primary
            code.backgroundColor = Palette.inlineCodeFill
            result += code
        }
        return result
    }
}

/// Focuses a `ModalCard` that has no text field on the next turn.
private struct ModalCardFocus: ViewModifier {
    let enabled: Bool
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if enabled {
            content
                .focusable()
                .focusEffectDisabled()
                .focused(focused)
                // The card is installed on this turn; focus it on the next one.
                .onAppear { DispatchQueue.main.async { focused.wrappedValue = true } }
        } else {
            content
        }
    }
}

/// One inner card of a `ModalCard`: the palette's results card (surface, radius 14, 1 pt edge), padded like a
/// settings card.
struct ModalSection<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content()
        }
        .padding(SettingsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(GlassCard(cornerRadius: SettingsMetrics.cardRadius))
    }
}
