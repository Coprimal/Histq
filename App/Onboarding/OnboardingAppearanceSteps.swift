// The onboarding's appearance step bodies, shown in `OnboardingCard`: tab position, layout, commit avatars, row height,
// lane colors and the other worktrees' fading. Each says what it sets in a line, shows the current pick large (when the
// window has room for it) and lists its options as tiles; a click selects a tile and writes the preference at once,
// through Settings › Appearance's keys and write paths, so the window behind follows and a skipped step keeps the pick.
import SwiftUI

/// One appearance step's body. The stored preferences are the only selection; the previews draw the other stored
/// picks too, so each step shows what the window will look like.
struct OnboardingAppearanceStep: View {
    let step: OnboardingModel.Step

    @AppStorage(PrefKey.tabPosition.rawValue, store: Preferences.defaults) private var tabPosition = "top"
    @AppStorage(PrefKey.layoutPreset.rawValue, store: Preferences.defaults) private var layoutPreset = "classic"
    @AppStorage(PrefKey.avatarMode.rawValue, store: Preferences.defaults) private var avatarMode = "generated"
    @AppStorage(PrefKey.rowDensity.rawValue, store: Preferences.defaults) private var rowDensity = "regular"
    @AppStorage(PrefKey.laneColors.rawValue, store: Preferences.defaults) private var laneColors = LaneColors.vivid
    @AppStorage(PrefKey.graphFadeOtherWorktrees.rawValue, store: Preferences.defaults) private var fadesWorktrees = false

    private static let densities = ["compact", "regular", "comfortable"]
    private static let avatarModes: [AvatarStore.Mode] = [.generated, .real, .initials]
    /// The large window sketch's height: the only preview, so it takes the room the tiles' sketches had.
    private static let windowHeight: CGFloat = 260
    /// Between the explanation, the large preview, the tiles and the hint.
    private static let spacing: CGFloat = 14

