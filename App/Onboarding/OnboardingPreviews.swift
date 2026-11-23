// The onboarding appearance steps' preview boxes. `GraphPreview`: a set of sample commits (a few rows, or more lanes
// for the lane colors, or more worktrees for the fade) laid out by `GraphLayout` and drawn with the graph's own cells,
// for a row height, lane colors, avatar mode and fade setting given as parameters, never the stored ones; avatars are
// local drawings or bundled samples, never a network load. `MiniWindowPreview`: a window sketch for a tab position
// and a layout preset.
import AppKit
import HistqCore
import SwiftUI

// MARK: - Graph sample

/// A few rows of a sample graph, drawn as the commit graph draws them: the step's large preview of the current picks.
/// Inert: no clicks, tooltips or accessibility elements of its own (the step's tiles under it are the controls).
struct GraphPreview: NSViewRepresentable {
    /// `PrefKey.rowDensity`: "compact", "regular" or "comfortable".
    var density: String
    var laneColors: LaneColors
    var avatarMode: AvatarStore.Mode
    /// `PrefKey.graphFadeOtherWorktrees`: the row of another worktree and its line fade.
    var fadeOtherWorktrees: Bool
    /// The sample commits: the basic set unless the step needs more lanes or worktrees to show its setting.
    var samples: GraphPreviewView.SampleSet = .basic

    func makeNSView(context: Context) -> GraphPreviewView { GraphPreviewView() }

    func updateNSView(_ view: GraphPreviewView, context: Context) {
        view.configure(samples: samples, metrics: GraphMetrics(density: density, laneColors: laneColors),
                       avatarMode: avatarMode, fadeOtherWorktrees: fadeOtherWorktrees)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GraphPreviewView, context: Context) -> CGSize? {
        let metrics = GraphMetrics(density: density, laneColors: laneColors)
        return CGSize(width: proposal.width ?? GraphPreviewView.idealWidth,
                      height: GraphPreviewView.height(rowHeight: metrics.rowHeight, samples: samples))
    }
}

/// `GraphPreview`'s view: one row of cells (badges, graph, message, author, date) per sample commit, on the graph's
/// opaque card color with the cards' edge. Narrow, it drops the date, then the author column, then the branch column
/// once `main` no longer fits whole (a lone check would read as a selected tile); its width goes to the graph.
final class GraphPreviewView: NSView {
    /// The sample graphs a step can show.
    enum SampleSet {
        /// Five commits: a merge, three lanes, one row of another worktree (avatars, row height).
        case basic
        /// Five branches open side by side, so many lane colors show at once.
        case lanes
        /// Three branches checked out in other worktrees beside `main`'s own commits, so their fading shows.
        case worktrees
    }

    /// A sample commit and what the graph would show beside it.
    private struct Sample {
        let commit: Commit
        let badges: [RefBadge]
        /// Checked out in another worktree: faded when the fade is on.
        var isOtherWorktree = false
    }

    /// One row's cells.
    @MainActor private struct RowCells {
        let refs = RefBadgeCellView()
        let graph = GraphCellView()
        let message = GraphTextCellView()
        let author = GraphTextCellView()
        let date = GraphTextCellView()

        var all: [NSView] { [refs, graph, message, author, date] }
    }

    static let idealWidth: CGFloat = 560
    /// Above the first row and under the last.
    private static let padding: CGFloat = 6

    static func height(rowHeight: CGFloat, samples: SampleSet) -> CGFloat {
        CGFloat(Self.samples(samples).count) * rowHeight + 2 * padding
    }

    /// Reserved demo identities (`.invalid` never resolves), so no real person shows up or is looked up.
    private static let ada = ("Ada Lovelace", "ada@example.invalid")
    private static let grace = ("Grace Hopper", "grace@example.invalid")
    private static let alan = ("Alan Turing", "alan@example.invalid")

    private static func samples(_ set: SampleSet) -> [Sample] {
        switch set {
        case .basic: basicSamples
        case .lanes: laneSamples
        case .worktrees: worktreeSamples
        }
    }

