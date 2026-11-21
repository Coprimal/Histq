// Key feature test for manual tab groups (tasks 1.1, 3.1): after the tabs are put in order, a group never splits a
// worktree box, an ungrouped tab joining a grouped box takes the box's group, and pinned tabs lose their group; a
// drop between two tabs of a group joins it, and a dragged box always moves whole.
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

    @Test("A tab dropped between two tabs of a group joins it")
    func dropBetweenGroupTabsJoins() {
        let g = UUID()
        let t = Entry(id: UUID())
        let a = Entry(id: UUID(), group: g)
        let b = Entry(id: UUID(), group: g)
        let tabs = [t, a, b]
        // Without t, a and b sit at 0 and 1: place 1 is between them.
        #expect(TabArrangement.destinations(for: .tab(t.id), targetGroup: g, in: tabs).contains(1))
        #expect(!TabArrangement.destinations(for: .tab(t.id), targetGroup: nil, in: tabs).contains(1))
        let result = TabArrangement.move(unit: .tab(t.id), to: 1, group: g, in: tabs)
        #expect(TabArrangement.segments(result.tabs) == [.group(g, [.tab(a.id), .tab(t.id), .tab(b.id)])])
        #expect(result.groups == [g])
    }

    @Test("A dragged worktree box moves whole to every allowed place, in or out of a group")
    func boxMovesWhole() {
        let g = UUID()
        let p = Entry(id: UUID(), pinned: true)
        let w1 = Entry(id: UUID(), repo: "r")
        let w2 = Entry(id: UUID(), repo: "r")
        let a = Entry(id: UUID(), group: g)
        let x = Entry(id: UUID(), repo: "s", group: g)
        let y = Entry(id: UUID(), repo: "s", group: g)
        let q = Entry(id: UUID())
        let z = Entry(id: UUID(), repo: "r", archived: true)
        let tabs = TabArrangement.normalized([p, w1, w2, a, x, y, q, z]).tabs
        for target in [g, nil] as [UUID?] {
            let places = TabArrangement.destinations(for: .box("r"), targetGroup: target, in: tabs)
            // Without the box: p, a, x, y, q, z. Never 3 (between x and y, the box of "s").
            #expect(places == (target == nil ? [1, 4, 5] : [1, 2, 4]))
            for place in places {
                let result = TabArrangement.move(unit: .box("r"), to: place, group: target, in: tabs)
                let ids = result.tabs.map(\.id)
                #expect(ids.firstIndex(of: w1.id) == place)
                #expect(ids.firstIndex(of: w2.id) == place + 1)
                #expect(result.tabs[place].group == target && result.tabs[place + 1].group == target)
                #expect(ids.last == z.id)
            }
        }
    }
}
