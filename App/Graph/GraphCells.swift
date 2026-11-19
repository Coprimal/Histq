// The graph table's cells other than the lanes: the ref badges (joined to their node by a line in the lane color; a
// branch with an open pull request carries its "#N" chip, which a click opens), the text columns, the selected row's
// neutral capsule and the column header. Every cell draws itself in `draw(_:)` with cached fonts, attributes and
// symbols; text is truncated with "…".
import AppKit
import HistqCore

// MARK: - Ref badges

/// One label in the BRANCH / TAG column.
struct RefBadge: Hashable {
    enum Kind: Hashable {
        /// A local branch (laptop icon), with the cloud icon when its upstream points at the same commit. `isHead`
        /// adds a check in front.
        case branch(isLocal: Bool, isRemote: Bool, isHead: Bool)
        case tag
        /// A detached HEAD.
        case head
        /// Another worktree's WIP row: the worktree's folder name.
        case worktree
    }

    /// An open pull request whose head is this branch: drawn as a chip at the badge's end.
    struct PullRequest: Hashable, Sendable {
        let number: Int
        let isDraft: Bool
    }

    let kind: Kind
    /// The full ref name (`origin/feature`): the menus, the drag and the drop use it.
    let name: String
    /// The name drawn when it differs from `name`: a remote branch without its remote (`remoteLabel`).
    var label: String?
    /// Commits ahead of / behind the upstream (local branches).
    var ahead = 0
    var behind = 0
    var pullRequest: PullRequest?
    /// The faded badge of the branch a selected commit is on (`BranchAttribution`), drawn with its line at
    /// `Palette.graphGhostAlpha`; not a menu, drag or drop target.
    var isGhost = false
    /// The remote the cloud icon stands for (`origin`): its owner's logo replaces the cloud once loaded
    /// (`RefBadgeCellView.remoteAvatars`).
    var remote: String?

    /// The name drawn in the badge.
    var shownName: String { label ?? name }

    /// The checked-out branch, or a detached HEAD.
    var isHead: Bool {
        switch kind {
        case .branch(_, _, let isHead): isHead
        case .head: true
        case .tag, .worktree: false
        }
    }

    /// The badges of every labeled commit, in row order: HEAD's branch (or a detached HEAD) first, then local
    /// branches, remote branches that are not merged into a local badge, then tags. Built once per refs read (and per
    /// change of `pullRequests`, the store's `branchPullRequests`: a remote branch's pull request by its name, which a
    /// local branch gets through its upstream; and per change of `remotes`, the repo's remote names).
    static func badges(for refs: Refs, pullRequests: [String: PullRequest] = [:], remotes: [String] = [])
        -> [String: [RefBadge]]
    {
        var byCommit: [String: [RefBadge]] = [:]
        let single = singleRemote(refs, remotes: remotes)
        let remoteBranches = Dictionary(refs.remoteBranches.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var mergedRemotes = Set<String>()
        if case .detached(let commit) = refs.head {
            byCommit[commit, default: []].append(RefBadge(kind: .head, name: "HEAD"))
        }
        for branch in refs.localBranches.sorted(by: { $0.isHead && !$1.isHead }) {
            var tracked: RemoteBranch?
            if let upstream = branch.upstream, let remote = remoteBranches[upstream], remote.commit == branch.commit {
                tracked = remote
                mergedRemotes.insert(upstream)
            }
            byCommit[branch.commit, default: []].append(RefBadge(
                kind: .branch(isLocal: true, isRemote: tracked != nil, isHead: branch.isHead), name: branch.name,
                ahead: branch.ahead, behind: branch.behind, pullRequest: branch.upstream.flatMap { pullRequests[$0] },
                remote: tracked?.remote))
        }
        for remote in refs.remoteBranches where !mergedRemotes.contains(remote.name) {
            byCommit[remote.commit, default: []].append(RefBadge(
                kind: .branch(isLocal: false, isRemote: true, isHead: false), name: remote.name,
                label: remoteLabel(of: remote, singleRemote: single), pullRequest: pullRequests[remote.name],
                remote: remote.remote))
        }
        for tag in refs.tags {
            byCommit[tag.commit ?? tag.target, default: []].append(RefBadge(kind: .tag, name: tag.name))
        }
        return byCommit
    }

    /// The repo's only remote, nil when it has several (or none): from `git remote` once it is read (a remote's name
    /// may hold a "/", which the remote branches' own `remote` cuts at), else from the remote branches.
    static func singleRemote(_ refs: Refs, remotes: [String]) -> String? {
        let names = remotes.isEmpty ? Array(Set(refs.remoteBranches.map(\.remote))) : remotes
        return names.count == 1 ? names[0] : nil
    }

    /// A remote branch's badge text when the repo has a single remote: its name without the remote (`feature` for
    /// `origin/feature`, the cloud icon telling it is remote). Nil (the full name) when there
    /// are several remotes.
    static func remoteLabel(of branch: RemoteBranch, singleRemote: String?) -> String? {
        guard let singleRemote else { return nil }
        let prefix = singleRemote + "/"
        guard branch.name.hasPrefix(prefix), branch.name.count > prefix.count else { return nil }
        return String(branch.name.dropFirst(prefix.count))
    }
}

/// The BRANCH / TAG column's cell: the row's badges from the left, as many as fit whole, then "+N" for the rest. When
/// even the first does not fit whole it steps down (`Level`) in the room "+N" leaves: its name without ↑↓ and the pull
/// request chip, cut with "…" (at least 3 characters), then its icons alone (HEAD's check, the laptop and
/// the cloud always stay); "+N" always stays. Nothing is drawn outside a badge, or past the cell. A line in the lane
/// color runs from the last badge to the column's right edge, where the graph cell continues it to the node. With
/// `stack` set it is the hover overlay instead (`GraphTableController`): every badge whole, one under the other; the
/// table routes its clicks, menus, drags and drops to them.
final class RefBadgeCellView: NSView {
    var badges: [RefBadge] = []
    /// The row's lane color (`GraphRow.color`).
    var color = 0
    /// The logos of the remotes' owners by remote name (`AvatarStore.ownerAvatar`): drawn in place of the cloud.
    var remoteAvatars: [String: NSImage] = [:]
    var metrics = GraphMetrics(density: "regular")
    /// Set on the hover overlay: the hovered row's height, whether the stack grows up from that row (near the bottom of
    /// the view), and where its line to the node ends (the column's right edge, in the overlay).
    var stack: Stack?
    /// A cell under the hover overlay draws nothing: its cut badge and "+N" would show beside the stack.
    var isCovered = false {
        didSet { if isCovered != oldValue { needsDisplay = true } }
    }
    /// The stack's badge under the pointer (an index in `badges`): drawn lit.
    var hovered: Int? {
        didSet { if hovered != oldValue { needsDisplay = true } }
    }

