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
    let name: String
    /// Commits ahead of / behind the upstream (local branches).
    var ahead = 0
    var behind = 0
    var pullRequest: PullRequest?
    /// The faded badge of the branch a selected commit is on (`BranchAttribution`), drawn with its line at
    /// `Palette.graphGhostAlpha`; not a menu, drag or drop target.
    var isGhost = false

    /// The badges of every labeled commit, in row order: HEAD's branch (or a detached HEAD) first, then local
    /// branches, remote branches that are not merged into a local badge, then tags. Built once per refs read (and per
    /// change of `pullRequests`, the store's `branchPullRequests`: a remote branch's pull request by its name, which a
    /// local branch gets through its upstream).
    static func badges(for refs: Refs, pullRequests: [String: PullRequest] = [:]) -> [String: [RefBadge]] {
        var byCommit: [String: [RefBadge]] = [:]
        let remoteCommits = Dictionary(refs.remoteBranches.map { ($0.name, $0.commit) }, uniquingKeysWith: { a, _ in a })
        var mergedRemotes = Set<String>()
        if case .detached(let commit) = refs.head {
            byCommit[commit, default: []].append(RefBadge(kind: .head, name: "HEAD"))
        }
        for branch in refs.localBranches.sorted(by: { $0.isHead && !$1.isHead }) {
            var isRemote = false
            if let upstream = branch.upstream, remoteCommits[upstream] == branch.commit {
                isRemote = true
                mergedRemotes.insert(upstream)
            }
            byCommit[branch.commit, default: []].append(RefBadge(
                kind: .branch(isLocal: true, isRemote: isRemote, isHead: branch.isHead), name: branch.name,
                ahead: branch.ahead, behind: branch.behind, pullRequest: branch.upstream.flatMap { pullRequests[$0] }))
        }
        for remote in refs.remoteBranches where !mergedRemotes.contains(remote.name) {
            byCommit[remote.commit, default: []].append(RefBadge(
                kind: .branch(isLocal: false, isRemote: true, isHead: false), name: remote.name,
                pullRequest: pullRequests[remote.name]))
        }
        for tag in refs.tags {
            byCommit[tag.commit ?? tag.target, default: []].append(RefBadge(kind: .tag, name: tag.name))
        }
        return byCommit
    }
}

/// The BRANCH / TAG column's cell: the row's badges from the left, as many as fit whole, then "+N" for the rest. When
/// even the first does not fit whole it steps down (`Level`): its name without ↑↓ and the pull request chip, cut with
/// "…" (at least 3 characters), with only its main icon, then that icon alone in a square; "+N" gives way before the
/// name does. Nothing is drawn outside a badge, or past the cell. A line in the lane color runs from the last badge to
/// the column's right edge, where the graph cell continues it to the node.
final class RefBadgeCellView: NSView {
    var badges: [RefBadge] = []
    /// The row's lane color (`GraphRow.color`).
    var color = 0
    var metrics = GraphMetrics(density: "regular")

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    @MainActor
    private enum Style {
        // Normal weight, a size up from the message text (user, 2026-11-13, as GitKraken's labels).
        static let font = NSFont.systemFont(ofSize: 13)
        static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        static let text: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: Palette.graphBadgeText, .paragraphStyle: paragraph,
        ]
        static let count: [NSAttributedString.Key: Any] = [
            .font: countFont, .foregroundColor: Palette.graphBadgeText,
        ]
        static let leading: CGFloat = 6
        static let padding: CGFloat = 7
        static let gap: CGFloat = 4
        static let iconGap: CGFloat = 3
        /// The check's slot. The laptop, cloud and tag get `refIcon`: bigger, so they read at a glance (user,
        /// 2026-11-13); the text and the badge height stay.
        static let icon: CGFloat = 12
        static let refIcon: CGFloat = 15
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

    /// A glyph's slot width: the check keeps the small one.
    private static func iconWidth(_ name: String) -> CGFloat {
        name == "checkmark.circle.fill" ? Style.icon : Style.refIcon
    }

