// The sidebar's ref tree: `backup/one` and `backup/two` share a `backup` folder row, nested folders go one step
// deeper each, and a collapsed folder lists none of its rows.
import HistqCore
import Testing

struct RefTreeTests {
    private func lines(_ names: [String], collapsed: Set<String> = []) -> [String] {
        RefTree.rows(names, name: { $0 }, isCollapsed: collapsed.contains).map { row in
            let indent = String(repeating: "  ", count: row.depth)
            switch row.kind {
            case .folder: return "\(indent)[\(row.name)]"
            case .ref(let name): return "\(indent)\(row.name) = \(name)"
            }
        }
    }

    @Test("Names sharing a prefix go under one folder where the first of them is, even when not adjacent")
    func groupsByPrefix() {
        #expect(lines(["backup/one", "main", "backup/two", "feature/ui/x", "feature/y"]) == [
            "[backup]",
            "  one = backup/one",
            "  two = backup/two",
            "main = main",
            "[feature]",
            "  [ui]",
            "    x = feature/ui/x",
            "  y = feature/y",
        ])
    }

    @Test("A collapsed folder keeps its row and hides its rows, nested folders included")
    func collapsedFolder() {
        #expect(lines(["feature/ui/x", "feature/y", "main"], collapsed: ["feature"]) == ["[feature]", "main = main"])
        #expect(lines(["feature/ui/x", "feature/y"], collapsed: ["feature/ui"]) == [
            "[feature]", "  [ui]", "  y = feature/y",
        ])
    }

    @Test("Row ids are unique: a folder's path ends with a slash")
    func uniqueIDs() {
        let ids = RefTree.rows(["a/b", "a/c/d"], name: { $0 }).map(\.id)
        #expect(ids == ["a/", "a/b", "a/c/", "a/c/d"])
    }
}