    /// How tall the body may be without scrolling (`OnboardingCard`); nil until the card has laid out.
    @Environment(\.onboardingBodyRoom) private var bodyRoom
    /// The body's height less the large preview: the explanation and the tiles, with the padding.
    @State private var restHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
            content
        }
        .padding(SettingsMetrics.cardPadding)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
            restHeight = height - (showsPreview ? previewHeight + Self.spacing : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The large preview of the current picks, left out when the window is too short for it and the tiles together,
    /// so the tiles always show without scrolling.
    private var showsPreview: Bool {
        guard let bodyRoom, let restHeight else { return true }
        return (restHeight + previewHeight + Self.spacing).rounded(.up) <= bodyRoom
    }

    /// The large preview's height: the window sketch's, or the sample graph's at the stored row height.
    private var previewHeight: CGFloat {
        switch step {
        case .tabPosition, .layout: Self.windowHeight
        default:
            GraphPreviewView.height(rowHeight: GraphMetrics(density: rowDensity, laneColors: laneColors).rowHeight,
                                    samples: graphSamples)
        }
    }

    /// The sample graph's commits: more lanes for the lane colors, more worktrees for the fade.
    private var graphSamples: GraphPreviewView.SampleSet {
        switch step {
        case .laneColors: .lanes
        case .fadeWorktrees: .worktrees
        default: .basic
        }
    }

    private var explanation: String {
        switch step {
        case .tabPosition: "Where the tabs show: a strip under the toolbar, or a column beside the panels."
        case .layout: "How a repository's panels sit, and where a file you open shows."
        case .avatars: "What each commit's node in the graph shows for its author."
        case .rowHeight: "How tall each row of the commit list is. Compact fits more commits on screen."
        case .laneColors: "How the graph colors its lines: one color per branch, or a rainbow column by column."
        case .fadeWorktrees: "Branches checked out in another worktree can fade, so this tab's own history stands out."
        default: ""
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .tabPosition: tabPositionContent
        case .layout: layoutContent
        case .avatars: avatarsContent
        case .rowHeight: rowHeightContent
        case .laneColors: laneColorsContent
        case .fadeWorktrees: fadeContent
        default: EmptyView()
        }
    }

    // MARK: Picks (stored values, never the DEBUG launch overrides)

    private var storedTabPosition: TabPosition { TabPosition(rawValue: tabPosition) ?? .top }
    private var storedLayout: LayoutPreset { LayoutPreset(rawValue: layoutPreset) ?? .classic }
    private var storedAvatarMode: AvatarStore.Mode { AvatarStore.Mode(rawValue: avatarMode) ?? .generated }

    /// Through `LayoutPreset.choose`, as Settings and the View menu, and only for another preset: choosing Focus while
    /// Focus is stored would switch back to the preset before it.
    private func pickLayout(_ preset: LayoutPreset) {
        if preset != storedLayout { LayoutPreset.choose(preset) }
    }

    // MARK: Steps

    private var tabPositionContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsPreview {
                MiniWindowPreview(tabPosition: storedTabPosition, layout: storedLayout)
                    .frame(height: Self.windowHeight)
                    .frame(maxWidth: .infinity)
            }
            HStack(spacing: 10) {
                ForEach([TabPosition.top, .left], id: \.self) { position in
                    OptionTile(title: position == .left ? "Left" : "Top", isSelected: position == storedTabPosition,
                               action: { tabPosition = position.rawValue })
                }
            }
        }
    }

    private var layoutContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsPreview {
                MiniWindowPreview(tabPosition: storedTabPosition, layout: storedLayout)
                    .frame(height: Self.windowHeight)
                    .frame(maxWidth: .infinity)
            }
            // Two per row, equal widths.
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 2), spacing: 10) {
                ForEach([LayoutPreset.classic, .stacked, .columns, .focus], id: \.self) { preset in
                    OptionTile(title: preset.rawValue.capitalized, isSelected: preset == storedLayout,
                               action: { pickLayout(preset) })
                }
            }
        }
    }

    private var avatarsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsPreview { graph }
            HStack(spacing: 10) {
                ForEach(Self.avatarModes, id: \.self) { mode in
                    OptionTile(title: AppearanceSettings.avatarTitle(mode.rawValue),
                               isSelected: mode == storedAvatarMode,
                               action: { avatarMode = mode.rawValue })
                }
            }
        }
    }

    private var rowHeightContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsPreview { graph }
            HStack(spacing: 10) {
                ForEach(Self.densities, id: \.self) { density in
                    OptionTile(title: density.capitalized, isSelected: density == rowDensity,
                               action: { rowDensity = density })
                }
            }
        }
    }

    private var laneColorsContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsPreview { graph }
            HStack(spacing: 10) {
                ForEach(LaneColors.allCases, id: \.self) { colors in
                    OptionTile(title: colors.title, isSelected: colors == laneColors,
                               action: { laneColors = colors })
                }
            }
        }
    }

    private var fadeContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsPreview { graph }
            HStack(spacing: 10) {
                ForEach([false, true], id: \.self) { fades in
                    OptionTile(title: fades ? "Fade" : "Don't fade", isSelected: fades == fadesWorktrees,
                               action: { fadesWorktrees = fades })
                }
            }
            SettingsHint("Here feature/search, feature/login and release/1.0 are checked out in other worktrees. "
                + "Selecting one of their commits lights that worktree up again.")
        }
    }

    /// The sample graph with the stored picks, the card's full width.
    private var graph: some View {
        GraphPreview(density: rowDensity, laneColors: laneColors, avatarMode: storedAvatarMode,
                     fadeOtherWorktrees: fadesWorktrees, samples: graphSamples)
    }
}

/// An option of a step: its label, with a check and the brand blue fill and ring when selected; the whole tile is
/// the button. The large preview above the tiles shows the pick.
private struct OptionTile: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    private static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 10, style: .continuous) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isSelected {
                    IconImage("checkmark.circle.fill")
                        .foregroundStyle(Palette.primaryFill)
                }
                Text(title)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .font(.callout)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(isSelected ? Palette.primaryFill.opacity(0.14) : Palette.tabFill, in: Self.shape)
            .overlay(Self.shape.strokeBorder(isSelected ? Palette.primaryFill : Palette.surfaceBorder,
                                             lineWidth: isSelected ? 2 : 1))
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