    /// SF Symbols in the badge text color, drawn at a size that fills their slot (the cloud and tag are 16 pt wide at
    /// 12 pt, scaled down to 15; at 10.5 pt they stayed 14). A Lucide icon (24 pt) is tinted the same color.
    @MainActor private static func symbol(_ name: String) -> NSImage? {
        if let cached = symbols[name] { return cached }
        if name.hasPrefix("lucide-") {
            let image = NSImage.icon(name, accessibilityDescription: nil, size: 24).map(tinted)
            symbols[name] = image
            return image
        }
        let isCheck = name == "checkmark.circle.fill"
        var configuration = NSImage.SymbolConfiguration(pointSize: isCheck ? 10.5 : 12, weight: .regular)
        // In the palette color the check's own layer fills in the disc; tinted whole, it stays a cutout.
        if !isCheck {
            configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [Palette.graphBadgeText]))
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
            .map { isCheck ? tinted($0) : $0 }
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
            return (isHead ? ["checkmark.circle.fill"] : [],
                    (isLocal ? ["lucide-laptop-minimal"] : []) + (isRemote ? ["cloud"] : []))
        case .tag: return (["tag"], [])
        case .head: return (["checkmark.circle.fill"], [])
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
    private static func pullChipWidth(_ pull: PullRequestChip) -> CGFloat {
        2 * Style.chipPadding + Style.icon + Style.iconGap
            + ceil((pull.text as NSString).size(withAttributes: Style.count).width)
    }

    /// The one icon of a badge drawn without the others: the check (HEAD's branch, a detached HEAD), else the laptop
    /// (local branch), the cloud (remote only), the tag or the folder (worktree).
    private static func mainIcon(_ badge: RefBadge) -> String {
        let (leading, trailing) = icons(badge)
        return leading.first ?? trailing.first ?? "tag"
    }

    /// The icons drawn at `level`, on the side each has in the full badge.
    private static func icons(_ badge: RefBadge, at level: Level) -> (leading: [String], trailing: [String]) {
        let all = icons(badge)
        switch level {
        case .full, .name(allIcons: true): return all
        case .name(allIcons: false), .icon:
            let main = mainIcon(badge)
            return all.leading.contains(main) ? ([main], []) : ([], [main])
        }
    }

    /// How much of a badge is drawn.
    fileprivate enum Level: Equatable {
        /// Icons, name, ↑↓ and the pull request chip.
        case full
        /// The name (cut with "…" when short) without ↑↓ and the pull request chip; with only the main icon when
        /// even 3 characters do not fit beside all of them.
        case name(allIcons: Bool)
        /// The main icon alone, in a square.
        case icon
    }

    /// The badge's level and width in `room` points of a row whose badges are `height` high; nil when not even the
    /// square fits.
    private static func fit(_ badge: RefBadge, room: CGFloat, height: CGFloat) -> (level: Level, width: CGFloat)? {
        let size = widths(badge)
        if size.chrome + size.name <= room { return (.full, size.chrome + size.name) }
        for allIcons in [true, false] {
            let (leading, trailing) = icons(badge, at: .name(allIcons: allIcons))
            let chrome = 2 * Style.padding + (leading + trailing).reduce(0) { $0 + iconWidth($1) + Style.iconGap }
            if chrome + minimumName(badge) <= room { return (.name(allIcons: allIcons), min(room, chrome + size.name)) }
        }
        return height <= room ? (.icon, height) : nil
    }

    /// The least of a name shown: its first 3 characters and "…" (with a point to spare, so AppKit keeps 3), or all
    /// of a shorter name.
    private static func minimumName(_ badge: RefBadge) -> CGFloat {
        let name = ceil((badge.name as NSString).size(withAttributes: Style.text).width)
        guard badge.name.count > 3 else { return name }
        let cut = ceil((String(badge.name.prefix(3)) + "…" as NSString).size(withAttributes: Style.text).width) + 1
        return min(name, cut)
    }

