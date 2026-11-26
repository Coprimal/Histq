// A list of refs as a tree, the sidebar's way to show `backup/one`: their names split at "/", every leading component
// a folder row with the rest nested one step under it, as a file tree's folders.
import Foundation

/// A row of `RefTree.rows`: a folder or a ref, its last name component and how many folders it is nested in.
public struct RefTreeRow<Ref>: Identifiable {
    public enum Kind {
        /// A folder, by its path from the list's root (`backup`, `feature/ui`).
        case folder(path: String)
        case ref(Ref)
    }

    public let kind: Kind
    /// The last component of the folder's path or the ref's name (`one` of `backup/one`).
    public let name: String
    public let depth: Int
    /// A ref's full name; a folder's path with a trailing "/", which no ref name has.
    public let id: String
}

public enum RefTree {
    /// `refs` as rows: a name with a "/" goes under a folder row for its first component, recursively. Each folder sits
    /// where its first ref is, so every level keeps the list's order. A folder `isCollapsed` (by its path) lists none
    /// of its rows.
    public static func rows<Ref>(_ refs: [Ref], name: (Ref) -> String,
                                 isCollapsed: (String) -> Bool = { _ in false }) -> [RefTreeRow<Ref>] {
        var rows: [RefTreeRow<Ref>] = []
        let items = refs.map { ref in
            let full = name(ref)
            return Item(ref: ref, fullName: full, components: full.split(separator: "/")[...])
        }
        append(items, path: "", depth: 0, isCollapsed: isCollapsed, to: &rows)
        return rows
    }

    private struct Item<Ref> {
        let ref: Ref
        let fullName: String
        /// The components left at this level.
        let components: ArraySlice<Substring>
    }

    private enum Entry {
        case ref(Int)
        case folder(String)
    }

    private static func append<Ref>(_ items: [Item<Ref>], path: String, depth: Int, isCollapsed: (String) -> Bool,
                                    to rows: inout [RefTreeRow<Ref>]) {
        var entries: [Entry] = []
        var folders: [String: [Item<Ref>]] = [:]
        for (index, item) in items.enumerated() {
            guard item.components.count > 1, let first = item.components.first else {
                entries.append(.ref(index))
                continue
            }
            let folder = String(first)
            if folders[folder] == nil { entries.append(.folder(folder)) }
            folders[folder, default: []].append(
                Item(ref: item.ref, fullName: item.fullName, components: item.components.dropFirst()))
        }
        for entry in entries {
            switch entry {
            case .ref(let index):
                let item = items[index]
                rows.append(RefTreeRow(kind: .ref(item.ref), name: item.components.last.map(String.init) ?? item.fullName,
                                       depth: depth, id: item.fullName))
            case .folder(let name):
                let folderPath = path.isEmpty ? name : "\(path)/\(name)"
                rows.append(RefTreeRow(kind: .folder(path: folderPath), name: name, depth: depth, id: folderPath + "/"))
                if !isCollapsed(folderPath) {
                    append(folders[name] ?? [], path: folderPath, depth: depth + 1, isCollapsed: isCollapsed, to: &rows)
                }
            }
        }
    }
}
