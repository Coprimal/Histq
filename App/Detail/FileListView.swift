// The changed files of a commit, a stash or the working tree, as one row per path or as a folder tree (the toggle
// is saved in `PrefKey.fileListMode`). Each row has a status icon, a context menu (the caller's entries, such as
// "Checkout File from This Commit", then Copy Path and Reveal in Finder) and the caller's trailing buttons (stage,
// unstage, discard). A click on a row opens that file's diff when the caller asks for it (`onSelectFile`).
import AppKit
import SwiftUI

/// One changed file of a list.
struct FileChange: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case added, modified, deleted, renamed, copied, typeChanged, untracked, conflicted
        /// A file of the commit's tree it did not change (the Files card's "View all files").
        case unchanged
    }

    let kind: Kind
    /// Root-relative.
    let path: String
    /// The path before a rename or copy.
    var originalPath: String?
    /// A submodule's pointer (a gitlink): its row shows the submodule icon and its diff the pointer change.
    var isSubmodule = false

    var id: String { path }

    init(kind: Kind, path: String, originalPath: String? = nil, isSubmodule: Bool = false) {
        self.kind = kind
        self.path = path
        self.originalPath = originalPath
        self.isSubmodule = isSubmodule
    }

    /// From git's one-letter status (`M`, `A`, `D`, `R`, `C`, `T`, `U`; anything else reads as modified).
    init(letter: Character, path: String, originalPath: String? = nil, isSubmodule: Bool = false) {
        let kind: Kind = switch letter {
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "T": .typeChanged
        case "U": .conflicted
        default: .modified
        }
        self.init(kind: kind, path: path, originalPath: originalPath, isSubmodule: isSubmodule)
    }

    /// The bare glyph, no circle or square behind it, drawn in `tint`; a submodule's is the sidebar's.
    var systemImage: String {
        if isSubmodule { return SidebarMetrics.submoduleImage }
        return switch kind {
        case .added, .untracked: "plus"
        case .modified, .typeChanged: "pencil"
        case .deleted: "minus"
        case .renamed, .copied: "arrow.right"
        case .conflicted: "exclamationmark.triangle"
        case .unchanged: "doc"
        }
    }

    /// File-kind colors: orange edited, green added, light red removed, purple conflicted, cyan renamed.
    var tint: Color {
        switch kind {
        case .added, .untracked: Color(nsColor: Palette.graphLanes[2])
        case .modified, .typeChanged: Color(nsColor: Palette.graphLanes[1])
        case .deleted: Color(nsColor: Palette.graphLanes[7])
        case .conflicted: Color(nsColor: Palette.graphLanes[6])
        case .renamed, .copied: Color(nsColor: Palette.graphLanes[4])
        case .unchanged: .secondary
        }
    }

    var kindName: String {
        isSubmodule ? "Submodule \(kindTitle.lowercased())" : kindTitle
    }

    private var kindTitle: String {
        switch kind {
        case .added: "Added"
        case .modified: "Modified"
        case .typeChanged: "Type changed"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .copied: "Copied"
        case .untracked: "Untracked"
        case .conflicted: "Conflicted"
        case .unchanged: "Unchanged"
        }
    }

    var name: String { (path as NSString).lastPathComponent }
    var folder: String { (path as NSString).deletingLastPathComponent }
}

/// A files card's search: the files whose path holds every word of the query, in any order (case- and
/// diacritic-insensitive; spaces, "-", "_" and "/" alike, as the commit search).
enum FileSearch {
    static func filter(_ files: [FileChange], query: String) -> [FileChange] {
        let words = fold(query).split(separator: " ")
        guard !words.isEmpty else { return files }
        return files.filter { file in
            let path = fold(file.path)
            return words.allSatisfy { path.contains($0) }
        }
    }

    /// Whether `text` holds every word of `query`, the same way (the sidebar cards' search of names); true for an
    /// empty query.
    static func matches(_ text: String, query: String) -> Bool {
        let words = fold(query).split(separator: " ")
        guard !words.isEmpty else { return true }
        let text = fold(text)
        return words.allSatisfy { text.contains($0) }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacing(/[-_\/\s]+/, with: " ")
    }
}

/// The two ways a file list shows its rows.
enum FileListMode: String {
    case path, tree
}

/// A files card whose list keeps its own path / tree mode (its header's switch); Settings › Appearance sets them all.
enum FileListCard: String, CaseIterable {
    case conflicted, unstaged, staged, commit

