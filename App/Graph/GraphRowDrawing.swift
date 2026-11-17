// Draws one row of the commit graph with Core Graphics: the faint band in the node's lane color, the line from the
// row's ref badges to its node, the lane lines (rounded where they bend into or out of the node) and the node itself.
// Nothing here allocates per row beyond what Core Graphics needs: colors are palette tokens resolved at draw time and
// the initials' strings are cached.
import AppKit
import HistqCore

/// Sizes of the graph, from the row height (`PrefKey.rowDensity`).
struct GraphMetrics: Equatable {
    let rowHeight: CGFloat

    /// "compact", "regular" (the default) or "comfortable"; anything else reads as regular.
    init(density: String) {
        // Closer to GitKraken's spacing (user, 2026-11-13): regular 28 -> 32, the others scaled with it.
        switch density {
        case "compact": rowHeight = 26
        case "comfortable": rowHeight = 38
        default: rowHeight = 32
        }
    }

    /// The height shared by the band, its edge bar, the selection and the node (the avatar), centered in the row: a
    /// 3 pt gap above and below, where the lane lines run between two rows, as in GitKraken (20 / 26 / 32 pt).
    var bandHeight: CGFloat { rowHeight - 6 }
    /// A commit's node (its avatar's circle): as tall as the band.
    var nodeDiameter: CGFloat { bandHeight }
    /// From one lane's center to the next: a node and a small gap.
    var laneWidth: CGFloat { nodeDiameter + 4 }
    /// Before lane 0.
    var leading: CGFloat { 6 }
    /// After the last lane at the column's widest (`width(lanes:)`): the gap between its node and the band's 2 pt bar
    /// at the column's right edge (GitKraken's is about 4 times the 6 pt it was).
    var trailing: CGFloat { 24 }
    /// The least gap between a node's right edge and the column's right edge: a narrower column shrinks the gap down to
    /// this, then pushes the right-most nodes left (`drawnX`), so a width saved before `trailing` grew still shows its
    /// lanes.
    var minTrailing: CGFloat { 6 }
    /// A merge commit's dot: scales with the node, kept even so it centers on whole pixels.
    var mergeDotDiameter: CGFloat { 2 * (nodeDiameter * 0.2).rounded() }
    var lineWidth: CGFloat { 2 }
    /// The radius of a line's bend into or out of a node: a third of the node.
    var bendRadius: CGFloat { (nodeDiameter / 3).rounded() }
    /// The band's, the selection's and the badges' inset from the row's top and bottom.
    var bandInset: CGFloat { (rowHeight - bandHeight) / 2 }

    /// The center of `lane`, from the graph column's left edge.
    func x(lane: Int) -> CGFloat { leading + CGFloat(lane) * laneWidth + laneWidth / 2 }

    /// The graph column's width that shows `lanes` lanes.
    func width(lanes: Int) -> CGFloat { leading + CGFloat(lanes) * laneWidth + trailing }

    /// The narrowest graph column: lane 0's node and `minTrailing` after it, where every lane has folded onto lane 0.
    var minColumnWidth: CGFloat { x(lane: 0) + nodeDiameter / 2 + minTrailing }

    /// The right-most node center a graph column `width` wide has room for (`minTrailing` after the node), never left
    /// of lane 0's.
    func foldLimit(width: CGFloat) -> CGFloat { max(x(lane: 0), width - minTrailing - nodeDiameter / 2) }

    /// Where `lane`'s node is drawn in a graph column `width` wide, from its left edge: its own center, or the fold
    /// limit when the column has no room for it. As in GitKraken the column folds continuously: narrowed point by
    /// point, the right-most node slides left, pinned to the right edge, onto its left neighbour's line, then both
    /// slide together, down to lane 0.
    func drawnX(lane: Int, width: CGFloat) -> CGFloat { min(x(lane: lane), foldLimit(width: width)) }

    /// `lane` has no room in a graph column `width` wide: its node is pushed left (`drawnX`) and its lines are not
    /// drawn. Lane 0 never is.
    func isPinned(lane: Int, width: CGFloat) -> Bool { x(lane: lane) > foldLimit(width: width) + 0.001 }

