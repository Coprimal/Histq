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

    /// A commit's node (its avatar's circle): as tall as the row less a 1 pt gap above and below, as in GitKraken, so
    /// the lane line still shows between two stacked avatars (30 pt at regular).
    var nodeDiameter: CGFloat { rowHeight - 2 }
    /// From one lane's center to the next: a node and a small gap.
    var laneWidth: CGFloat { nodeDiameter + 4 }
    /// Before lane 0.
    var leading: CGFloat { 6 }
    /// After the last lane, clear of the band's 2 pt bar at the column's right edge.
    var trailing: CGFloat { 6 }
    /// A merge commit's dot: scales with the node, kept even so it centers on whole pixels.
    var mergeDotDiameter: CGFloat { 2 * (nodeDiameter * 0.2).rounded() }
    var lineWidth: CGFloat { 2 }
    /// The radius of a line's bend into or out of a node: a third of the node.
    var bendRadius: CGFloat { (nodeDiameter / 3).rounded() }
    /// The band's and the badges' inset from the row's top and bottom.
    var bandInset: CGFloat { 3 }
    /// A stash node's box side: about 0.7 of the node, kept even so the box's edges sit on whole points.
    var stashSide: CGFloat { 2 * (nodeDiameter * 0.35).rounded() }

    /// The center of `lane`, from the graph column's left edge.
    func x(lane: Int) -> CGFloat { leading + CGFloat(lane) * laneWidth + laneWidth / 2 }

    /// The graph column's width that shows `lanes` lanes.
    func width(lanes: Int) -> CGFloat { leading + CGFloat(lanes) * laneWidth + trailing }

    /// How many lanes a graph column `width` wide shows, at least one (the inverse of `width(lanes:)`).
    func visibleLanes(width: CGFloat) -> Int {
        max(1, Int(((width - leading - trailing) / laneWidth + 0.001).rounded(.down)))
    }

    /// Where `lane` is drawn when only `visible` lanes show: a lane past them folds onto the last visible one, as in
    /// GitKraken (the rightmost lanes fold first as the column narrows, down to lane 0).
    func foldedLane(_ lane: Int, visible: Int) -> Int { min(lane, visible - 1) }

    /// Half the drawn width of `node`'s shape with its stroke (`GraphRowDrawing.drawNode`), rounded out to a whole
    /// point so an edge drawn there stays crisp.
    func nodeRadius(_ node: GraphNodeStyle) -> CGFloat {
        switch node {
        case .commit: nodeDiameter / 2
        case .merge: mergeDotDiameter / 2
        // The dashed circle is inset by 1 pt and stroked 1.5 pt: it reaches 0.25 pt short of the node.
        case .wip: nodeDiameter / 2
        // The box is stroked 1.5 pt on its edge: 0.25 pt short of this.
        case .stash: (stashSide / 2 + 0.75).rounded(.up)
        }
    }

    /// The left edge of `node` on `lane`, from the graph column's left edge: where a selected row's highlight starts.
    func nodeMinX(lane: Int, node: GraphNodeStyle) -> CGFloat { x(lane: lane) - nodeRadius(node) }
}

/// What a row's node stands for.
enum GraphNodeStyle: Equatable {
    /// A commit: its author's initials (5.2 adds the avatar).
    case commit(initials: String)
    /// A merge commit: a small dot.
    case merge
    /// The working tree's changes: a dashed circle.
    case wip
    /// A stash: a small box.
    case stash
}