    /// The card's mode in `Preferences.defaults`; unset, the Settings one (`PrefKey.fileListMode`).
    var key: String { "\(PrefKey.fileListMode.rawValue).\(rawValue)" }

    /// The card's mode, stored under `key`.
    var storage: AppStorage<String> {
        let mode = Preferences.defaults.string(forKey: PrefKey.fileListMode.rawValue) ?? FileListMode.tree.rawValue
        return AppStorage(wrappedValue: mode, key, store: Preferences.defaults)
    }
}

/// The path / tree switch of a files card's header; only that card's list follows it.
struct FileListModeToggle: View {
    @AppStorage private var mode: String

    init(card: FileListCard) {
        _mode = card.storage
    }

    var body: some View {
        let isTree = mode == FileListMode.tree.rawValue
        Button {
            mode = isTree ? FileListMode.path.rawValue : FileListMode.tree.rawValue
        } label: {
            Image(systemName: isTree ? "list.bullet.indent" : "list.bullet")
                .foregroundStyle(.secondary)
        }
        .buttonStyle(RowIconButtonStyle())
        .help(isTree ? "Show as Paths" : "Show as Tree")
        .accessibilityLabel(isTree ? "Show as paths" : "Show as tree")
    }
}

/// The changed-only / all-files switch of a commit's Files card (`PrefKey.commitShowsAllFiles`), in the accent color
/// while every file shows.
struct AllFilesToggle: View {
    @AppStorage(PrefKey.commitShowsAllFiles.rawValue, store: Preferences.defaults) private var showsAll = false

    var body: some View {
        Button {
            showsAll.toggle()
        } label: {
            Image(systemName: showsAll ? "folder.fill" : "folder")
                .foregroundStyle(showsAll ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
        .buttonStyle(RowIconButtonStyle())
        .help(showsAll ? "Show Changed Files Only" : "View All Files")
        .accessibilityLabel(showsAll ? "Show changed files only" : "View all files")
    }
}

/// The rows of `files`, as paths (name, then its folder dimmed) or as a tree (folders, then their files, indented).
/// `trailing` adds a row's buttons. `repoURL` is the worktree, for Reveal in Finder.
struct FileListView<Trailing: View>: View {
    let files: [FileChange]
    let repoURL: URL
    @ViewBuilder let trailing: (FileChange) -> Trailing
    /// The caller's context menu entries of a row, above Copy Path and Reveal in Finder.
    var menu: (FileChange) -> [MenuEntry] = { _ in [] }
    /// The caller's context menu of a folder row (the tree), given its path and the files under it; none when empty.
    var folderMenuEntries: (String, [FileChange]) -> [MenuEntry] = { _, _ in [] }
    /// The path of the row drawn as selected (the file whose diff is open).
    var selectedPath: String?
    /// A click on a row; nil leaves rows unclickable.
    var onSelect: ((FileChange) -> Void)?
    /// Each file's size on disk by path, shown left of its buttons; nil shows no sizes.
    var sizes: [String: Int64]?
    /// A folder row's buttons (the tree), given its path and the files under it; nil gives it none.
    var folderTrailing: ((String, [FileChange]) -> AnyView)?
    /// The card's mode (`FileListModeToggle`).
    @AppStorage private var mode: String

    init(files: [FileChange], repoURL: URL, card: FileListCard,
         @ViewBuilder trailing: @escaping (FileChange) -> Trailing)
    {
        self.files = files
        self.repoURL = repoURL
        self.trailing = trailing
        _mode = card.storage
    }

    /// A row's height at the text size: 26 unless a line of text and 5 pt above and below need more. The skeleton and
    /// empty rows share it, so a list does not jump when it loads.
    static func rowHeight(_ textSize: TextSize) -> CGFloat {
        max(26, textSize.lineHeight + 10)
    }

    /// The list with `menu`'s entries in each row's context menu.
    func fileMenu(_ menu: @escaping (FileChange) -> [MenuEntry]) -> Self {
        var list = self
        list.menu = menu
        return list
    }

    /// The list with `menu`'s entries as each folder row's context menu (the tree).
    func folderMenu(_ menu: @escaping (_ folder: String, _ files: [FileChange]) -> [MenuEntry]) -> Self {
        var list = self
        list.folderMenuEntries = menu
        return list
    }

    /// The list with clickable rows: a click calls `action` at once (the diff's placeholder shows in that frame), and
    /// the row of `selected` is drawn as selected.
    func onSelectFile(selected: String?, _ action: @escaping (FileChange) -> Void) -> Self {
        var list = self
        list.selectedPath = selected
        list.onSelect = action
        return list
    }

    /// The list with each file's size (and a folder's total in the tree) left of the buttons.
    func fileSizes(_ sizes: [String: Int64]) -> Self {
        var list = self
        list.sizes = sizes
        return list
    }

    /// The list with `buttons` at each folder row's trailing edge (the tree), like a file row's `trailing`; they act
    /// on the files under it. Give them a file row's buttons' width, so the sizes line up.
    func folderButtons<Buttons: View>(
        _ buttons: @escaping (_ folder: String, _ files: [FileChange]) -> Buttons
    ) -> Self {
        var list = self
        list.folderTrailing = { AnyView(buttons($0, $1)) }
        return list
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if mode == FileListMode.tree.rawValue {
                ForEach(FileTree.rows(for: files)) { row in
                    switch row.content {
                    case .folder(let name, let path):
                        let under = files.filter { $0.path.hasPrefix(path + "/") }
                        FolderRow(name: name, path: path, repoURL: repoURL, depth: row.depth, size: folderSize(path),
                                  trailing: folderTrailing.map { $0(path, under) }) {
                            folderMenuEntries(path, under)
                        }
                    case .file(let file):
                        FileRow(file: file, repoURL: repoURL, depth: row.depth, showsFolder: false, trailing: trailing,
                                menu: menu, isSelected: file.path == selectedPath, onSelect: onSelect,
                                size: sizes?[file.path])
                    }
                }
            } else {
                ForEach(files) { file in
                    FileRow(file: file, repoURL: repoURL, depth: 0, showsFolder: true, trailing: trailing, menu: menu,
                            isSelected: file.path == selectedPath, onSelect: onSelect, size: sizes?[file.path])
                }
            }
        }
    }

    /// The total size of the files under `folder`; nil when none has a size (all deleted) or sizes are off.
    private func folderSize(_ folder: String) -> Int64? {
        guard let sizes else { return nil }
        let prefix = folder + "/"
        let matching = sizes.filter { $0.key.hasPrefix(prefix) }
        return matching.isEmpty ? nil : matching.values.reduce(0, +)
    }
}

extension FileListView where Trailing == EmptyView {
    init(files: [FileChange], repoURL: URL, card: FileListCard) {
        self.init(files: files, repoURL: repoURL, card: card) { _ in EmptyView() }
    }
}

/// A file list's placeholder rows: an icon circle and a name capsule of the given widths.
struct SkeletonFileRows: View {
    var fractions: [CGFloat] = [0.6, 0.45, 0.7]
    @Environment(\.textSize) private var textSize