    /// Newest first: `main`'s merge of a typo fix, `feature/search` checked out in another worktree (a tip of its own,
    /// so three lanes), the fix, and the two commits they branch from.
    private static let basicSamples: [Sample] = [
        Sample(commit: commit("a5", ["c3", "t4"], ada, 20, "Merge branch 'fix/typos'"), badges: [mainBadge]),
        Sample(commit: commit("f4", ["c3"], grace, 45, "Add the search field"),
               badges: [branch("feature/search", isOtherWorktree: true)], isOtherWorktree: true),
        Sample(commit: commit("t4", ["c3"], alan, 90, "Fix typos in README"), badges: []),
        Sample(commit: commit("c3", ["r1"], ada, 26 * 60, "Show branches in the sidebar"), badges: []),
        Sample(commit: commit("r1", [], grace, 50 * 60, "Initial commit"), badges: []),
    ]

    /// The basic commits and three more, no worktree (a faded row would dull its colors): `main`'s merge of
    /// `fix/typos`, with `feature/search`, `release/1.0` and `feature/login` open beside it, five lanes at once.
    private static let laneSamples: [Sample] = [
        Sample(commit: commit("a5", ["c3", "t4"], ada, 20, "Merge branch 'fix/typos'"), badges: [mainBadge]),
        Sample(commit: commit("f4", ["c3"], grace, 45, "Add the search field"), badges: [branch("feature/search")]),
        Sample(commit: commit("v6", ["c3"], ada, 60, "Bump the version to 1.0"),
               badges: [branch("release/1.0", isRemote: true)]),
        Sample(commit: commit("t4", ["c3"], alan, 90, "Fix typos in README"), badges: [branch("fix/typos")]),
        Sample(commit: commit("l5", ["l2"], alan, 3 * 60, "Add the sign-in form"), badges: [branch("feature/login")]),
        Sample(commit: commit("c3", ["r1"], ada, 26 * 60, "Show branches in the sidebar"), badges: []),
        Sample(commit: commit("l2", ["r1"], grace, 36 * 60, "Sketch the sign-in screen"), badges: []),
        Sample(commit: commit("r1", [], grace, 50 * 60, "Initial commit"), badges: []),
    ]

    /// `main`'s own commits, and two each of `feature/search`, `feature/login` and `release/1.0`, checked out in other
    /// worktrees: only the commits no branch of this tab reaches are the other worktrees' (the fork points stay lit).
    private static let worktreeSamples: [Sample] = [
        Sample(commit: commit("a5", ["c3"], ada, 5, "Show the commit count"), badges: [mainBadge]),
        Sample(commit: commit("s5", ["f4"], grace, 15, "Highlight the matches"),
               badges: [branch("feature/search", isOtherWorktree: true)], isOtherWorktree: true),
        Sample(commit: commit("g6", ["g3"], alan, 35, "Remember the last account"),
               badges: [branch("feature/login", isOtherWorktree: true)], isOtherWorktree: true),
        Sample(commit: commit("f4", ["c3"], grace, 45, "Add the search field"), badges: [], isOtherWorktree: true),
        Sample(commit: commit("v5", ["v2"], ada, 70, "Bump the version to 1.0"),
               badges: [branch("release/1.0", isOtherWorktree: true)], isOtherWorktree: true),
        Sample(commit: commit("g3", ["c3"], alan, 2 * 60, "Add the sign-in form"), badges: [], isOtherWorktree: true),
        Sample(commit: commit("c3", ["r1"], ada, 26 * 60, "Show branches in the sidebar"), badges: []),
        Sample(commit: commit("v2", ["r1"], grace, 30 * 60, "Write the release notes"), badges: [],
               isOtherWorktree: true),
        Sample(commit: commit("r1", [], grace, 50 * 60, "Initial commit"), badges: []),
    ]

    /// The checked-out branch, local and on `origin`.
    private static let mainBadge = RefBadge(kind: .branch(isLocal: true, isRemote: true, isHead: true), name: "main",
                                            remote: "origin")