@MainActor
enum GraphRowDrawing {
    /// Draws `row` in `bounds` (a flipped view's bounds, the graph column's cell), clipped to it. `hasRefs` draws the
    /// line from the column's left edge (where the ref badges' line ends) to the node, at `refsAlpha` (a ghost badge's
    /// is faded). `avatar`, when given, fills the node.
    ///
    /// When `bounds` is narrower than the log's `logLanes`, the lanes past the visible ones fold onto the last visible
    /// lane (`GraphMetrics.foldedLane`): their nodes are drawn there, over its line, and their own lines are not. A
    /// line between a visible lane and a folded one is drawn only when its folded end is this row's node (it then ends
    /// under the node); one that would run on down or up a folded lane is left out, so no line dangles. With a single
    /// visible lane in a log of several, no lane line is drawn at all (GitKraken's collapsed column): the nodes' ring
    /// colors and the band's edge bar tell the branches apart.
    static func draw(
        _ row: GraphRow, node: GraphNodeStyle, hasRefs: Bool, refsAlpha: CGFloat = 1, avatar: NSImage?,
        metrics: GraphMetrics, logLanes: Int, in bounds: CGRect, context: CGContext
    ) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: bounds)

        let lanes = Palette.graphLanes
        let colorCount = lanes.count
        let visible = metrics.visibleLanes(width: bounds.width)
        let nodeX = bounds.minX + metrics.x(lane: metrics.foldedLane(row.lane, visible: visible))
        let midY = bounds.midY
        let laneColor = lanes[row.color % colorCount]

        // The band, from the node to the column's edge, ending in a 2 pt bar in the lane color (gk's message marker).
        let band = CGRect(x: nodeX, y: bounds.minY + metrics.bandInset,
                          width: max(0, bounds.maxX - nodeX), height: bounds.height - 2 * metrics.bandInset)
        if band.width > 0 {
            Palette.graphLaneBands[row.color % colorCount].setFill()
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

        if visible > 1 || logLanes <= 1 {
            // A segment's edge end (top or bottom) must be on a visible lane; its center end may also be the node.
            func shows(_ lane: Int, atCenter: Bool) -> Bool { lane < visible || (atCenter && lane == row.lane) }
            for segment in row.top where shows(segment.from, atCenter: false) && shows(segment.to, atCenter: true) {
                stroke(segment, top: true, visible: visible, metrics: metrics, bounds: bounds, context: context)
            }
            for segment in row.bottom where shows(segment.from, atCenter: true) && shows(segment.to, atCenter: false) {
                stroke(segment, top: false, visible: visible, metrics: metrics, bounds: bounds, context: context)
            }
        }

        drawNode(node, color: laneColor, band: Palette.graphLaneBands[row.color % colorCount], avatar: avatar,
                 center: CGPoint(x: nodeX, y: midY), metrics: metrics, context: context)
    }

    /// One line piece. Top half: from the row's top edge at lane `from` to the center at lane `to`. Bottom half: from
    /// the center at `from` to the bottom edge at `to`. Bends turn with `bendRadius` (less when the lanes are closer;
    /// none when a folded node sits on the other lane: the bend is then a straight line). Lanes fold to `visible`.
    private static func stroke(
        _ segment: GraphSegment, top: Bool, visible: Int, metrics: GraphMetrics, bounds: CGRect, context: CGContext
    ) {
        let fromX = bounds.minX + metrics.x(lane: metrics.foldedLane(segment.from, visible: visible))
        let toX = bounds.minX + metrics.x(lane: metrics.foldedLane(segment.to, visible: visible))
        let midY = bounds.midY
        let radius = min(metrics.bendRadius, abs(toX - fromX), bounds.height / 2)
        Palette.graphLanes[segment.color % Palette.graphLanes.count].setStroke()
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
            let side = metrics.stashSide
            let rect = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            Palette.graphSurface.setFill()
            context.addPath(path)
            context.fillPath()
            band.setFill()
            context.addPath(path)
            context.fillPath()
            color.setStroke()
            context.setLineWidth(1.5)
            context.addPath(path)
            context.strokePath()
            // The box's lid.
            context.move(to: CGPoint(x: rect.minX + 3, y: rect.midY - 1))
            context.addLine(to: CGPoint(x: rect.maxX - 3, y: rect.midY - 1))
            context.strokePath()
            context.setLineWidth(metrics.lineWidth)
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