    struct Stack {
        var rowHeight: CGFloat
        var upward: Bool
        var lineEnd: CGFloat
    }

    /// A badge's name attributes at the metrics' text size, and the counts' attributes.
    private func textAttributes(_ badge: RefBadge) -> [NSAttributedString.Key: Any] {
        (badge.isHead ? Style.headText : Style.text)[metrics.textSize] ?? [:]
    }
    private var countAttributes: [NSAttributedString.Key: Any] { Style.count[metrics.textSize] ?? [:] }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// The table under the hover stack keeps every event, and routes those on it to its badges (`GraphTableController`).
    override func hitTest(_ point: NSPoint) -> NSView? { stack == nil ? super.hitTest(point) : nil }

    @MainActor
    private enum Style {
        /// Between two badges of the hover stack.
        static let stackGap: CGFloat = 2
        /// The stack's badges under the row's own keep this part of their fill's opacity; the hovered one gets this
        /// much white over its fill.
        static let faintFill: CGFloat = 0.5
        static let litFill: CGFloat = 0.22
        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        /// The name's attributes by text size: normal weight, 12 pt at Regular (user, 2026-11-18: a bit smaller than
        /// the body text), in pure white like the checked-out branch's so it reads sharp (user, 2026-11-18).
        static let text: [TextSize: [NSAttributedString.Key: Any]] = Dictionary(
            uniqueKeysWithValues: TextSize.allCases.map {
                ($0, [.font: NSFont.systemFont(ofSize: $0.scaled(12)), .foregroundColor: Palette.graphBadgeText,
                      .paragraphStyle: paragraph])
            })
        /// The checked-out branch's name: the body text (13 pt at Regular) in pure white, so it stands out from the
        /// others without a border (user, 2026-11-18).
        static let headText: [TextSize: [NSAttributedString.Key: Any]] = Dictionary(
            uniqueKeysWithValues: TextSize.allCases.map {
                ($0, [.font: $0.bodyNSFont, .foregroundColor: Palette.graphBadgeText, .paragraphStyle: paragraph])
            })
        /// ↑↓, "#N" and "+N" by text size: the counts' font (11 pt at Regular).
        static let count: [TextSize: [NSAttributedString.Key: Any]] = Dictionary(
            uniqueKeysWithValues: TextSize.allCases.map {
                ($0, [.font: $0.countNSFont, .foregroundColor: Palette.graphBadgeText])
            })
        static let leading: CGFloat = 6
        static let padding: CGFloat = 7
        static let gap: CGFloat = 4
        static let iconGap: CGFloat = 3
        /// The pull request chip's icon slot. The laptop, cloud and tag get `refIcon`: bigger, so they read at a glance
        /// (user, 2026-11-13); the text and the badge height stay. HEAD's check gets `headIcon`, the biggest (user,
        /// 2026-11-17: it tells at a glance which branch the tab has checked out).
        static let icon: CGFloat = 12
        static let refIcon: CGFloat = 15
        static let headIcon: CGFloat = 16
        static let radius: CGFloat = 5
        /// A badge's height, less in a row too short for it (compact).
        static let height: CGFloat = 22
        /// Room kept for the line to the node.
        static let trailing: CGFloat = 8
        /// The pull request chip: inset from the badge's edges, its own padding, and its corner radius.
        static let chipInset: CGFloat = 2
        static let chipPadding: CGFloat = 5
        static let chipRadius: CGFloat = 4
    }

    /// A glyph's slot width: HEAD's check gets the biggest.
    private static func iconWidth(_ name: String) -> CGFloat {
        name == headIcon ? Style.headIcon : Style.refIcon
    }

    /// The check of the branch checked out (or of a detached HEAD): always drawn, in front of the name.
    private static let headIcon = "checkmark.circle.fill"