    var body: some View {
        ForEach(fractions.indices, id: \.self) { index in
            HStack(spacing: 8) {
                SkeletonLine(width: 14, height: 14)
                SkeletonLine(fraction: fractions[index], height: 11)
            }
            .padding(.horizontal, 6)
            .frame(height: FileListView<EmptyView>.rowHeight(textSize))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Rows

private struct FileRow<Trailing: View>: View {
    let file: FileChange
    let repoURL: URL
    let depth: Int
    let showsFolder: Bool
    let trailing: (FileChange) -> Trailing
    let menu: (FileChange) -> [MenuEntry]
    let isSelected: Bool
    let onSelect: ((FileChange) -> Void)?
    let size: Int64?
    @Environment(\.textSize) private var textSize
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            // A bit bigger and heavier than the text: a bare glyph needs the weight a filled square had.
            Image(systemName: file.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(file.tint)
                .frame(width: 18)
                .help(file.kindName)
                .accessibilityLabel(file.kindName)
            HStack(spacing: 4) {
                Text(file.name)
                    .lineLimit(1)
                if showsFolder, !file.folder.isEmpty {
                    Text(file.folder)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 4)
            }
            .truncationMode(.middle)
            .font(textSize.body)
            // The path's tooltip on the name part only: on the whole row it would hide the icon's and the buttons'.
            .contentShape(Rectangle())
            .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
            if let size {
                FileSizeText(size: size, warnsWhenLarge: true)
                    .padding(.trailing, 4)
            }
            trailing(file)
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 6)
        .frame(height: FileListView<EmptyView>.rowHeight(textSize))
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? Palette.selectedFill : hovered ? Palette.hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // A single tap only (no double-tap on the row), so the click acts at mouse-up without a wait; the row's
        // buttons keep their own clicks.
        .onTapGesture { onSelect?(file) }
        .accessibilityAddTraits(onSelect == nil ? [] : .isButton)
        .contextMenu {
            let entries = menu(file)
            if !entries.isEmpty {
                MenuEntriesView(entries: entries)
                Divider()
            }
            Button("Copy Path") { Self.copy(file.path) }
            Button("Reveal in Finder") { revealInFinder(file.path, in: repoURL) }
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The root-relative `path` (a file or a folder) in Finder; its nearest existing folder when it is gone (deleted).
private func revealInFinder(_ path: String, in repoURL: URL) {
    var url = repoURL.appending(path: path)
    while !FileManager.default.fileExists(atPath: url.path), url.path.count > repoURL.path.count {
        url = url.deletingLastPathComponent()
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
}

private struct FolderRow: View {
    let name: String
    /// Root-relative.
    let path: String
    let repoURL: URL
    let depth: Int
    let size: Int64?
    /// The caller's buttons, laid out as a file row's, so the sizes and buttons line up.
    let trailing: AnyView?
    /// The caller's context menu entries, above Reveal in Finder.
    let menu: () -> [MenuEntry]
    @Environment(\.textSize) private var textSize

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.secondary)
                Text(name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(textSize.body)
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if let size {
                FileSizeText(size: size)
                    .padding(.trailing, 4)
            }
            trailing
        }
        .padding(.leading, 6 + CGFloat(depth) * 14)
        .padding(.trailing, 6)
        .frame(height: FileListView<EmptyView>.rowHeight(textSize))
        .contentShape(Rectangle())
        .contextMenu {
            let entries = menu()
            if !entries.isEmpty {
                MenuEntriesView(entries: entries)
                Divider()
            }
            Button("Reveal in Finder") { revealInFinder(path, in: repoURL) }
        }
    }
}

/// A file's or a folder's size in a row ("12 KB"), dimmed, digits of the same width. A heavy file's is yellow from
/// 1 MB and red from 10 MB (`warnsWhenLarge`; a folder's total stays dimmed).
private struct FileSizeText: View {
    let size: Int64
    var warnsWhenLarge = false
    @Environment(\.textSize) private var textSize

    var body: some View {
        Text(size.formatted(.byteCount(style: .file, spellsOutZero: false)))
            .font(textSize.caption)
            .monospacedDigit()
            .foregroundStyle(style)
            .lineLimit(1)
            .fixedSize()
    }

    private var style: AnyShapeStyle {
        guard warnsWhenLarge else { return AnyShapeStyle(.secondary) }
        switch size {
        case 10_000_000...: return AnyShapeStyle(Color(nsColor: Palette.graphLanes[7]))
        case 1_000_000...: return AnyShapeStyle(Color(nsColor: Palette.graphLanes[5]))
        default: return AnyShapeStyle(.secondary)
        }
    }
}

// MARK: - Tree

/// The tree view's rows: each folder once (a chain of single-child folders joined as `a/b/c`), then its files, sorted
/// folders first and by name.
private enum FileTree {
    struct Row: Identifiable {
        enum Content {
            /// Its label (single-child folders joined) and its root-relative path.
            case folder(name: String, path: String)
            case file(FileChange)
        }

        let id: String
        let depth: Int
        let content: Content
    }

    private final class Node {
        var folders: [String: Node] = [:]
        var files: [FileChange] = []
    }

    static func rows(for files: [FileChange]) -> [Row] {
        let root = Node()
        for file in files {
            var node = root
            for part in file.folder.split(separator: "/") {
                let key = String(part)
                if let next = node.folders[key] {
                    node = next
                } else {
                    let next = Node()
                    node.folders[key] = next
                    node = next
                }
            }
            node.files.append(file)
        }
        var rows: [Row] = []
        append(root, path: "", depth: 0, to: &rows)
        return rows
    }

    private static func append(_ node: Node, path: String, depth: Int, to rows: inout [Row]) {
        for name in node.folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            var child = node.folders[name]!
            var label = name
            while child.files.isEmpty, child.folders.count == 1, let (next, grandchild) = child.folders.first {
                label += "/" + next
                child = grandchild
            }
            let folderPath = path.isEmpty ? label : path + "/" + label
            rows.append(Row(id: "dir:" + folderPath, depth: depth, content: .folder(name: label, path: folderPath)))
            append(child, path: folderPath, depth: depth + 1, to: &rows)
        }
        let files = node.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        for file in files {
            rows.append(Row(id: file.path, depth: depth, content: .file(file)))
        }
    }
}
