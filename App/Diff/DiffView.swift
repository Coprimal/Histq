// A file's diff in panel2, in place of the graph (Esc or close returns to it), each part in its own card: one card per
// side of the change (a WIP file's Unstaged and Staged changes, a commit's changes), or a card that says why there are
// no lines (binary, too large, no change). The first card's header is the file's row (its status, folder / name, the
// tools, +N −M, Diff / Full file, close). An image whose diff is binary shows its versions before and after the change
// instead of lines. The diff loads off the main actor; until then the card's body is a skeleton.
import HistqCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A file whose diff panel2 shows: a WIP file (its unstaged and staged changes), a file of a commit or a stash, or a
/// file of a compare.
struct FileTarget: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case wip
        /// A commit or a stash, by its hash.
        case commit(String)
        /// A file of a compare, read-only: `base` against `head` (nil for the working tree).
        case compare(base: String, head: String?)
    }

    let source: Source
    let file: FileChange

    var path: String { file.path }

    /// A raster image by its extension (SVG is text: it keeps its line diff). Its binary diff shows as images.
    var isImage: Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }
}

/// An image decoded off the main actor, with the size of its file.
struct DiffImage: @unchecked Sendable {
    /// Immutable, so safe to share across actors. At most `maxDecodedSide` pixels on its long side.
    let image: CGImage
    /// The image's own size in pixels, upright (what the label shows and the most a pane draws it at).
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int

    /// The longest side decoded: a small file can declare a huge image (a decompression bomb), and no pane is wider.
    private static let maxDecodedSide = 4096
    /// The formats decoded (sniffed from the bytes, not the extension): common web and photo formats only, so a
    /// repo's file never reaches ImageIO's rarer parsers.
    private static let decodedTypes: [UTType] = [.png, .jpeg, .gif, .webP, .bmp, .tiff, .heic, .heif, .ico]

    /// Turned upright by its EXIF orientation (a phone photo). Nil for no data, another format, or data ImageIO cannot
    /// decode.
    nonisolated init?(data: Data?) {
        guard let data, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }),
              Self.decodedTypes.contains(where: { type.conforms(to: $0) }),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), Self.maxDecodedSide),
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary)
        else { return nil }
        self.image = image
        // The decoded image is upright: scale its sides back to the file's size (a rotated photo swaps them).
        let factor = Double(max(width, height)) / Double(max(image.width, image.height))
        pixelWidth = Int((Double(image.width) * factor).rounded())
        pixelHeight = Int((Double(image.height) * factor).rounded())
        byteCount = data.count
    }
}

/// One card of an image's diff: the image before and after the change on one side (nil where that side has no file,
/// such as an added or deleted image, or where it does not decode).
struct ImageDiffSide: Sendable, Identifiable {
    let side: DiffSide
    let before: DiffImage?
    let after: DiffImage?

    var id: DiffSide { side }
}

/// Hunks with git's context, or the whole file with its changes marked.
enum DiffMode: String, Hashable, Sendable, CaseIterable {
    case diff, full

    var title: String {
        switch self {
        case .diff: "Diff"
        case .full: "Full file"
        }
    }
}

/// A loaded file diff. `loadID` changes with every load, so the tables know a reload (after a stage) from a redraw.
struct FileDiffDetail: Sendable {
    enum Content: Sendable {
        /// One card per side with changes.
        case sections([DiffSection])
        /// An image's versions, one card per side with changes.
        case images([ImageDiffSide])
        case binary
        /// Over `RepoSession.fileSizeLimit`: the largest side's size in bytes.
        case tooLarge(Int)
        /// git printed no diff for the file (it has no change left).
        case unchanged
    }

    let loadID: Int
    let content: Content

    init(loadID: Int, content: Content) {
        self.loadID = loadID
        self.content = content
    }

    /// The sections with changes; a binary side makes the whole file binary.
    init(loadID: Int, sections: [DiffSection]) {
        self.loadID = loadID
        content = sections.isEmpty ? .unchanged : sections.contains(where: \.isBinary) ? .binary : .sections(sections)
    }

    var additions: Int? {
        if case .sections(let sections) = content { sections.reduce(0) { $0 + $1.additions } } else { nil }
    }