    /// SF Symbols in the badge text color (pure white on every badge, like its name: user, 2026-11-18), drawn at a
    /// size that fills their slot (the cloud and tag are 16 pt wide at 12 pt, scaled down to 15; at 10.5 pt they
    /// stayed 14). A Lucide icon (24 pt) is tinted the same color.
    @MainActor private static func symbol(_ name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        if name.hasPrefix("lucide-") {
            let image = NSImage.icon(name, accessibilityDescription: nil, size: 24).map(tinted)
            symbols[name] = image
            return image
        }
        let isCheck = name == headIcon
        // HEAD's check stands out: a solid white disc with a bold check in the graph's dark surface.
        let colors = isCheck ? [Palette.graphSurface, Palette.graphBadgeText] : [Palette.graphBadgeText]
        let configuration = NSImage.SymbolConfiguration(pointSize: isCheck ? 13.5 : 12, weight: isCheck ? .bold : .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: colors))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        symbols[name] = image
        return image
    }

    @MainActor private static var symbols: [String: NSImage?] = [:]

    /// A template image (Lucide, or a monochrome symbol) filled with the badge text color: it would draw black.
    private static func tinted(_ template: NSImage) -> NSImage {
        NSImage(size: template.size, flipped: false) { rect in
            template.draw(in: rect)
            Palette.graphBadgeText.setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    private static func icons(_ badge: RefBadge) -> (leading: [String], trailing: [String]) {
        switch badge.kind {
        case .branch(let isLocal, let isRemote, let isHead):
            return (isHead ? [headIcon] : [],
                    (isLocal ? ["lucide-laptop-minimal"] : []) + (isRemote ? ["cloud"] : []))
        case .tag: return (["tag"], [])
        case .head: return ([headIcon], [])
        case .worktree: return (["folder"], [])
        }
    }

    private static func aheadBehind(_ badge: RefBadge) -> String? {
        var parts: [String] = []
        if badge.ahead > 0 { parts.append("↑\(badge.ahead)") }
        if badge.behind > 0 { parts.append("↓\(badge.behind)") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// The pull request chip's width: its icon and "#N".
    private func pullChipWidth(_ pull: PullRequestChip) -> CGFloat {
        2 * Style.chipPadding + Style.icon + Style.iconGap
            + ceil((pull.text as NSString).size(withAttributes: countAttributes).width)
    }

    /// The pull request icon, in the chip and, on a badge drawn without it, at the badge's right end.
    private static let pullIcon = "lucide-git-pull-request-arrow"

    /// The icons a badge always keeps, on the side each has in the full badge: `icons` with the pull request icon
    /// last, for a badge drawn without its chip (user, 2026-11-16: the laptop and the cloud never give way;
    /// 2026-11-17: nor the pull request icon, which the chip with "#N" shows only on a whole badge, as in the hover
    /// stack; nor HEAD's check).
    private static func refIcons(_ badge: RefBadge) -> (leading: [String], trailing: [String]) {
        let all = icons(badge)
        return badge.pullRequest == nil ? all : (all.leading, all.trailing + [pullIcon])
    }

    /// The icons drawn at `level`, on the side each has in the full badge.
    private static func icons(_ badge: RefBadge, at level: Level) -> (leading: [String], trailing: [String]) {
        level == .full ? icons(badge) : refIcons(badge)
    }

    /// The icons drawn alone at `.icon` (`refIcons`) or `.check` (HEAD's check).
    private static func iconsAlone(_ badge: RefBadge, at level: Level) -> [String] {
        if level == .check { return [headIcon] }
        let (leading, trailing) = refIcons(badge)
        return leading + trailing
    }

    /// The width of `names` side by side.
    private static func iconsWidth(_ names: [String]) -> CGFloat {
        names.reduce(0) { $0 + iconWidth($1) } + CGFloat(max(0, names.count - 1)) * Style.iconGap
    }

    /// How much of a badge is drawn.
    fileprivate enum Level: Equatable {
        /// Icons, name, ↑↓ and the pull request chip.
        case full
        /// The name (cut with "…" when short) without ↑↓, the pull request chip giving way to its icon.
        case name
        /// The icons it always keeps (`refIcons`) alone: one in a square.
        case icon
        /// HEAD's check alone in a square, when not even `refIcons` fit: the checked-out branch never loses it.
        case check
    }

    /// The badge's level and width in `room` points of a row whose badges are `height` high; nil when not even its
    /// icons fit.
    private func fit(_ badge: RefBadge, room: CGFloat, height: CGFloat) -> (level: Level, width: CGFloat)? {
        let size = widths(badge)
        if size.chrome + size.name <= room { return (.full, size.chrome + size.name) }
        let (leading, trailing) = Self.refIcons(badge)
        let chrome = 2 * Style.padding + (leading + trailing).reduce(0) { $0 + Self.iconWidth($1) + Style.iconGap }
        if chrome + minimumName(badge) <= room { return (.name, min(room, chrome + size.name)) }
        // As much room around the icons as a single one has in its square.
        for level in [Level.icon, .check] where level == .icon || leading.contains(Self.headIcon) {
            let width = Self.iconsWidth(Self.iconsAlone(badge, at: level)) + height - Style.refIcon
            if width <= room { return (level, width) }
        }
        return nil
    }

    /// The least of a name shown: its first 3 characters and "…" (with a point to spare, so AppKit keeps 3), or all
    /// of a shorter name.
    private func minimumName(_ badge: RefBadge) -> CGFloat {
        let attributes = textAttributes(badge)
        let name = ceil((badge.shownName as NSString).size(withAttributes: attributes).width)
        guard badge.shownName.count > 3 else { return name }
        let cut = ceil((String(badge.shownName.prefix(3)) + "…" as NSString)
            .size(withAttributes: attributes).width) + 1
        return min(name, cut)
    }

    /// The badge's width without its name, and its name's width. A pull request chip takes the place of the badge's
    /// right padding, `chipInset` from its edge.
    private func widths(_ badge: RefBadge) -> (chrome: CGFloat, name: CGFloat) {
        let (leading, trailing) = Self.icons(badge)
        var chrome = 2 * Style.padding + (leading + trailing).reduce(0) { $0 + Self.iconWidth($1) + Style.iconGap }
        if let counts = Self.aheadBehind(badge) {
            chrome += Style.iconGap + ceil((counts as NSString).size(withAttributes: countAttributes).width)
        }
        if let pull = badge.pullRequest.map(PullRequestChip.init) {
            chrome += Style.iconGap + pullChipWidth(pull) + Style.chipInset - Style.padding
        }
        let name = ceil((badge.shownName as NSString).size(withAttributes: textAttributes(badge)).width)
        return (chrome, name)
    }

    /// Where the badges are drawn: each shown badge's frame, the "+N" chip, and where the line to the node starts.
    private struct Layout {
        var badges: [(index: Int, rect: CGRect, level: Level)] = []
        var chip: (text: String, rect: CGRect)?
        var lineStart: CGFloat = 0
        /// Where the line runs (the hover stack's first row); nil: the cell's middle, to its right edge.
        var lineY: CGFloat?
        var lineEnd: CGFloat?
    }

    /// Whether every badge is drawn whole: else the row's badges show as a stack on hover.
    var showsAllBadges: Bool {
        guard let layout = layout() else { return true }
        return layout.badges.count == badges.count && layout.badges.allSatisfy { $0.level == .full }
    }

    /// The hover overlay's size for these badges: one row, then a badge and its gap for each other one; as wide as
    /// the widest badge whole, and at least to `lineEnd`.
    func stackSize(rowHeight: CGFloat, lineEnd: CGFloat) -> CGSize {
        let height = min(Style.height, rowHeight - 2 * metrics.bandInset)
        return CGSize(width: max(lineEnd, Style.leading + stackWidth + Style.trailing),
                      height: rowHeight + CGFloat(badges.count - 1) * (height + Style.stackGap))
    }

    private var stackWidth: CGFloat {
        badges.map { let size = widths($0); return size.chrome + size.name }.max() ?? 0
    }

    /// Every badge whole and as wide as the widest, one under the other from the hovered row (or above it, upward).
    private func stackLayout(_ stack: Stack) -> Layout {
        var layout = Layout()
        let height = min(Style.height, stack.rowHeight - 2 * metrics.bandInset)
        let width = stackWidth
        let rowY = stack.upward ? bounds.height - stack.rowHeight : 0
        let y = rowY + (stack.rowHeight - height) / 2
        for index in badges.indices {
            let step = CGFloat(index) * (height + Style.stackGap)
            layout.badges.append((index, CGRect(x: Style.leading, y: stack.upward ? y - step : y + step,
                                                width: width, height: height), .full))
        }
        layout.lineStart = Style.leading + width
        layout.lineY = rowY + stack.rowHeight / 2
        layout.lineEnd = stack.lineEnd
        return layout
    }

    /// The index of the badge drawn at `point` (in this view); in the stack, a gap counts for the badges beside it, so
    /// the pointer moving down the list is always on one. A covered cell draws no badge, so it has none to hit.
    func badgeIndex(at point: CGPoint) -> Int? {
        guard !isCovered, let layout = layout(), bounds.contains(point) else { return nil }
        let slack = stack == nil ? 0 : Style.stackGap / 2
        return layout.badges.first { $0.rect.insetBy(dx: 0, dy: -slack).contains(point) }?.index
    }

    /// The badge drawn at `point` (in this view), for its menu and its drag; never a ghost.
    func badge(at point: CGPoint) -> RefBadge? {
        badgeIndex(at: point).map { badges[$0] }.flatMap { $0.isGhost ? nil : $0 }
    }

    /// The pull request whose chip is drawn at `point` (in this view): a click there opens it. A covered cell draws
    /// no chip.
    func pullRequest(at point: CGPoint) -> RefBadge.PullRequest? {
        guard !isCovered, let layout = layout() else { return nil }
        // Only a chip that is drawn: a square or a cut name has none.
        for (index, rect, level) in layout.badges where level == .full {
            guard let pull = badges[index].pullRequest, chipRect(PullRequestChip(pull), in: rect).contains(point)
            else { continue }
            return pull
        }
        return nil
    }

    /// The chip's frame inside its badge's: at the trailing end, `chipInset` from the badge's edges.
    private func chipRect(_ pull: PullRequestChip, in rect: CGRect) -> CGRect {
        let width = min(pullChipWidth(pull), rect.width - 2 * Style.chipInset)
        return CGRect(x: rect.maxX - Style.chipInset - width, y: rect.minY + Style.chipInset,
                      width: max(0, width), height: max(0, rect.height - 2 * Style.chipInset))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !isCovered, let layout = layout(), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        // The stack lies over other rows: its see-through fills go on the graph's surface, as in `dragImage`, one
        // piece under every badge and the gaps between them, so nothing of the rows below shows through.
        if stack != nil {
            let all = layout.badges.reduce(CGRect.null) { $0.union($1.rect) }
            Palette.graphSurface.setFill()
            context.addPath(CGPath(roundedRect: all, cornerWidth: Style.radius, cornerHeight: Style.radius,
                                   transform: nil))
            context.fillPath()
        }
        for (index, rect, level) in layout.badges {
            let badge = badges[index]
            // A ghost is faded as a whole (one transparency layer), so its fill and text do not show through each other.
            if badge.isGhost {
                context.saveGState()
                context.setAlpha(Palette.graphGhostAlpha)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            // In the stack: the row's own badge as it is, those under it fainter, the hovered one lit.
            let fill: Fill = stack == nil ? .normal
                : index == hovered && !badge.isGhost ? .lit : index == 0 ? .normal : .faint
            drawBadge(badge, in: rect, level: level, fill: fill, context: context)
            if badge.isGhost {
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        if let chip = layout.chip {
            drawChip(chip.text, in: chip.rect, context: context)
        }

        // The line to the node: faded too when only a ghost is shown.
        let lineY = layout.lineY ?? bounds.midY
        let lineEnd = layout.lineEnd ?? bounds.maxX
        guard layout.lineStart < lineEnd else { return }
        let lane = Palette.graphLanes[color % Palette.graphLanes.count]
        // Not beside "+N" alone (no badge drawn): that line is the row's own.
        let onlyGhosts = !layout.badges.isEmpty && layout.badges.allSatisfy { badges[$0.index].isGhost }
        (onlyGhosts ? lane.withAlphaComponent(Palette.graphGhostAlpha) : lane).setStroke()
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: layout.lineStart, y: lineY))
        context.addLine(to: CGPoint(x: lineEnd, y: lineY))
        context.strokePath()
    }

    private func layout() -> Layout? {
        guard !badges.isEmpty else { return nil }
        if let stack { return stackLayout(stack) }
        var layout = Layout()
        let height = min(Style.height, bounds.height - 2 * metrics.bandInset)
        let y = (bounds.height - height) / 2
        let available = bounds.width - Style.leading - Style.trailing
        let sizes = badges.map(widths)

        // How many badges fit whole, keeping room for "+N" when some are left out.
        var shown = badges.count
        var total = sizes.reduce(0) { $0 + $1.chrome + $1.name } + CGFloat(badges.count - 1) * Style.gap
        while shown > 1, total + (shown < badges.count ? chipWidth(badges.count - shown) + Style.gap : 0) > available {
            total -= sizes[shown - 1].chrome + sizes[shown - 1].name + Style.gap
            shown -= 1
        }
        var x = Style.leading
        func place(_ index: Int, _ level: Level, _ width: CGFloat) {
            layout.badges.append((index, CGRect(x: x, y: y, width: width, height: height), level))
            x += width + Style.gap
        }
        let showsChip = shown < badges.count
        if shown > 1 || shown == badges.count && sizes[0].chrome + sizes[0].name <= available {
            for index in 0..<shown { place(index, .full, sizes[index].chrome + sizes[index].name) }
        } else {
            // Only the first badge is shown, and not whole: it steps down in the room "+N" leaves it (user,
            // 2026-11-16: "+N" always stays, only the name gives way). When not even its square fits, "+N" counts it.
            let chip = showsChip ? chipWidth(badges.count - 1) + Style.gap : 0
            if let fit = fit(badges[0], room: available - chip, height: height) {
                place(0, fit.level, fit.width)
                shown = 1
            } else {
                shown = 0
                guard showsChip else {
                    layout.lineStart = Style.leading
                    return layout
                }
            }
        }
        if showsChip {
            let width = chipWidth(badges.count - shown)
            layout.chip = ("+\(badges.count - shown)", CGRect(x: x, y: y, width: width, height: height))
            x += width + Style.gap
        }
        layout.lineStart = x - Style.gap
        return layout
    }

    /// An image of `badge` alone, for its drag.
    func dragImage(of badge: RefBadge, scale: CGFloat) -> NSImage {
        let size = widths(badge)
        let rect = CGRect(x: 0, y: 0, width: size.chrome + size.name, height: Style.height)
        let image = NSImage(size: rect.size)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((rect.width * scale).rounded(.up)),
            pixelsHigh: Int((rect.height * scale).rounded(.up)), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let bitmapContext = NSGraphicsContext(bitmapImageRep: bitmap)
        else { return image }
        bitmap.size = rect.size
        let context = bitmapContext.cgContext
        context.scaleBy(x: scale, y: scale)
        // Drawn top-down, as in the cell.
        context.translateBy(x: 0, y: rect.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        // The badge's fill is see-through: on the graph's surface first, so the badge under the drag does not show
        // through it.
        Palette.graphSurface.setFill()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Style.radius, cornerHeight: Style.radius, transform: nil))
        context.fillPath()
        drawBadge(badge, in: rect, level: .full, context: context)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        return image
    }

    private func chipWidth(_ count: Int) -> CGFloat {
        2 * Style.padding + ceil(("+\(count)" as NSString).size(withAttributes: countAttributes).width)
    }

    private func drawChip(_ text: String, in rect: CGRect, context: CGContext) {
        Palette.graphTagFill.setFill()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Style.radius, cornerHeight: Style.radius, transform: nil))
        context.fillPath()
        let size = (text as NSString).size(withAttributes: countAttributes)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: countAttributes)
    }

    /// A badge's fill: as it is, fainter (the stack's badges under the row's own), or lit (the hovered one).
    private enum Fill {
        case normal, faint, lit
    }

    /// Draws `badge` at `level` in `rect`, clipped to it; the name is clipped to the room between its icons.
    private func drawBadge(_ badge: RefBadge, in rect: CGRect, level: Level, fill: Fill = .normal,
                           context: CGContext)
    {
        let path = CGPath(roundedRect: rect, cornerWidth: Style.radius, cornerHeight: Style.radius, transform: nil)
        let isHead = badge.isHead
        let lane = self.color % Palette.graphLanes.count
        let color: NSColor = if case .tag = badge.kind {
            Palette.graphTagFill
        } else {
            (isHead ? Palette.graphHeadBadgeFills : Palette.graphBadgeFills)[lane]
        }
        (fill == .faint ? color.withAlphaComponent(color.alphaComponent * Style.faintFill) : color).setFill()
        context.addPath(path)
        context.fillPath()
        if fill == .lit {
            NSColor.white.withAlphaComponent(Style.litFill).setFill()
            context.addPath(path)
            context.fillPath()
        }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)

        if level == .icon || level == .check {
            let names = Self.iconsAlone(badge, at: level)
            var x = rect.midX - Self.iconsWidth(names) / 2
            for name in names {
                drawIcon(name, of: badge, x: x, midY: rect.midY)
                x += Self.iconWidth(name) + Style.iconGap
            }
            return
        }
        let (leading, trailing) = Self.icons(badge, at: level)
        var x = rect.minX + Style.padding
        for name in leading {
            drawIcon(name, of: badge, x: x, midY: rect.midY)
            x += Self.iconWidth(name) + Style.iconGap
        }
        var trailingX = rect.maxX - Style.padding
        if level == .full, let pull = badge.pullRequest.map(PullRequestChip.init) {
            let chip = chipRect(pull, in: rect)
            drawPullRequestChip(pull, in: chip, context: context)
            trailingX = chip.minX - Style.iconGap
        }
        for name in trailing.reversed() {
            trailingX -= Self.iconWidth(name)
            drawIcon(name, of: badge, x: trailingX, midY: rect.midY)
            trailingX -= Style.iconGap
        }
        if level == .full, let counts = Self.aheadBehind(badge) {
            let size = (counts as NSString).size(withAttributes: countAttributes)
            trailingX -= ceil(size.width)
            (counts as NSString).draw(at: CGPoint(x: trailingX, y: rect.midY - size.height / 2),
                                      withAttributes: countAttributes)
            trailingX -= Style.iconGap
        }
        let attributes = textAttributes(badge)
        let font = attributes[.font] as? NSFont ?? metrics.textSize.bodyNSFont
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textRect = CGRect(x: x, y: rect.midY - lineHeight / 2, width: max(0, trailingX - x), height: lineHeight)
        guard textRect.width > 0 else { return }
        context.clip(to: textRect)
        (badge.shownName as NSString).draw(
            with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    /// The pull icon and "#N" on GitHub's open green (or draft grey).
    private func drawPullRequestChip(_ pull: PullRequestChip, in rect: CGRect, context: CGContext) {
        (pull.isDraft ? Palette.graphPullDraftFill : Palette.graphPullOpenFill).setFill()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Style.chipRadius, cornerHeight: Style.chipRadius,
                               transform: nil))
        context.fillPath()
        context.saveGState()
        context.clip(to: rect)
        let x = rect.minX + Style.chipPadding
        drawIcon(Self.pullIcon, x: x, midY: rect.midY, slot: Style.icon)
        let size = (pull.text as NSString).size(withAttributes: countAttributes)
        (pull.text as NSString).draw(at: CGPoint(x: x + Style.icon + Style.iconGap, y: rect.midY - size.height / 2),
                                     withAttributes: countAttributes)
        context.restoreGState()
    }

