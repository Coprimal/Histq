// Key feature test for manual tab groups (task 1.1): after the tabs are put in order, a group never splits a worktree
// box, an ungrouped tab joining a grouped box takes the box's group, and pinned tabs lose their group.
import Foundation
import HistqCore
import Testing

struct TabArrangementTests {
    private typealias Entry = TabArrangement.Entry

    @Test("A worktree box whose tabs sit apart gathers whole into the group of its first grouped tab")
    func groupNeverSplitsBox() {
        let g = UUID(), h = UUID()
        let p1 = Entry(id: UUID(), group: g)
        let w1 = Entry(id: UUID(), repo: "r", group: g)
        let q = Entry(id: UUID())
        let w2 = Entry(id: UUID(), repo: "r", group: h)
        let p2 = Entry(id: UUID(), group: h)
        let result = TabArrangement.normalized([p1, w1, q, w2, p2])
        #expect(TabArrangement.segments(result.tabs) == [
            .group(g, [.tab(p1.id), .box("r", [w1.id, w2.id])]),
            .tab(q.id),
            .group(h, [.tab(p2.id)]),
        ])
        #expect(result.groups == [g, h])
    }

    @Test("An ungrouped tab before a grouped box joins the box's group, which survives")
    func ungroupedTabJoinsBoxGroup() {
        let g = UUID()
        let w0 = Entry(id: UUID(), repo: "r")
        let w1 = Entry(id: UUID(), repo: "r", group: g)
        let w2 = Entry(id: UUID(), repo: "r", group: g)
        let result = TabArrangement.normalized([w0, w1, w2])
        #expect(TabArrangement.segments(result.tabs) == [.group(g, [.box("r", [w0.id, w1.id, w2.id])])])
        #expect(result.groups == [g])
    }

    @Test("A pinned tab pins its whole box, loses its group and comes first")
    func pinnedTabLosesGroup() {
        let g = UUID()
        let t = Entry(id: UUID())
        let w1 = Entry(id: UUID(), repo: "r", group: g)
        let w2 = Entry(id: UUID(), repo: "r", group: g, pinned: true)
        let result = TabArrangement.normalized([t, w1, w2])
        #expect(result.tabs.map(\.id) == [w1.id, w2.id, t.id])
        #expect(result.tabs.map(\.pinned) == [true, true, false])
        #expect(result.tabs.allSatisfy { $0.group == nil })
        #expect(result.groups.isEmpty)
        #expect(TabArrangement.segments(result.tabs) == [.box("r", [w1.id, w2.id]), .tab(t.id)])
    }
}
