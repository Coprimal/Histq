// Lays out the commit graph as a streaming fold over `LogReader` pages: lanes are slots waiting for a
// parent hash, so each row needs only the open lanes, never the rows above it, and a page can be laid
// out as soon as git delivers it. Free slots are reused, which keeps the width bounded by the number of
// branches open at that point of the history.
import Foundation

/// One line piece in one half of a row. A top segment runs from the row's top edge at lane `from` to the
/// row's center at lane `to`; a bottom segment from the center at lane `from` to the bottom edge at lane
/// `to`. Lanes never shift, so only the lines that meet the node bend.
public struct GraphSegment: Sendable, Hashable {
    public enum Shape: Sendable, Hashable {
        /// Stays in its lane (`from == to`): a lane passing by, or the node's own lane.
        case straight
        /// Top half only: a child's line coming down lane `from` and bending into the node (`to`).
        case bendIn
        /// Bottom half only: a line leaving the node (`from`) and bending out to lane `to`, towards a
        /// merge's other parent.
        case bendOut
    }

    public let shape: Shape
    public let from: Int
    public let to: Int
    /// Index into the lane palette, `0..<GraphLayout.colorCount`, or `GraphLayout.stashColor`.
    public let color: Int
    /// The line between a synthetic row (WIP, stash) and its base commit.
    public let isDashed: Bool

    public init(shape: Shape, from: Int, to: Int, color: Int, isDashed: Bool) {
        self.shape = shape
        self.from = from
        self.to = to
        self.color = color
        self.isDashed = isDashed
    }
}

/// A row that is not a commit of the log: the working tree changes, a stash, or another worktree's
/// changes. It is drawn on a lane that leads to its base commit's node.
public struct GraphSyntheticRow: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case wip
        case stash
        case worktreeWIP
    }

    public let kind: Kind
    /// Identifies the row for the app, e.g. the stash hash or the worktree path.
    public let id: String
    /// The commit the row hangs from (HEAD, the stash's base, the worktree's HEAD); nil in an unborn repo.
    public let base: String?

    public init(kind: Kind, id: String, base: String?) {
        self.kind = kind
        self.id = id
        self.base = base
    }
}

/// One laid-out row: where its node sits, its color, and the line pieces of both halves.
public struct GraphRow: Sendable, Hashable {
    public enum Node: Sendable, Hashable {
        case commit(hash: String, isMerge: Bool)
        case synthetic(GraphSyntheticRow)
    }

    public let node: Node
    /// The node's lane (column index, 0 = leftmost).
    public let lane: Int
    /// The node's palette index (also the row band and badge line color).
    public let color: Int
    /// Segments from the top edge to the center, ordered by `from`.
    public let top: [GraphSegment]
    /// Segments from the center to the bottom edge: lanes passing by and the node's own lane (straight),
    /// then the node's lines to a merge's other parents (bendOut).
    public let bottom: [GraphSegment]
    /// Number of lanes this row draws in (highest lane used + 1).
    public let width: Int
}

/// A synthetic row laid out just above its base commit (`GraphLayout.hang`).
public struct GraphHungRow: Sendable, Hashable {
    /// The index of the base commit among every commit the layout was fed: the row sits right above it.
    public let above: Int
    public let synthetic: GraphSyntheticRow
    public let row: GraphRow
}

/// The resumable layout state. Feed the synthetic rows that sit at the top first, hang the ones that sit
/// above their base commit, then feed every `LogReader` page in order; each call returns the rows for what
/// it was given, and hung rows land in `hung` as their base comes. The state is a value: a copy can be kept
/// and resumed later.
///
/// A parent that never gets a row (shallow or partial history, a record the parser dropped, a synthetic
/// row fed after its base) keeps its lane open to the end; a duplicate hash is laid out as a new tip.
public struct GraphLayout: Sendable {
    public static let colorCount = 8
    /// The color of a stash row and its line to its base: outside the lane palette (the app draws it grey), so a
    /// stash never takes a branch's color, and the commit it hangs from never takes the stash's.
    public static let stashColor = colorCount

    /// Which kind of edge a lane is waiting along; when several lanes wait for the same commit, the node
    /// continues the most important one so a branch's first-parent chain keeps its lane and color.
    private enum Edge: UInt8, Comparable {
        case firstParent, mergeParent, synthetic
        static func < (a: Edge, b: Edge) -> Bool { a.rawValue < b.rawValue }
    }

    private struct Lane {
        var waitingFor: String
        var color: Int
        var edge: Edge
    }

    private var lanes: [Lane?] = []
    private var nextColor = 0
    /// Hung rows whose base has not come yet, in the order they were hung.
    public private(set) var waiting: [GraphSyntheticRow] = []
    private var waitingBases: Set<String> = []
    /// The hung rows laid out so far, top first.
    public private(set) var hung: [GraphHungRow] = []
    /// Commits laid out so far.
    private var placed = 0

    public init() {}

    /// Lays out synthetic rows, each on a new lane that leads down to its base commit.
    public mutating func append(_ synthetic: [GraphSyntheticRow]) -> [GraphRow] {
        synthetic.map { place($0) }
    }