    var deletions: Int? {
        if case .sections(let sections) = content { sections.reduce(0) { $0 + $1.deletions } } else { nil }
    }
}

/// Panel2 while a file is open: the diff's cards (skeletons until loaded). The first card's header is the file's own row
/// (`DiffFileHeader`), there at once, so its actions work while the diff loads.
struct DiffView: View {
    let session: RepoSession
    let target: FileTarget
    @Environment(WindowModel.self) private var model

    var body: some View {
        Group {
            switch session.fileDiff {
            case .idle, .loading:
                DiffCard(header: DiffFileHeader(session: session, target: target, counts: .loading),
                         contentPadding: target.isImage ? SettingsMetrics.cardPadding : 0) {
                    PlaceholderCard(
                        token: session.fileToken, detail: session.fileDetail,
                        isCurrent: { [model, session] in model.selectedSession === session && session.openFile != nil }
                    ) {
                        if target.isImage { ImageDiffPlaceholder() } else { DiffPlaceholder() }
                    }
                }
            case .loaded(let detail):
                DiffContent(session: session, target: target, detail: detail)
                    .onAppear { UITiming.content(session.fileDetail) }
            case .failed(let message):
                DiffCard(header: DiffFileHeader(session: session, target: target, counts: .none),
                         contentPadding: SettingsMetrics.cardPadding) {
                    FileNotice(systemImage: "exclamationmark.triangle", message: message)
                }
                .onAppear { UITiming.content("\(session.fileDetail) failed") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A card of the open file. The first one's header is the file's row (`DiffFileHeader`), at a titled `SectionCard`
/// header's insets and a little taller (`DiffFileHeader.height`), so the mode switch clears its edges; a later one (`header` nil) has its side's title and `accessory` instead. The body keeps
/// one place in the view tree either way, so a side that becomes the first card or stops being it (a quiet reload after
/// a stage or an unstage) keeps its line table and the table's scroll offset.
private struct DiffCard<Content: View, Accessory: View>: View {
    let header: DiffFileHeader?
    /// The card's title and icon when it has no `header`.
    let title: String?
    let systemImage: String?
    /// Around the body, below the header (0 for the line tables, which run to the card's edges).
    let contentPadding: CGFloat
    @ViewBuilder let content: () -> Content
    @ViewBuilder let accessory: () -> Accessory
    @Environment(\.cardExtraPadding) private var extraPadding
    @Environment(\.cardExtraVerticalPadding) private var extraVerticalPadding

    init(header: DiffFileHeader?, title: String? = nil, systemImage: String? = nil, contentPadding: CGFloat = 0,
         @ViewBuilder content: @escaping () -> Content, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.header = header
        self.title = title
        self.systemImage = systemImage
        self.contentPadding = contentPadding
        self.content = content
        self.accessory = accessory
    }

    var body: some View {
        SectionCard(header == nil ? title : nil, systemImage: systemImage, contentPadding: 0) {
            if let header {
                header
            }
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, contentPadding == 0 ? 0 : contentPadding + extraPadding)
            .padding(.bottom, contentPadding == 0 ? 0 : contentPadding + extraVerticalPadding)
        } accessory: {
            accessory()
        }
    }
}

extension DiffCard where Accessory == EmptyView {
    init(header: DiffFileHeader?, title: String? = nil, systemImage: String? = nil, contentPadding: CGFloat = 0,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(header: header, title: title, systemImage: systemImage, contentPadding: contentPadding,
                  content: content, accessory: { EmptyView() })
    }
}

/// The open file's row, the header of its first card: the status icon, "folder / name" (and the card's side, such as
/// Unstaged, when a second card follows), Checkout This Version (a commit's file), File History and Blame (a tracked
/// file), the card's line counts, the mode switch and close (Esc). As the row narrows, the folder truncates (the
/// tooltip has the full path), Checkout This Version turns into an icon, then the actions fold into a "…" menu.
private struct DiffFileHeader: View {
    enum Counts {
        /// A skeleton until the diff is in.
        case loading
        case none
        case lines(additions: Int, deletions: Int)
    }

    let session: RepoSession
    let target: FileTarget
    /// The card's side, shown when the file has more than one card.
    var side: String?
    let counts: Counts
    @AppStorage(PrefKey.layoutPreset.rawValue, store: Preferences.defaults) private var storedPreset = "classic"
    @Environment(\.cardExtraPadding) private var extraPadding
    @Environment(\.cardExtraVerticalPadding) private var extraVerticalPadding

    /// The folder's width when the row decides whether the actions fit: the folder truncates first, down to this.
    private static let folderFitWidth: CGFloat = 60
    /// The narrowest truncated folder; narrower, it hides.
    private static let folderMinWidth: CGFloat = 40
    /// Between the buttons, the counts and the mode switch: wider than the title's gaps, so the icons don't crowd.
    private static let controlSpacing: CGFloat = 12
    /// Taller than a `SectionCard` header (32), so the small mode switch (30) has room above and below it.
    static let height: CGFloat = 40

    var body: some View {
        @Bindable var session = session
        let detail = session.fileDiff.value
        HStack(spacing: Self.controlSpacing) {
            ViewThatFits(in: .horizontal) {
                row { actions(checkoutAsIcon: false) }
                row { actions(checkoutAsIcon: true) }
                row { actionsMenu }
            }
            countsView
                .fixedSize()
            // An image's versions have no modes; an image type git diffs as text (XBM, EPS) keeps them.
            if !target.isImage || detail.map({ if case .sections = $0.content { true } else { false } }) == true {
                CapsuleTabs(selection: $session.diffMode, tabs: DiffMode.allCases, title: { Text($0.title) },
                            compact: true, small: true)
                    .fixedSize()
            }
            Button {
                session.closeFile()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(RowIconButtonStyle())
            .keyboardShortcut(.cancelAction)
            .help(closesPane ? "Close the diff (Esc)" : "Back to the \(backName) (Esc)")
            .accessibilityLabel(closesPane ? "Close the diff" : "Back to the \(backName.lowercased())")
        }
        .padding(.horizontal, SettingsMetrics.cardPadding + extraPadding)
        .frame(height: Self.height)
        .padding(.top, extraVerticalPadding * 2 / 3)
    }

    private func row(@ViewBuilder _ actions: () -> some View) -> some View {
        HStack(spacing: 8) {
            title
            Spacer(minLength: 8)
            HStack(spacing: Self.controlSpacing) {
                actions()
            }
        }
    }

    private func folderText(_ folder: String) -> some View {
        Text("\(folder) /")
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    /// The status icon, "folder / name" in one font (the folder secondary, truncating from its head) and the side.
    private var title: some View {
        let file = target.file
        return HStack(spacing: 8) {
            Image(systemName: file.systemImage)
                .foregroundStyle(file.tint)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                if !file.folder.isEmpty {
                    // Whole, else truncated from its head while that still shows a few letters, else hidden: the
                    // name keeps its width.
                    ViewThatFits(in: .horizontal) {
                        folderText(file.folder)
                        folderText(file.folder)
                            .truncationMode(.head)
                            .frame(minWidth: Self.folderMinWidth, idealWidth: Self.folderMinWidth, alignment: .leading)
                        Color.clear
                            .frame(width: 0)
                    }
                    .frame(idealWidth: Self.folderFitWidth, alignment: .leading)
                }
                Text(file.name)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
            .accessibilityElement(children: .ignore)
            // The status icon is hidden from VoiceOver and the status is not shown as text: the label says both.
            .accessibilityLabel(file.originalPath.map { "\(file.kindName): \($0) → \(file.path)" }
                                ?? "\(file.kindName): \(file.path)")
            .layoutPriority(1)
            if let side {
                Text(side)
                    .font(.settingsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// Checkout This Version (a commit's file), as a button or an icon, then File History and Blame (a tracked file; no
    /// Blame for an image).
    @ViewBuilder private func actions(checkoutAsIcon: Bool) -> some View {
        let file = target.file
        if case .commit = target.source, file.kind != .deleted {
            if checkoutAsIcon {
                toolButton("arrow.down.doc", help: "Checkout This Version") { session.checkoutVersion(of: target) }
            } else {
                Button("Checkout This Version") { session.checkoutVersion(of: target) }
                    .buttonStyle(RowTextButtonStyle())
                    .lineLimit(1)
                    .fixedSize()
                    .help("Replace the file in the working tree with this commit's version")
            }
        }
        if file.kind != .untracked {
            toolButton("clock.arrow.circlepath", help: "File History") {
                session.selectTool(.fileHistory(path: file.path, rev: rev, follow: false))
            }
            if file.kind != .deleted, !target.isImage {
                toolButton("person.text.rectangle", help: "Blame") {
                    session.selectTool(.blame(path: file.path, rev: rev))
                }
            }
        }
    }

    /// The same actions in a "…" menu, for a narrow row.
    @ViewBuilder private var actionsMenu: some View {
        let file = target.file
        let checkout: [MenuEntry] = if case .commit = target.source, file.kind != .deleted {
            [.action("Checkout This Version") { [session, target] in session.checkoutVersion(of: target) }]
        } else {
            []
        }
        let tools = file.kind == .untracked ? []
            : RepoMenus.fileTools(path: file.path, rev: rev, blame: file.kind != .deleted && !target.isImage,
                                  session: session)
        let entries = checkout + tools
        if !entries.isEmpty {
            Menu {
                MenuEntriesView(entries: entries)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 22)
            }
            .menuStyle(.button)
            .buttonStyle(RowIconButtonStyle())
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More Actions")
            .accessibilityLabel("More file actions")
        }
    }

    /// An icon button opening a tool (File History, Blame), the close button's look.
    private func toolButton(_ icon: String, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            IconImage(icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(RowIconButtonStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    /// The commit of a commit's or stash's file, a compare's head; nil for a WIP file or a compare with the working
    /// tree (HEAD's history, the working tree's blame).
    private var rev: String? {
        switch target.source {
        case .wip: nil
        case .commit(let hash): hash
        case .compare(_, let head): head
        }
    }

    /// Stacked, not opened from a tool: close (and Esc) hides the bottom pane under the graph, which stays in view.
    private var closesPane: Bool {
        session.returnTool == nil && LayoutPreset.resolved(storedPreset) == .stacked
    }

    /// Where close (and Esc) returns: the tool the diff was opened from, else the graph.
    private var backName: String {
        switch session.returnTool {
        case .fileHistory?: "History"
        case .blame?: "Blame"
        case .reflog?: "Reflog"
        case nil: "Graph"
        }
    }

    @ViewBuilder private var countsView: some View {
        switch counts {
        case .loading:
            SkeletonLine(width: 56, height: 11)
        case .none:
            EmptyView()
        case .lines(let additions, let deletions):
            HStack(spacing: 6) {
                Text("+\(additions)")
                    .foregroundStyle(Color(nsColor: Palette.diffAddedSign))
                Text("−\(deletions)")
                    .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
            }
            .font(.callout.monospacedDigit().weight(.medium))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(additions) added, \(deletions) removed")
        }
    }
}

/// The loaded diff: a card per side (filling the panel together; the first one's header is the file's row), or a card
/// that says why there are no lines.
private struct DiffContent: View {
    let session: RepoSession
    let target: FileTarget
    let detail: FileDiffDetail

    var body: some View {
        switch detail.content {
        case .sections(let sections):
            // The cards with lines fill panel2 and share its height equally (each table scrolls); a side without
            // lines fits its text.
            VStack(spacing: SectionCardMetrics.spacing) {
                ForEach(sections) { section in
                    sectionCard(section, in: sections)
                }
                if sections.allSatisfy({ $0.rows(session.diffMode).isEmpty }) {
                    Spacer(minLength: 0)
                }
            }
        case .images(let sides):
            VStack(spacing: SectionCardMetrics.spacing) {
                ForEach(sides) { side in
                    ImageDiffCard(side: side, header: side.id == sides.first?.id
                        ? header(side: sides.count > 1 ? side.side.title : nil, counts: .none) : nil)
                }
            }
        case .binary:
            noticeCard(FileNotice(systemImage: "doc.zipper",
                                  message: "Histq does not show the contents of binary files."))
        case .tooLarge(let bytes):
            noticeCard(FileNotice(
                systemImage: "doc.badge.clock",
                message: "This file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
                    + "over the \(ByteCountFormatter.string(fromByteCount: Int64(RepoSession.fileSizeLimit), countStyle: .file)) "
                    + "Histq shows at once."
            ) {
                Button("Load Anyway") { session.loadFileAnyway() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            })
        case .unchanged:
            noticeCard(FileNotice(systemImage: "checkmark.circle", message: "This file has no changes to show."))
        }
    }

    private func header(side: String?, counts: DiffFileHeader.Counts) -> DiffFileHeader {
        DiffFileHeader(session: session, target: target, side: side, counts: counts)
    }

    private func noticeCard(_ notice: some View) -> some View {
        DiffCard(header: header(side: nil, counts: .none), contentPadding: SettingsMetrics.cardPadding) { notice }
    }

    /// The first side's card has the file's row as its header (naming the side when another card follows); the others
    /// keep their side's title, with the line counts as their accessory. One `DiffCard` for both, so the body keeps its
    /// table when the side moves to or from the first place.
    private func sectionCard(_ section: DiffSection, in sections: [DiffSection]) -> some View {
        let isFirst = section.id == sections.first?.id
        return DiffCard(
            header: isFirst ? header(side: sections.count > 1 ? section.side.title : nil,
                                     counts: .lines(additions: section.additions, deletions: section.deletions)) : nil,
            title: section.side.title, systemImage: section.side.systemImage
        ) {
            sectionBody(section)
        } accessory: {
            HStack(spacing: 6) {
                Text("+\(section.additions)")
                    .foregroundStyle(Color(nsColor: Palette.diffAddedSign))
                Text("−\(section.deletions)")
                    .foregroundStyle(Color(nsColor: Palette.diffRemovedSign))
            }
            .font(.settingsCaption.monospacedDigit())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(section.additions) added, \(section.deletions) removed")
        }
    }

    @ViewBuilder private func sectionBody(_ section: DiffSection) -> some View {
        let rows = section.rows(session.diffMode)
        if rows.isEmpty {
            Text(modeOnlyText(section))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
        } else {
            DiffLineTable(
                section: section, mode: session.diffMode, loadID: detail.loadID,
                onApply: { [session] action, lines, file in session.apply(action, lines: lines, of: file) },
                onClose: { [session] in session.closeFile() })
                .frame(maxHeight: .infinity)
        }
    }

    /// A side without lines: a mode change, or an empty file added or deleted.
    private func modeOnlyText(_ section: DiffSection) -> String {
        if let diff = section.diff, diff.isModeChange, let old = diff.oldMode, let new = diff.newMode {
            return "Mode changed from \(old) to \(new)."
        }
        return section.side == .file ? "Empty file." : "No line changes."
    }
}

/// One side of an image's diff: Before and After next to each other, or one above the other when that shows them
/// larger (a narrow, tall panel2), one pane when the file exists on one side only. Each image is scaled down to fit,
/// never up, over a checkerboard that shows transparency.
private struct ImageDiffCard: View {
    let side: ImageDiffSide
    /// The file's row, on the first side's card, in place of the side's title.
    let header: DiffFileHeader?

    private static let spacing: CGFloat = 12
    /// A pane's label row and the gap under it.
    private static let labelHeight: CGFloat = 24

    var body: some View {
        DiffCard(header: header, title: side.side.title, systemImage: side.side.systemImage,
                 contentPadding: SettingsMetrics.cardPadding) { panes }
    }

    private var panes: some View {
        GeometryReader { proxy in
            let layout = Self.stacks(side, in: proxy.size)
                ? AnyLayout(VStackLayout(spacing: Self.spacing))
                : AnyLayout(HStackLayout(alignment: .top, spacing: Self.spacing))
            layout {
                if let before = side.before {
                    ImagePane(title: "Before", tint: Color(nsColor: Palette.diffRemovedSign), image: before)
                }
                if let after = side.after {
                    ImagePane(title: side.side == .file ? "This version" : "After",
                              tint: side.side == .file ? nil : Color(nsColor: Palette.diffAddedSign), image: after)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// Whether Before and After show larger one above the other than side by side in `size`: the smaller of their two
    /// scales decides. A single image never stacks.
    private static func stacks(_ side: ImageDiffSide, in size: CGSize) -> Bool {
        guard let before = side.before, let after = side.after else { return false }
        func scale(_ width: CGFloat, _ height: CGFloat) -> CGFloat {
            [before, after].map { image in
                min(1, max(0, width) / CGFloat(image.pixelWidth), max(0, height - labelHeight) / CGFloat(image.pixelHeight))
            }.min() ?? 0
        }
        let sideBySide = scale((size.width - spacing) / 2, size.height)
        let stacked = scale(size.width, (size.height - spacing) / 2)
        return stacked > sideBySide
    }
}

/// A label (Before or After, the pixel size and the file size) centered above the image.
private struct ImagePane: View {
    let title: String
    let tint: Color?
    let image: DiffImage

    var body: some View {
        let width = image.pixelWidth
        let height = image.pixelHeight
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.settingsCaption.weight(.semibold))
                    .foregroundStyle(tint ?? .secondary)
                Text("\(width) × \(height) · "
                     + ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .file))
                    .font(.settingsCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            // One image pixel per point, as a browser shows it; smaller when the pane is.
            Image(decorative: image.image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .background(Checkerboard())
                .overlay { Rectangle().strokeBorder((tint ?? Color.secondary).opacity(0.6), lineWidth: 1) }
                .frame(maxWidth: CGFloat(width), maxHeight: CGFloat(height), alignment: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(width) by \(height) pixels")
    }
}

/// Grey squares behind an image, so its transparent parts show.
private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.4)))
            var squares = Path()
            for row in 0 ..< Int((size.height / cell).rounded(.up)) {
                for column in stride(from: row % 2, to: Int((size.width / cell).rounded(.up)), by: 2) {
                    squares.addRect(CGRect(x: CGFloat(column) * cell, y: CGFloat(row) * cell, width: cell, height: cell))
                }
            }
            context.fill(squares, with: .color(Color(white: 0.55)))
        }
    }
}

/// A card with a message instead of lines (binary, too large, no change, a failed read), and an optional action. The
/// PR detail's Files changed tab uses it too.
struct DiffNoticeCard<Action: View>: View {
    let title: String
    let systemImage: String
    let message: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        SectionCard(title, systemImage: systemImage) {
            VStack(alignment: .leading, spacing: 10) {
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                action()
            }
            // Fills panel2 like the line cards, no empty space below.
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// The body of the open file's card when it has no lines (binary, too large, no change, a failed read): the reason's
/// icon and message, and an optional action.
private struct FileNotice<Action: View>: View {
    let systemImage: String
    let message: String
    @ViewBuilder let action: () -> Action

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                IconImage(systemImage)
            }
            .foregroundStyle(.secondary)
            action()
        }
        // Fills panel2 like the line cards, no empty space below.
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

extension FileNotice where Action == EmptyView {
    init(systemImage: String, message: String) {
        self.init(systemImage: systemImage, message: message) { EmptyView() }
    }
}

extension DiffNoticeCard where Action == EmptyView {
    init(title: String, systemImage: String, message: String) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// The diff's skeleton, under the file's row: a hunk header bar and line rows (number gutters and text capsules).
private struct DiffPlaceholder: View {
    private static let widths: [CGFloat] = [0.55, 0.7, 0.4, 0.62, 0.5, 0.75, 0.35, 0.6, 0.45, 0.66, 0.52, 0.3]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SkeletonLine(fraction: 0.35, height: 10)
                SkeletonLine(width: 72, height: 18)
            }
            .padding(.horizontal, 10)
            .frame(height: DiffLayout.hunkHeight)
            ForEach(Self.widths.indices, id: \.self) { index in
                HStack(spacing: 10) {
                    SkeletonLine(width: 20, height: 9)
                    SkeletonLine(width: 20, height: 9)
                    SkeletonLine(fraction: Self.widths[index], height: 10)
                }
                .padding(.horizontal, 10)
                .frame(height: DiffLayout.lineHeight)
            }
        }
        .padding(.bottom, 8)
        // The loaded cards fill panel2: so does their skeleton.
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// An image diff's skeleton, under the file's row: two image boxes side by side.
private struct ImageDiffPlaceholder: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(0 ..< 2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonLine(width: 120, height: 10)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Palette.skeletonFill)
                        .frame(maxWidth: .infinity, maxHeight: 240)
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}