    private func drawIcon(_ name: String, x: CGFloat, midY: CGFloat) {
        drawIcon(name, x: x, midY: midY, slot: Self.iconWidth(name))
    }

    /// `badge`'s icon `name`; the cloud gives way to the logo of its remote's owner once loaded (`remoteAvatars`).
    private func drawIcon(_ name: String, of badge: RefBadge, x: CGFloat, midY: CGFloat) {
        guard name == "cloud", let image = badge.remote.flatMap({ remoteAvatars[$0] }) else {
            return drawIcon(name, x: x, midY: midY)
        }
        let side = Style.refIcon
        let rect = CGRect(x: x, y: (midY - side / 2).rounded(), width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                   hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawIcon(_ name: String, x: CGFloat, midY: CGFloat, slot: CGFloat) {
        guard let image = Self.symbol(name) else { return }
        let size = image.size
        let scale = min(1, slot / max(size.width, size.height))
        let width = size.width * scale
        let height = size.height * scale
        image.draw(in: CGRect(x: x + (slot - width) / 2, y: midY - height / 2, width: width, height: height))
    }
}

/// What a pull request chip draws.
private struct PullRequestChip {
    let text: String
    let isDraft: Bool

    init(_ pull: RefBadge.PullRequest) {
        text = "#\(pull.number)"
        isDraft = pull.isDraft
    }
}

// MARK: - Text

/// A text column's cell: one line, vertically centered, truncated with "…". `detail` follows the text in the
/// secondary color (the WIP row's change counts).
final class GraphTextCellView: NSView {
    enum Tone { case primary, secondary }

    var text = "" { didSet { refreshAccessibilityLabel(); refreshToolTip() } }
    /// A WIP row's files after the text: each kind's glyph in its file-list color, then its count.
    var changes: WorktreeChanges? { didSet { refreshAccessibilityLabel(); refreshToolTip() } }
    var tone = Tone.primary
    var isItalic = false { didSet { refreshToolTip() } }
    /// The fonts' size (`GraphMetrics.textSize`): set before `text`, whose tooltip measures it.
    var textSize = TextSize.regular { didSet { if textSize != oldValue { refreshToolTip() } } }
    /// The author column's avatar: drawn instead of the text while the column is too narrow for `compactTitle` (its
    /// header's title, which shows an icon then).
    var avatar: NSImage? { didSet { refreshToolTip() } }
    var avatarDiameter: CGFloat = 16
    var compactTitle: String?
    /// A row the graph search does not match while it has matches: the text draws at `Style.dimmedAlpha`.
    var isDimmed = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The fonts, attributes and glyphs of one text size (12 pt text at Regular), built once per size
    /// (`Style.bySize`).
    @MainActor
    private struct Style {
        let font: NSFont
        let italic: NSFont
        let primary: [NSAttributedString.Key: Any]
        let secondary: [NSAttributedString.Key: Any]
        let primaryItalic: [NSAttributedString.Key: Any]
        let secondaryItalic: [NSAttributedString.Key: Any]
        // `FileChange`'s glyphs and colors, so the row matches the file lists.
        let edited: NSTextAttachment
        let added: NSTextAttachment
        let deleted: NSTextAttachment
        /// One line of the text, for its rect.
        let lineHeight: CGFloat

        init(_ size: TextSize) {
            font = NSFont.systemFont(ofSize: size.scaled(12))
            italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            primary = Self.attributes(.primary, font: font)
            secondary = Self.attributes(.secondary, font: font)
            primaryItalic = Self.attributes(.primary, font: italic)
            secondaryItalic = Self.attributes(.secondary, font: italic)
            let glyphSize = size.scaled(11)
            edited = Self.glyph("pencil", Palette.graphLanes[1], size: glyphSize, font: font)
            added = Self.glyph("plus", Palette.graphLanes[2], size: glyphSize, font: font)
            deleted = Self.glyph("minus", Palette.graphLanes[7], size: glyphSize, font: font)
            lineHeight = ceil(font.ascender - font.descender + font.leading)
        }

        static let bySize = Dictionary(uniqueKeysWithValues: TextSize.allCases.map { ($0, Style($0)) })
        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        private static func attributes(_ tone: Tone, font: NSFont) -> [NSAttributedString.Key: Any] {
            [.font: font, .paragraphStyle: paragraph,
             .foregroundColor: tone == .primary ? NSColor.labelColor : NSColor.secondaryLabelColor]
        }
        static let padding: CGFloat = 8
        static let dimmedAlpha: CGFloat = 0.35

        /// A symbol with its color baked in (an attachment does not take the text's color), centered on the capitals.
        private static func glyph(_ name: String, _ color: NSColor, size: CGFloat, font: NSFont) -> NSTextAttachment {
            let attachment = NSTextAttachment()
            let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration)
            else { return attachment }
            attachment.image = image
            attachment.bounds = CGRect(x: 0, y: ((font.capHeight - image.size.height) / 2).rounded(),
                                       width: image.size.width, height: image.size.height)
            return attachment
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshToolTip()
    }

    private var showsAvatar: Bool {
        guard avatar != nil, let compactTitle else { return false }
        return !GraphHeaderCell.fits(compactTitle, width: bounds.width, textSize: textSize)
    }

    private var textWidth: CGFloat { max(0, bounds.width - 2 * Style.padding) }

    /// On a selected row every tone draws in full white, brighter than the label colors.
    private var isRowSelected: Bool { (superview as? NSTableRowView)?.isSelected ?? false }

    /// The fonts of `textSize`.
    private var style: Style { Style.bySize[textSize] ?? Style(textSize) }

    /// The width a cell needs to show `text` whole at `textSize`: the text and its padding.
    static func fittingWidth(_ text: String, textSize: TextSize) -> CGFloat {
        let font = (Style.bySize[textSize] ?? Style(textSize)).font
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 2 * Style.padding
    }

    private var attributedText: NSAttributedString {
        let style = style
        let selected = isRowSelected
        var attributes = switch (tone, isItalic) {
        case (.primary, false): style.primary
        case (.secondary, false): style.secondary
        case (.primary, true): style.primaryItalic
        case (.secondary, true): style.secondaryItalic
        }
        if selected { attributes[.foregroundColor] = NSColor.white }
        guard let changes else { return NSAttributedString(string: text, attributes: attributes) }
        let combined = NSMutableAttributedString(string: text, attributes: attributes)
        var counts = tone == .primary ? style.primary : style.secondary
        if selected { counts[.foregroundColor] = NSColor.white }
        for (count, glyph) in [(changes.edited, style.edited), (changes.added, style.added),
                               (changes.deleted, style.deleted)] where count > 0 {
            combined.append(NSAttributedString(string: "   ", attributes: counts))
            combined.append(NSAttributedString(attachment: glyph))
            combined.append(NSAttributedString(string: " \(count)", attributes: counts))
        }
        return combined
    }

    /// The text with the WIP counts in words ("// WIP  5 edited · 1 added").
    private var plainText: String {
        guard let summary = changes?.kindSummary, !summary.isEmpty else { return text }
        return text + "  " + summary
    }

    private func refreshAccessibilityLabel() {
        setAccessibilityLabel(plainText)
    }

    /// The whole text on hover when it is cut (or shown as the avatar); none when it shows whole.
    private func refreshToolTip() {
        let tip: String?
        if text.isEmpty {
            tip = nil
        } else if showsAvatar {
            tip = text
        } else {
            tip = ceil(attributedText.size().width) > textWidth ? plainText : nil
        }
        if tip != toolTip { toolTip = tip }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let context = NSGraphicsContext.current?.cgContext
        if isDimmed {
            context?.saveGState()
            context?.setAlpha(Style.dimmedAlpha)
        }
        defer { if isDimmed { context?.restoreGState() } }
        if showsAvatar, let avatar {
            let rect = CGRect(x: Style.padding, y: ((bounds.height - avatarDiameter) / 2).rounded(),
                              width: avatarDiameter, height: avatarDiameter)
            context?.saveGState()
            context?.addEllipse(in: rect)
            context?.clip()
            avatar.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            context?.restoreGState()
            return
        }
        let lineHeight = style.lineHeight
        let rect = CGRect(x: Style.padding, y: (bounds.height - lineHeight) / 2, width: textWidth, height: lineHeight)
        attributedText.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Row and header

/// A graph row: the selection is a neutral square fill (no accent, no edge) from the row's node to the table's right
/// edge, as tall as the band and the node (`GraphMetrics.bandHeight`); drawn under the cells so the
/// lanes stay on top. Its text cells draw in full white while it is selected.
final class GraphRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            guard isSelected != oldValue else { return }
            for cell in subviews where cell is GraphTextCellView { cell.needsDisplay = true }
        }
    }

    /// Where the selection starts, in the row's coordinates: the node's left edge (set by the table's controller on
    /// every reuse and column resize).
    var highlightStartX: CGFloat = 0 {
        didSet { if highlightStartX != oldValue { needsDisplay = true } }
    }

    /// The selection's inset from the row's top and bottom (`GraphMetrics.bandInset`, set with `highlightStartX`).
    var bandInset: CGFloat = 0 {
        didSet { if bandInset != oldValue { needsDisplay = true } }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawSelection(in dirtyRect: NSRect) {
        let start = min(max(highlightStartX, bounds.minX), bounds.maxX)
        Palette.graphSelection.setFill()
        NSRect(x: start, y: bounds.minY + bandInset, width: bounds.maxX - start,
               height: max(0, bounds.height - 2 * bandInset))
            .fill(using: .sourceOver)
    }
}

/// The column titles: small uppercase secondary text on the card's own fill (opaque, so scrolled rows
/// never show through it); a hairline below.
final class GraphHeaderView: NSTableHeaderView {
    override var isOpaque: Bool { true }

    /// The borders right of the message and author columns are dragged by the table (`trackBorderDrag`); the others
    /// keep AppKit's resizing.
    override func mouseDown(with event: NSEvent) {
        if let table = tableView as? GraphTableView, table.trackBorderDrag(event, in: self) { return }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.graphSurface.setFill()
        dirtyRect.fill()
        guard let tableView else { return }
        for index in tableView.tableColumns.indices where !tableView.tableColumns[index].isHidden {
            // A hidden column's rect is not empty: it would draw its title over the first column's.
            let rect = headerRect(ofColumn: index)
            guard rect.intersects(dirtyRect) else { continue }
            tableView.tableColumns[index].headerCell.draw(withFrame: rect, in: self)
        }
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.minX, y: isFlipped ? bounds.maxY - 1 : bounds.minY, width: bounds.width, height: 1).fill()
    }
}

final class GraphHeaderCell: NSTableHeaderCell {
    /// The title's attributes by text size: 10.5 pt semibold at Regular.
    @MainActor private static let attributes: [TextSize: [NSAttributedString.Key: Any]] = Dictionary(
        uniqueKeysWithValues: TextSize.allCases.map {
            ($0, [.font: NSFont.systemFont(ofSize: $0.scaled(10.5), weight: .semibold),
                  .foregroundColor: NSColor.secondaryLabelColor, .kern: 0.6])
        })