    /// The badge's width without its name, and its name's width. A pull request chip takes the place of the badge's
    /// right padding, `chipInset` from its edge.
    private static func widths(_ badge: RefBadge) -> (chrome: CGFloat, name: CGFloat) {
        let (leading, trailing) = icons(badge)
        var chrome = 2 * Style.padding + (leading + trailing).reduce(0) { $0 + iconWidth($1) + Style.iconGap }
        if let counts = aheadBehind(badge) {
            chrome += Style.iconGap + ceil((counts as NSString).size(withAttributes: Style.count).width)
        }
        if let pull = badge.pullRequest.map(PullRequestChip.init) {
            chrome += Style.iconGap + pullChipWidth(pull) + Style.chipInset - Style.padding
        }
        let name = ceil((badge.name as NSString).size(withAttributes: Style.text).width)
        return (chrome, name)
    }

    /// Where the badges are drawn: each shown badge's frame, the "+N" chip, and where the line to the node starts.
    private struct Layout {
        var badges: [(index: Int, rect: CGRect, level: Level)] = []
        var chip: (text: String, rect: CGRect)?
        var lineStart: CGFloat = 0
    }

    /// The badge drawn at `point` (in this view), for its menu and its drag; never a ghost.
    func badge(at point: CGPoint) -> RefBadge? {
        guard let layout = layout() else { return nil }
        return layout.badges.first { $0.rect.contains(point) && bounds.contains(point) }.map { badges[$0.index] }
            .flatMap { $0.isGhost ? nil : $0 }
    }

    /// The pull request whose chip is drawn at `point` (in this view): a click there opens it.
    func pullRequest(at point: CGPoint) -> RefBadge.PullRequest? {
        guard let layout = layout() else { return nil }
        // Only a chip that is drawn: a square or a cut name has none.
        for (index, rect, level) in layout.badges where level == .full {
            guard let pull = badges[index].pullRequest, Self.chipRect(PullRequestChip(pull), in: rect).contains(point)
            else { continue }
            return pull
        }
        return nil
    }

    /// The chip's frame inside its badge's: at the trailing end, `chipInset` from the badge's edges.
    private static func chipRect(_ pull: PullRequestChip, in rect: CGRect) -> CGRect {
        let width = min(pullChipWidth(pull), rect.width - 2 * Style.chipInset)
        return CGRect(x: rect.maxX - Style.chipInset - width, y: rect.minY + Style.chipInset,
                      width: max(0, width), height: max(0, rect.height - 2 * Style.chipInset))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let layout = layout(), let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)
        for (index, rect, level) in layout.badges {
            let badge = badges[index]
            // A ghost is faded as a whole (one transparency layer), so its fill and text do not show through each other.
            if badge.isGhost {
                context.saveGState()
                context.setAlpha(Palette.graphGhostAlpha)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            drawBadge(badge, in: rect, level: level, context: context)
            if badge.isGhost {
                context.endTransparencyLayer()
                context.restoreGState()
            }
        }
        if let chip = layout.chip {
            drawChip(chip.text, in: chip.rect, context: context)
        }

        // The line to the node: faded too when only a ghost is shown.
        let lane = Palette.graphLanes[color % Palette.graphLanes.count]
        let onlyGhosts = layout.badges.allSatisfy { badges[$0.index].isGhost }
        (onlyGhosts ? lane.withAlphaComponent(Palette.graphGhostAlpha) : lane).setStroke()
        context.setLineWidth(1.5)
        context.move(to: CGPoint(x: layout.lineStart, y: bounds.midY))
        context.addLine(to: CGPoint(x: bounds.maxX, y: bounds.midY))
        context.strokePath()
    }