    /// The lane lines' opacity in a graph column `width` wide, for a log of `logLanes` lanes: 1 until lane 1 is pinned,
    /// then fading to 0 as lane 1's nodes slide onto lane 0, so the narrowest column draws no lane line at all
    /// (GitKraken's collapsed column) without a pop. A one-lane log keeps its line.
    func lineAlpha(width: CGFloat, logLanes: Int) -> CGFloat {
        guard logLanes > 1 else { return 1 }
        return min(1, max(0, (foldLimit(width: width) - x(lane: 0)) / laneWidth))
    }
}

/// What a row's node stands for.
enum GraphNodeStyle: Equatable {
    /// A commit: its author's initials (5.2 adds the avatar).
    case commit(initials: String)
    /// A merge commit: a small dot.
    case merge
    /// The working tree's changes: a dashed circle.
    case wip
    /// A stash: a dashed square around a tray, as GitKraken.
    case stash
}

@MainActor
enum GraphRowDrawing {
    /// Draws `row` in `bounds` (a flipped view's bounds, the graph column's cell), clipped to it. `hasRefs` draws the
    /// line from the column's left edge (where the ref badges' line ends) to the node, at `refsAlpha` (a ghost badge's
    /// is faded). `avatar`, when given, fills the node.
    ///
    /// When `bounds` is too narrow for the log's `logLanes`, the right-most lanes fold continuously
    /// (`GraphMetrics.drawnX`): their nodes are pushed left, over their neighbours' lines, and the lines of a pinned
    /// lane are not drawn. A line between an unpinned lane and a pinned one is drawn only when its pinned end is this
    /// row's node (it then ends under the node); one that would run on down or up a pinned lane is left out, so no
    /// line dangles. As lane 1 folds onto lane 0 the remaining lines fade out (`GraphMetrics.lineAlpha`): the
    /// narrowest column draws none (GitKraken's collapsed column), the nodes' ring colors and the band's edge bar tell
    /// the branches apart.
    static func draw(
        _ row: GraphRow, node: GraphNodeStyle, hasRefs: Bool, refsAlpha: CGFloat = 1, avatar: NSImage?,
        metrics: GraphMetrics, logLanes: Int, in bounds: CGRect, context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)

        let width = bounds.width
        let nodeX = bounds.minX + metrics.drawnX(lane: row.lane, width: width)
        let midY = bounds.midY
        let laneColor = Palette.graphLane(row.color)

        // The band, from the node to the column's edge, ending in a 2 pt bar in the lane color (gk's message marker).
        let band = CGRect(x: nodeX, y: midY - metrics.bandHeight / 2,
                          width: max(0, bounds.maxX - nodeX), height: metrics.bandHeight)
        if band.width > 0 {
            Palette.graphLaneBand(row.color).setFill()
            context.fill(band)
            laneColor.setFill()
            context.fill(CGRect(x: bounds.maxX - 2, y: band.minY, width: 2, height: band.height))
        }