    /// Hangs synthetic rows above their base commit: each is laid out (into `hung`) right before that commit's
    /// row, in the order given. A row without a base, or whose base never comes, stays in `waiting`.
    public mutating func hang(_ synthetic: [GraphSyntheticRow]) {
        waiting += synthetic
        for row in synthetic { if let base = row.base { waitingBases.insert(base) } }
    }

    /// Lays out one page of commits (in `--topo-order`, children before parents).
    public mutating func append(_ commits: [Commit]) -> [GraphRow] {
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)
        for commit in commits {
            if !waitingBases.isEmpty, waitingBases.remove(commit.hash) != nil {
                for row in waiting where row.base == commit.hash {
                    hung.append(GraphHungRow(above: placed, synthetic: row, row: place(row)))
                }
                waiting.removeAll { $0.base == commit.hash }
            }
            rows.append(place(commit))
            placed += 1
        }
        return rows
    }

    private mutating func place(_ row: GraphSyntheticRow) -> GraphRow {
        let lane = freeSlot()
        let color = row.kind == .stash ? Self.stashColor : newColor()
        let top = passingSegments()
        if let base = row.base {
            lanes[lane] = Lane(waitingFor: base, color: color, edge: .synthetic)
        }
        trimFreeSlots()
        let bottom = passingSegments()
        return makeRow(.synthetic(row), lane: lane, color: color, top: top, bottom: bottom)
    }

    private mutating func place(_ commit: Commit) -> GraphRow {
        // Lanes waiting for this commit end at its node; the node continues the best of them.
        var node = -1
        var best: Edge?
        var top: [GraphSegment] = []
        for index in lanes.indices {
            guard let lane = lanes[index], lane.waitingFor == commit.hash else { continue }
            // Among the lines of synthetic rows, a WIP's (colored) wins over a stash's (grey).
            if best == nil || lane.edge < best! || (lane.edge == best! && lanes[node]!.color == Self.stashColor) {
                node = index
                best = lane.edge
            }
        }
        let color: Int
        if node >= 0, lanes[node]!.color != Self.stashColor {
            color = lanes[node]!.color
        } else {
            // A tip, or a commit only stashes hang from: a color of its own.
            if node < 0 { node = freeSlot() }
            color = newColor()
        }
        for index in lanes.indices {
            guard let lane = lanes[index] else { continue }
            let dashed = lane.edge == .synthetic
            if lane.waitingFor == commit.hash {
                let shape: GraphSegment.Shape = index == node ? .straight : .bendIn
                top.append(GraphSegment(shape: shape, from: index, to: node, color: lane.color, isDashed: dashed))
                lanes[index] = nil
            } else {
                top.append(GraphSegment(shape: .straight, from: index, to: index, color: lane.color, isDashed: dashed))
            }
        }

        // The first parent continues the node's lane; the others join a lane already waiting for them, or
        // open one.
        var parents: [String] = []
        for parent in commit.parents where !parents.contains(parent) { parents.append(parent) }
        var outgoing: [GraphSegment] = []
        var opened: [Int] = []
        if let first = parents.first {
            lanes[node] = Lane(waitingFor: first, color: color, edge: .firstParent)
        }
        for parent in parents.dropFirst() {
            let joined = lanes.firstIndex { $0?.waitingFor == parent && $0?.edge != .synthetic }
            let target: Int
            if let joined {
                target = joined
            } else {
                target = freeSlot()
                lanes[target] = Lane(waitingFor: parent, color: newColor(), edge: .mergeParent)
                opened.append(target)
            }
            outgoing.append(
                GraphSegment(shape: .bendOut, from: node, to: target, color: lanes[target]!.color, isDashed: false))
        }
        trimFreeSlots()

        var bottom = passingSegments(skipping: opened)
        bottom += outgoing
        return makeRow(.commit(hash: commit.hash, isMerge: commit.isMerge), lane: node, color: color, top: top, bottom: bottom)
    }

    /// A straight segment for every open lane.
    private func passingSegments(skipping skipped: [Int] = []) -> [GraphSegment] {
        var segments: [GraphSegment] = []
        for index in lanes.indices where !skipped.contains(index) {
            guard let lane = lanes[index] else { continue }
            segments.append(
                GraphSegment(
                    shape: .straight, from: index, to: index, color: lane.color, isDashed: lane.edge == .synthetic))
        }
        return segments
    }

    private func makeRow(
        _ node: GraphRow.Node, lane: Int, color: Int, top: [GraphSegment], bottom: [GraphSegment]
    ) -> GraphRow {
        var highest = lane
        for segment in top { highest = max(highest, segment.from, segment.to) }
        for segment in bottom { highest = max(highest, segment.from, segment.to) }
        return GraphRow(node: node, lane: lane, color: color, top: top, bottom: bottom, width: highest + 1)
    }

    /// The leftmost free slot, growing the lane list when none is free. The slot stays free until set.
    private mutating func freeSlot() -> Int {
        if let index = lanes.firstIndex(where: { $0 == nil }) { return index }
        lanes.append(nil)
        return lanes.count - 1
    }

    private mutating func trimFreeSlots() {
        while let last = lanes.last, last == nil { lanes.removeLast() }
    }

    private mutating func newColor() -> Int {
        defer { nextColor = (nextColor + 1) % Self.colorCount }
        return nextColor
    }
}