    private static func branch(_ name: String, isRemote: Bool = false, isOtherWorktree: Bool = false) -> RefBadge {
        RefBadge(kind: .branch(isLocal: true, isRemote: isRemote, isHead: false), name: name,
                 remote: isRemote ? "origin" : nil, isOtherWorktree: isOtherWorktree)
    }

    private static func commit(_ hash: String, _ parents: [String], _ author: (String, String), _ minutesAgo: Int,
                               _ subject: String) -> Commit
    {
        let date = reference.addingTimeInterval(TimeInterval(-60 * minutesAgo))
        return Commit(hash: hash, parents: parents, authorName: author.0, authorEmail: author.1, authorDate: date,
                      committerDate: date, subject: subject, body: "")
    }

    /// A fixed moment, so the dates never change between two looks.
    nonisolated private static let reference = Calendar.current.date(
        from: DateComponents(year: 2026, month: 11, day: 20, hour: 16, minute: 30)) ?? .now

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: Locale.current.identifier)
        formatter.dateFormat = "MM/dd HH:mm"
        return formatter
    }()

    private var metrics = GraphMetrics(density: "regular")
    /// The set `samples` and `cells` show; nil until the first `configure`.
    private var sampleSet: SampleSet?
    private var samples: [Sample] = []
    private var cells: [RowCells] = []
    private var rows: [GraphRow] = []
    private var logLanes = 1
    /// The coloring `rows` were laid out with.
    private var coloring: GraphLayout.Coloring?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Palette.graphSurface.cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        // The graph's card edge: the fill is close to the step's card around it.
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(Palette.sheetCardBorder).cgColor
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Inert: clicks pass through to the step under the preview.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The sample's cells are not the user's commits: nothing for VoiceOver to read here.
    override func accessibilityChildren() -> [Any]? { [] }

    /// Makes the rows' cells when the sample set changes, lays the samples out again when it or the coloring changes,
    /// then sets every cell from the parameters.
    func configure(samples set: SampleSet, metrics: GraphMetrics, avatarMode: AvatarStore.Mode,
                   fadeOtherWorktrees: Bool)
    {
        self.metrics = metrics
        if set != sampleSet {
            sampleSet = set
            samples = Self.samples(set)
            for row in cells { for cell in row.all { cell.removeFromSuperview() } }
            cells = samples.map(makeCells)
            self.coloring = nil
        }
        let coloring = metrics.laneColors.coloring
        if coloring != self.coloring {
            var layout = GraphLayout(coloring: coloring)
            rows = layout.append(samples.map(\.commit))
            logLanes = rows.map(\.width).max() ?? 1
            self.coloring = coloring
        }
        // A commit's lines to its parents belong to it, by its index among the samples.
        let fadedOwners = Set(samples.indices.filter { fadeOtherWorktrees && samples[$0].isOtherWorktree }
            .map(Int32.init))
        for (index, sample) in samples.enumerated() where index < rows.count {
            let row = cells[index]
            let isFaded = fadedOwners.contains(Int32(index))
            row.refs.color = rows[index].color
            row.refs.isFaded = isFaded
            row.refs.metrics = metrics
            row.graph.row = rows[index]
            row.graph.metrics = metrics
            row.graph.logLanes = logLanes
            row.graph.isFaded = isFaded
            row.graph.isSegmentFaded = { fadedOwners.contains($0) }
            row.graph.avatar = sample.commit.isMerge ? nil : avatar(sample.commit, mode: avatarMode)
            for text in [row.message, row.author, row.date] {
                text.textSize = metrics.textSize
                text.isDimmed = isFaded
            }
            for cell in row.all { cell.needsDisplay = true }
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    /// One sample's cells, added to the view.
    private func makeCells(_ sample: Sample) -> RowCells {
        let row = RowCells()
        for cell in row.all { addSubview(cell) }
        row.message.text = sample.commit.subject
        row.message.tone = .primary
        row.author.text = sample.commit.authorName
        row.author.tone = .secondary
        row.date.text = Self.dateFormatter.string(from: sample.commit.authorDate)
        row.date.tone = .secondary
        row.refs.badges = sample.badges
        row.graph.hasRefs = !sample.badges.isEmpty
        row.graph.hasHeadRef = sample.badges.contains { $0.isHead }
        row.graph.node = sample.commit.isMerge
            ? .merge : .commit(initials: GraphRowDrawing.initials(of: sample.commit.authorName))
        return row
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric,
               height: Self.height(rowHeight: metrics.rowHeight, samples: sampleSet ?? .basic))
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let date: CGFloat = width >= 540 ? 86 : 0
        let author: CGFloat = width >= 440 ? 96 : 0
        var refs = min(150, max(44, (width * 0.26).rounded()))
        var graph = metrics.width(lanes: logLanes)
        var message = max(0, width - refs - graph - author - date)
        // Too narrow for a readable subject (a tile three across): the graph's row bands take the room, not a lone "…".
        if message < 48 {
            graph += message
            message = 0
        }
        // The checked-out branch's badge cut down to its check reads as the tile's selection mark: the column goes
        // whole, its width to the graph (after the subject's test, so dropping it never brings a cut subject back).
        if !headBadgeFits(in: refs) {
            graph += refs
            refs = 0
        }
        for row in cells {
            let hasRefs = refs > 0 && !row.refs.badges.isEmpty
            if row.graph.hasRefs != hasRefs {
                row.graph.hasRefs = hasRefs
                row.graph.needsDisplay = true
            }
        }
        for (index, row) in cells.enumerated() {
            let y = Self.padding + CGFloat(index) * metrics.rowHeight
            var x: CGFloat = 0
            for (cell, columnWidth) in zip(row.all, [refs, graph, message, author, date]) {
                cell.frame = CGRect(x: x, y: y, width: columnWidth, height: metrics.rowHeight)
                cell.isHidden = columnWidth == 0
                x += columnWidth
            }
            // A cut text sets its tooltip on each resize: the sample has none.
            for text in [row.message, row.author, row.date] { text.toolTip = nil }
        }
    }

    /// Whether the rows with the checked-out branch's badge draw every badge whole in a column `width` wide, at the
    /// current row height and text size.
    private func headBadgeFits(in width: CGFloat) -> Bool {
        cells.filter { $0.refs.badges.contains(where: \.isHead) }.allSatisfy { row in
            row.refs.frame.size = CGSize(width: width, height: metrics.rowHeight)
            return row.refs.showsAllBadges
        }
    }

    /// Generated or initials: the app's own drawings. Real: bundled samples standing in for downloaded pictures (a
    /// GitHub avatar, a person), so the preview never sends anything.
    private func avatar(_ commit: Commit, mode: AvatarStore.Mode) -> NSImage? {
        guard mode == .real else {
            return AvatarStore.shared.localAvatar(mode: mode, email: commit.authorEmail, name: commit.authorName)
        }
        return commit.authorEmail == Self.grace.1 ? Self.gitHubSample : Self.personSample
    }

    /// The GitHub logo, white on the generated avatars' dark disc.
    private static let gitHubSample: NSImage? = {
        guard let logo = NSImage(named: AvatarStore.Provider.github.asset) else { return nil }
        return disc(Palette.graphNodeText) { rect in
            let mark = rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.2)
            NSImage(size: mark.size, flipped: false) { markRect in
                logo.draw(in: markRect)
                NSColor.white.setFill()
                markRect.fill(using: .sourceAtop)
                return true
            }.draw(in: mark)
        }
    }()

    /// A white person on a neutral grey, as an address book shows a contact without a picture.
    private static let personSample: NSImage? = {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        guard let person = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }
        return disc(Palette.graphStash) { rect in
            let size = person.size
            person.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.minY + rect.height * 0.12,
                                   width: size.width, height: size.height))
        }
    }()

    /// A 20 pt square avatar on `background` (the node clips it to its circle), its mark drawn by `mark`.
    private static func disc(_ background: NSColor, mark: @escaping (CGRect) -> Void) -> NSImage {
        NSImage(size: NSSize(width: 20, height: 20), flipped: false) { rect in
            background.setFill()
            rect.fill()
            mark(rect)
            return true
        }
    }
}