        context.setLineWidth(metrics.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        if hasRefs {
            (refsAlpha < 1 ? laneColor.withAlphaComponent(refsAlpha) : laneColor).setStroke()
            context.setLineWidth(1.5)
            context.move(to: CGPoint(x: bounds.minX, y: midY))
            context.addLine(to: CGPoint(x: nodeX, y: midY))
            context.strokePath()
            context.setLineWidth(metrics.lineWidth)
        }

        // The same for every row of the column, so the lines never break between rows.
        let lineAlpha = metrics.lineAlpha(width: width, logLanes: logLanes)
        if lineAlpha > 0.01 {
            // Faded, the lines go through one layer: the halves that meet under a node would otherwise darken there.
            let fades = lineAlpha < 0.99
            if fades {
                context.setAlpha(lineAlpha)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            // A segment's edge end (top or bottom) must be on an unpinned lane; its center end may also be the node.
            func shows(_ lane: Int, atCenter: Bool) -> Bool {
                !metrics.isPinned(lane: lane, width: width) || (atCenter && lane == row.lane)
            }
            for segment in row.top where shows(segment.from, atCenter: false) && shows(segment.to, atCenter: true) {
                stroke(segment, top: true, metrics: metrics, bounds: bounds, context: context)
            }
            for segment in row.bottom where shows(segment.from, atCenter: true) && shows(segment.to, atCenter: false) {
                stroke(segment, top: false, metrics: metrics, bounds: bounds, context: context)
            }
            if fades {
                context.endTransparencyLayer()
                context.setAlpha(1)
            }
        }

        drawNode(node, color: laneColor, band: Palette.graphLaneBand(row.color), avatar: avatar,
                 center: CGPoint(x: nodeX, y: midY), metrics: metrics, context: context)
    }

    /// One line piece. Top half: from the row's top edge at lane `from` to the center at lane `to`. Bottom half: from
    /// the center at `from` to the bottom edge at `to`. Bends turn with `bendRadius` (less when the lanes are closer;
    /// none when a folded node sits on the other lane: the bend is then a straight line). Lanes are at their drawn x
    /// (`GraphMetrics.drawnX`).
    private static func stroke(
        _ segment: GraphSegment, top: Bool, metrics: GraphMetrics, bounds: CGRect, context: CGContext
    ) {
        let fromX = bounds.minX + metrics.drawnX(lane: segment.from, width: bounds.width)
        let toX = bounds.minX + metrics.drawnX(lane: segment.to, width: bounds.width)
        let midY = bounds.midY
        let radius = min(metrics.bendRadius, abs(toX - fromX), bounds.height / 2)
        Palette.graphLane(segment.color).setStroke()
        if segment.isDashed { context.setLineDash(phase: 0, lengths: [3, 3]) }
        switch (segment.shape, top) {
        case (.bendIn, _):
            // Down lane `from`, then across to the node.
            context.move(to: CGPoint(x: fromX, y: bounds.minY))
            context.addArc(tangent1End: CGPoint(x: fromX, y: midY), tangent2End: CGPoint(x: toX, y: midY),
                           radius: radius)
            context.addLine(to: CGPoint(x: toX, y: midY))
        case (.bendOut, _):
            // Across from the node, then down lane `to`.
            context.move(to: CGPoint(x: fromX, y: midY))
            context.addArc(tangent1End: CGPoint(x: toX, y: midY), tangent2End: CGPoint(x: toX, y: bounds.maxY),
                           radius: radius)
            context.addLine(to: CGPoint(x: toX, y: bounds.maxY))
        case (.straight, true):
            context.move(to: CGPoint(x: fromX, y: bounds.minY))
            context.addLine(to: CGPoint(x: toX, y: midY))
        case (.straight, false):
            context.move(to: CGPoint(x: fromX, y: midY))
            context.addLine(to: CGPoint(x: toX, y: bounds.maxY))
        }
        context.strokePath()
        if segment.isDashed { context.setLineDash(phase: 0, lengths: []) }
    }

    private static func drawNode(
        _ node: GraphNodeStyle, color: NSColor, band: NSColor, avatar: NSImage?, center: CGPoint,
        metrics: GraphMetrics, context: CGContext
    ) {
        let diameter = metrics.nodeDiameter
        switch node {
        case .merge:
            let dot = metrics.mergeDotDiameter
            color.setFill()
            context.fillEllipse(in: CGRect(x: center.x - dot / 2, y: center.y - dot / 2, width: dot, height: dot))
        case .wip:
            let rect = CGRect(x: center.x - diameter / 2 + 1, y: center.y - diameter / 2 + 1,
                              width: diameter - 2, height: diameter - 2)
            Palette.graphSurface.setFill()
            context.fillEllipse(in: rect)
            band.setFill()
            context.fillEllipse(in: rect)
            color.setStroke()
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [2.5, 2.5])
            context.strokeEllipse(in: rect)
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(metrics.lineWidth)
        case .stash:
            // The WIP circle's size, as a square.
            let rect = CGRect(x: center.x - diameter / 2 + 1, y: center.y - diameter / 2 + 1,
                              width: diameter - 2, height: diameter - 2)
            let path = CGPath(roundedRect: rect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            Palette.graphSurface.setFill()
            context.addPath(path)
            context.fillPath()
            band.setFill()
            context.addPath(path)
            context.fillPath()
            color.setStroke()
            context.setLineWidth(1.5)
            context.setLineDash(phase: 0, lengths: [2.5, 2.5])
            context.addPath(path)
            context.strokePath()
            context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(metrics.lineWidth)
            if let tray = trayIcon(color: color, nodeDiameter: diameter) {
                let size = tray.size
                tray.draw(in: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                                     width: size.width, height: size.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .commit(let initials):
            let rect = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            color.setFill()
            context.fillEllipse(in: rect)
            if let avatar {
                // A 1.5 pt ring of the lane color around the avatar.
                let inner = rect.insetBy(dx: 1.5, dy: 1.5)
                context.saveGState()
                context.addEllipse(in: inner)
                context.clip()
                avatar.draw(in: inner)
                context.restoreGState()
            } else if !initials.isEmpty {
                let text = initialsString(initials, size: metrics.nodeDiameter)
                let size = text.size()
                text.draw(at: CGPoint(x: center.x - size.width / 2, y: center.y - size.height / 2))
            }
        }
    }

    /// The stash node's tray symbols, by color and node size: one per lane color.
    private static var trayCache: [String: NSImage] = [:]

    private static func trayIcon(color: NSColor, nodeDiameter: CGFloat) -> NSImage? {
        let key = "\(color)|\(nodeDiameter)"
        if let cached = trayCache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: (nodeDiameter * 0.5).rounded(), weight: .semibold)
            .applying(.init(paletteColors: [color]))
        let image = NSImage(systemSymbolName: "tray", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        trayCache[key] = image
        return image
    }

    /// The initials' strings, by initials and node size: a few hundred at most in any repo.
    private static var initialsCache: [String: NSAttributedString] = [:]

    private static func initialsString(_ initials: String, size: CGFloat) -> NSAttributedString {
        let key = "\(initials)|\(size)"
        if let cached = initialsCache[key] { return cached }
        let font = NSFont.systemFont(ofSize: (size * 0.42).rounded(), weight: .semibold)
        let string = NSAttributedString(
            string: initials, attributes: [.font: font, .foregroundColor: Palette.graphNodeText])
        initialsCache[key] = string
        return string
    }

    /// Up to two letters: the first of the name's first and last words (`Ada Lovelace` -> `AL`).
    static func initials(of name: String) -> String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" || $0 == "-" })
        guard let first = words.first?.first else { return "" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }
}

/// The graph column's cell: draws its row with `GraphRowDrawing`. Reused by the table as it scrolls.
final class GraphCellView: NSView {
    var row: GraphRow?
    var node: GraphNodeStyle = .merge
    var hasRefs = false
    /// The row shows only a ghost badge (`RefBadge.isGhost`): its line to the node is faded.
    var hasGhostRef = false
    /// 5.2's avatar for the node; initials while nil.
    var avatar: NSImage?
    var metrics = GraphMetrics(density: "regular")
    /// The most lanes a row of the loaded log draws in: with one visible lane, a log of more draws no lines.
    var logLanes = 1

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let row, let context = NSGraphicsContext.current?.cgContext else { return }
        GraphRowDrawing.draw(row, node: node, hasRefs: hasRefs || hasGhostRef,
                             refsAlpha: hasRefs ? 1 : Palette.graphGhostAlpha, avatar: avatar, metrics: metrics,
                             logLanes: logLanes, in: bounds, context: context)
    }
}

extension Palette {
    /// A `GraphRow` or `GraphSegment` color: its lane color, or the stash grey.
    static func graphLane(_ color: Int) -> NSColor {
        color == GraphLayout.stashColor ? graphStash : graphLanes[color % graphLanes.count]
    }

    /// The band of a row of `color`.
    static func graphLaneBand(_ color: Int) -> NSColor {
        color == GraphLayout.stashColor ? graphStashBand : graphLaneBands[color % graphLaneBands.count]
    }
}
