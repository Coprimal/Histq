// The command palette's state (ported from Dblore's `CommandPaletteModel`): the rows copied when it opens, the query,
// and the rows ranked for it off the main actor (`FuzzyRank`), one rank task per keystroke, the older one cancelled.
import Foundation
import HistqCore
import Observation

@MainActor
@Observable
final class CommandPaletteModel {
    /// The most rows a query shows.
    static let limit = 50

    var query: String {
        didSet {
            guard query != oldValue else { return }
            schedule()
        }
    }

    /// The rows that match the query, best first, at most `limit`. They stay on screen until the next query's rank
    /// lands.
    private(set) var ranked: [PaletteItem] = []

    /// Bumped on each query; `ranked` belongs to the query of `rankedGeneration`. Observed, so a keystroke that
    /// makes the rows stale redraws the view.
    private var generation = 0
    private var rankedGeneration = -1

    /// `ranked` belongs to the current query.
    var isRankFresh: Bool { rankedGeneration == generation }
    /// The current query's rows are in, and there are none.
    var showsNoMatches: Bool { isRankFresh && ranked.isEmpty }

    @ObservationIgnored private let items: [PaletteItem]
    @ObservationIgnored private let actions: [Int: @MainActor () -> Void]
    @ObservationIgnored private var rankTask: Task<Void, Never>?

    /// Ranks `snapshot` for `query` at once (off the main actor). An empty query takes the first rows here, so they
    /// show in the palette's first frame.
    init(snapshot: PaletteSnapshot, query: String = "") {
        items = snapshot.items
        actions = snapshot.actions
        self.query = query
        if FuzzyRank.keywords(in: query).isEmpty {
            ranked = Array(items.prefix(Self.limit))
            rankedGeneration = generation
        } else {
            schedule()
        }
    }

    /// The row's action, when Return or a click may run it: an enabled row of the current query's results (never one
    /// left over from an older query).
    func action(for item: PaletteItem) -> (@MainActor () -> Void)? {
        guard item.isEnabled, isRankFresh, ranked.contains(item) else { return nil }
        return actions[item.id]
    }

    private func schedule() {
        // The previous rows stay on screen; the new generation marks them stale for Return.
        generation += 1
        let generation = generation
        let items = items
        let query = query
        let limit = Self.limit
        rankTask?.cancel()
        let start = DispatchTime.now().uptimeNanoseconds
        rankTask = Task.detached(priority: .userInitiated) { [weak self] in
            var steps = UITiming.Steps()
            let keys = items.map(\.searchKeys)
            steps.lap("keys")
            let indices = FuzzyRank.rank(keys, query: query, limit: limit)
            steps.lap("rank")
            guard !Task.isCancelled else { return }
            let ranked = indices.map { items[$0] }
            await self?.adopt(ranked, generation: generation, query: query, start: start, steps: steps)
        }
    }

    private func adopt(_ ranked: [PaletteItem], generation: Int, query: String, start: UInt64,
                       steps: UITiming.Steps)
    {
        guard generation == self.generation else { return }
        self.ranked = ranked
        rankedGeneration = generation
        UITiming.palette("rank \"\(query)\" rows=\(items.count) \(steps.description) adopt="
            + String(format: "%.1f", Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000))
    }

    deinit {
        rankTask?.cancel()
    }
}