    private func layout() -> Layout? {
        guard !badges.isEmpty else { return nil }
        var layout = Layout()
        let height = min(Style.height, bounds.height - 2 * metrics.bandInset)
        let y = (bounds.height - height) / 2
        let available = bounds.width - Style.leading - Style.trailing
        let sizes = badges.map(Self.widths)

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
        var showsChip = shown < badges.count
        if shown > 1 || shown == badges.count && sizes[0].chrome + sizes[0].name <= available {
            for index in 0..<shown { place(index, .full, sizes[index].chrome + sizes[index].name) }
        } else {
            // Only the first badge is shown, and not with "+N" whole: "+N" stays only if the badge keeps the level it
            // has alone (a shorter cut of its name, or its square), else it gives way.
            let chip = showsChip ? chipWidth(badges.count - 1) + Style.gap : 0
            let alone = Self.fit(badges[0], room: available, height: height)
            let beside = showsChip ? Self.fit(badges[0], room: available - chip, height: height) : nil
            showsChip = beside != nil && beside?.level == alone?.level
            guard let fit = showsChip ? beside : alone else {
                layout.lineStart = Style.leading
                return layout
            }
            place(0, fit.level, fit.width)
            shown = 1
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
        let size = Self.widths(badge)
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
        drawBadge(badge, in: rect, level: .full, context: context)
        NSGraphicsContext.restoreGraphicsState()
        image.addRepresentation(bitmap)
        return image
    }

    private func chipWidth(_ count: Int) -> CGFloat {
        2 * Style.padding + ceil(("+\(count)" as NSString).size(withAttributes: Style.count).width)
    }

    private func drawChip(_ text: String, in rect: CGRect, context: CGContext) {
        Palette.graphTagFill.setFill()
        context.addPath(CGPath(roundedRect: rect, cornerWidth: Style.radius, cornerHeight: Style.radius, transform: nil))
        context.fillPath()
        let size = (text as NSString).size(withAttributes: Style.count)
        (text as NSString).draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
                                withAttributes: Style.count)
    }

    /// Draws `badge` at `level` in `rect`, clipped to it; the name is clipped to the room between its icons.
    private func drawBadge(_ badge: RefBadge, in rect: CGRect, level: Level, context: CGContext) {
        let path = CGPath(roundedRect: rect, cornerWidth: Style.radius, cornerHeight: Style.radius, transform: nil)
        if case .tag = badge.kind {
            Palette.graphTagFill.setFill()
        } else {
            Palette.graphBadgeFills[color % Palette.graphBadgeFills.count].setFill()
        }
        // No border, not even on HEAD's branch: its check icon marks it (user, 2026-11-13).
        context.addPath(path)
        context.fillPath()
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)