    /// The SF Symbol drawn instead of the title when the column is too narrow for the whole title.
    var symbolName: String?
    /// The title's size (`GraphMetrics.textSize`).
    var textSize = TextSize.regular

    /// Whether `title` fits whole in a column `width` wide at `textSize` (the author cells show avatars when the
    /// author's does not).
    @MainActor static func fits(_ title: String, width: CGFloat, textSize: TextSize) -> Bool {
        (title.uppercased() as NSString).size(withAttributes: attributes[textSize] ?? [:]).width <= width - 12
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        if let symbolName, !Self.fits(stringValue, width: cellFrame.width, textSize: textSize),
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: stringValue)?
               .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
                   .applying(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor]))) {
            let size = symbol.size
            symbol.draw(in: NSRect(x: cellFrame.minX + 8, y: (cellFrame.midY - size.height / 2).rounded(),
                                   width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        } else {
            let title = stringValue.uppercased() as NSString
            let attributes = Self.attributes[textSize] ?? [:]
            let size = title.size(withAttributes: attributes)
            let rect = NSRect(x: cellFrame.minX + 8, y: cellFrame.midY - size.height / 2,
                              width: max(0, cellFrame.width - 12), height: size.height)
            title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                       attributes: attributes)
        }
        // A hairline between columns, like the resize handle's place.
        NSColor.separatorColor.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 6, width: 1, height: max(0, cellFrame.height - 12)).fill()
    }
}