// MARK: - Mini window

/// A sketch of a Histq window: the toolbar, the tabs on top or on the left joined to the page's sheet, and a repo
/// tab's panels in `layout`, each labeled. Classic, Stacked and Columns show where an open file goes. Drawn at a fixed
/// size and scaled to fit its frame, keeping its proportions.
struct MiniWindowPreview: View {
    var tabPosition: TabPosition
    var layout: LayoutPreset

    /// Wide: at the step's preview height it fills the onboarding card's width (the graph panel takes the extra).
    private static let size = CGSize(width: 448, height: 200)
    private static let gap: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let scale = min(proxy.size.width / Self.size.width, proxy.size.height / Self.size.height)
            window
                .frame(width: Self.size.width, height: Self.size.height)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: Self.size.width * scale, height: Self.size.height * scale, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(Self.size.width / Self.size.height, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var window: some View {
        VStack(spacing: 0) {
            toolbar
            if tabPosition == .top {
                topTabs
                sheet.padding([.horizontal, .bottom], Self.gap)
            } else {
                HStack(spacing: 0) {
                    leftTabs
                    sheet.padding([.trailing, .bottom], Self.gap)
                }
                .padding(.top, Self.gap)
            }
        }
        .background(Palette.bgCard)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.surfaceBorder))
    }

    /// The traffic lights and a few toolbar buttons.
    private var toolbar: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in
                Circle().fill(Palette.switchOffFill).frame(width: 7, height: 7)
            }
            Spacer()
            ForEach(0..<4, id: \.self) { _ in
                Capsule().fill(Palette.tabFill).frame(width: 18, height: 9)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
    }

    /// Three tabs, the first selected: the sheet's fill, joined to the sheet under it.
    private var topTabs: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                tabLabel(index)
                    .frame(width: 58, height: 16)
                    .background(index == 0 ? Palette.sheet : Palette.tabFill,
                                in: UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5,
                                                           style: .continuous))
            }
            Spacer()
        }
        .padding(.horizontal, Self.gap + 6)
    }

    /// The vertical tabs: three rows, the first selected and joined to the sheet on its right.
    private var leftTabs: some View {
        VStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { index in
                tabLabel(index)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 6)
                    .frame(height: 16)
                    .background(index == 0 ? Palette.sheet : Color.clear,
                                in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5,
                                                           style: .continuous))
            }
            Spacer()
        }
        .frame(width: 58)
        .padding(.leading, Self.gap)
        .padding(.top, 6)
    }

    private func tabLabel(_ index: Int) -> some View {
        Text(["Histq", "website", "notes"][index])
            .font(.system(size: 7, weight: index == 0 ? .semibold : .regular))
            .foregroundStyle(index == 0 ? .primary : .secondary)
            .lineLimit(1)
    }

    /// The page's sheet and the repo tab's panels on it.
    private var sheet: some View {
        HStack(spacing: Self.gap) {
            if layout != .focus {
                panel("Sidebar").frame(width: 52)
            }
            graphColumn
            if layout != .focus {
                panel("Detail").frame(width: 64)
            }
            if layout == .columns {
                panel("File", note: "opens here", tone: .file).frame(width: 64)
            }
        }
        .padding(Self.gap)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.sheet, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// Panel 2: the graph, with the open file over it (Classic, Focus) or in a pane under it (Stacked).
    @ViewBuilder private var graphColumn: some View {
        switch layout {
        case .stacked:
            VStack(spacing: Self.gap) {
                panel("Graph")
                panel("File", note: "opens here", tone: .file).frame(height: 54)
            }
        case .classic, .focus:
            panel("Graph", note: "a file opens over it")
        case .columns:
            panel("Graph")
        }
    }

    private enum Tone {
        case normal, file
    }

    /// A labeled card; the file's place is tinted with the brand blue.
    private func panel(_ title: String, note: String? = nil, tone: Tone = .normal) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.primary)
            if let note {
                Text(note)
                    .font(.system(size: 6.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .lineLimit(2)
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(tone == .file ? Palette.primaryFill.opacity(0.22) : Palette.sheetCard,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(tone == .file ? Palette.primaryFill.opacity(0.6) : Palette.sheetCardBorder))
    }
}