        if level == .icon {
            let name = Self.mainIcon(badge)
            drawIcon(name, x: rect.midX - Self.iconWidth(name) / 2, midY: rect.midY)
            return
        }
        let (leading, trailing) = Self.icons(badge, at: level)
        var x = rect.minX + Style.padding
        for name in leading {
            drawIcon(name, x: x, midY: rect.midY)
            x += Self.iconWidth(name) + Style.iconGap
        }
        var trailingX = rect.maxX - Style.padding
        if level == .full, let pull = badge.pullRequest.map(PullRequestChip.init) {
            let chip = Self.chipRect(pull, in: rect)
            drawPullRequestChip(pull, in: chip, context: context)
            trailingX = chip.minX - Style.iconGap
        }
        for name in trailing.reversed() {
            trailingX -= Self.iconWidth(name)
            drawIcon(name, x: trailingX, midY: rect.midY)
            trailingX -= Style.iconGap
        }
        if level == .full, let counts = Self.aheadBehind(badge) {
            let size = (counts as NSString).size(withAttributes: Style.count)
            trailingX -= ceil(size.width)
            (counts as NSString).draw(at: CGPoint(x: trailingX, y: rect.midY - size.height / 2),
                                      withAttributes: Style.count)
            trailingX -= Style.iconGap
        }
        let lineHeight = ceil(Style.font.ascender - Style.font.descender + Style.font.leading)
        let textRect = CGRect(x: x, y: rect.midY - lineHeight / 2, width: max(0, trailingX - x), height: lineHeight)
        guard textRect.width > 0 else { return }
        context.clip(to: textRect)
        (badge.name as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                      attributes: Style.text)
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
        drawIcon("arrow.triangle.pull", x: x, midY: rect.midY, slot: Style.icon)
        let size = (pull.text as NSString).size(withAttributes: Style.count)
        (pull.text as NSString).draw(at: CGPoint(x: x + Style.icon + Style.iconGap, y: rect.midY - size.height / 2),
                                     withAttributes: Style.count)
        context.restoreGState()
    }

    private func drawIcon(_ name: String, x: CGFloat, midY: CGFloat) {
        drawIcon(name, x: x, midY: midY, slot: Self.iconWidth(name))
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

    var text = "" { didSet { setAccessibilityLabel(text) } }
    var detail: String?
    var tone = Tone.primary
    var isItalic = false
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

    @MainActor
    private enum Style {
        static let font = NSFont.systemFont(ofSize: 12)
        static let italic = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 12), toHaveTrait: .italicFontMask)
        static let paragraph: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            return style
        }()
        static func attributes(_ tone: Tone, italic: Bool) -> [NSAttributedString.Key: Any] {
            [.font: italic ? Style.italic : Style.font, .paragraphStyle: paragraph,
             .foregroundColor: tone == .primary ? NSColor.labelColor : NSColor.secondaryLabelColor]
        }
        static let primary = attributes(.primary, italic: false)
        static let secondary = attributes(.secondary, italic: false)
        static let primaryItalic = attributes(.primary, italic: true)
        static let secondaryItalic = attributes(.secondary, italic: true)
        static let padding: CGFloat = 8
        static let dimmedAlpha: CGFloat = 0.35
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let context = NSGraphicsContext.current?.cgContext
        if isDimmed {
            context?.saveGState()
            context?.setAlpha(Style.dimmedAlpha)
        }
        defer { if isDimmed { context?.restoreGState() } }
        let attributes = switch (tone, isItalic) {
        case (.primary, false): Style.primary
        case (.secondary, false): Style.secondary
        case (.primary, true): Style.primaryItalic
        case (.secondary, true): Style.secondaryItalic
        }
        let lineHeight = ceil(Style.font.ascender - Style.font.descender + Style.font.leading)
        let rect = CGRect(x: Style.padding, y: (bounds.height - lineHeight) / 2,
                          width: max(0, bounds.width - 2 * Style.padding), height: lineHeight)
        let string: NSAttributedString
        if let detail {
            let combined = NSMutableAttributedString(string: text, attributes: attributes)
            combined.append(NSAttributedString(string: "  " + detail, attributes: Style.secondary))
            string = combined
        } else {
            string = NSAttributedString(string: text, attributes: attributes)
        }
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

// MARK: - Row and header

/// A graph row: the selection is a neutral square fill (no accent, no white text, no edge) from the row's node to the
/// table's right edge, as tall as the band and the node (`GraphMetrics.bandHeight`), as in GitKraken; drawn under the
/// cells so the lanes stay on top.
final class GraphRowView: NSTableRowView {
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

/// The column titles as gk shows them: small uppercase secondary text on the card's own fill (opaque, so scrolled rows
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
    @MainActor private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
        .foregroundColor: NSColor.secondaryLabelColor,
        .kern: 0.6,
    ]

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let title = stringValue.uppercased() as NSString
        let size = title.size(withAttributes: Self.attributes)
        let rect = NSRect(x: cellFrame.minX + 8, y: cellFrame.midY - size.height / 2,
                          width: max(0, cellFrame.width - 12), height: size.height)
        title.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                   attributes: Self.attributes)
        // A hairline between columns, like the resize handle's place.
        NSColor.separatorColor.setFill()
        NSRect(x: cellFrame.maxX - 1, y: cellFrame.minY + 6, width: 1, height: max(0, cellFrame.height - 12)).fill()
    }
}
