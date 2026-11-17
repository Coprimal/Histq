// A file's diff in panel2, in place of the graph (Esc or the back button returns to it), each part in its own card:
// the header (back, the file, its status, +N −M, Diff / Full file, close), then one card per side of the change (a WIP file's
// Unstaged and Staged changes, a commit's changes), or a card that says why there are no lines (binary, too large, no
// change). An image whose diff is binary shows its versions before and after the change instead of lines. The diff
// loads off the main actor; until then the cards are skeletons.
import HistqCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// A file whose diff panel2 shows: a WIP file (its unstaged and staged changes) or a file of a commit or a stash.
struct FileTarget: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case wip
        /// A commit or a stash, by its hash.
        case commit(String)
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

/// Panel2 while a file is open: the header card at once, then the diff's cards (skeletons until loaded).
struct DiffView: View {
    let session: RepoSession
    let target: FileTarget
    @Environment(WindowModel.self) private var model

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            DiffHeaderCard(session: session, target: target)
            Group {
                switch session.fileDiff {
                case .idle, .loading:
                    PlaceholderCard(
                        token: session.fileToken, detail: session.fileDetail,
                        isCurrent: { [model, session] in model.selectedSession === session && session.openFile != nil }
                    ) {
                        if target.isImage { ImageDiffPlaceholder() } else { DiffPlaceholder() }
                    }
                case .loaded(let detail):
                    DiffContent(session: session, detail: detail)
                        .onAppear { UITiming.content(session.fileDetail) }
                case .failed(let message):
                    DiffNoticeCard(title: "Diff", systemImage: "exclamationmark.triangle", message: message)
                        .onAppear { UITiming.content("\(session.fileDetail) failed") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

/// Back, the file's icon, name and folder, its status, File History and Blame icons (a tracked file), the line counts,
/// the mode switch and close; a commit's file adds "Checkout This Version". The actions fold into a "…" menu when the
/// row is narrow. The counts are skeletons until the diff is in.
private struct DiffHeaderCard: View {
    let session: RepoSession
    let target: FileTarget

    var body: some View {
        @Bindable var session = session
        let detail = session.fileDiff.value
        SectionCard(nil, contentPadding: 8) {
            HStack(spacing: 8) {
                Button {
                    session.closeFile()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(RowIconButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help("Back to the \(backName) (Esc)")
                .accessibilityLabel("Back to the \(backName.lowercased())")
                .padding(.leading, 4)
                // The name first: the secondary actions fold into a "…" menu when the row is too narrow for them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        title
                        Spacer(minLength: 8)
                        actions
                    }
                    HStack(spacing: 8) {
                        title
                        Spacer(minLength: 8)
                        actionsMenu
                    }
                }
                counts(detail)
                    .fixedSize()
                // An image's versions have no modes; an image type git diffs as text (XBM, EPS) keeps them.
                if !target.isImage || detail.map({ if case .sections = $0.content { true } else { false } }) == true {
                    CapsuleTabs(selection: $session.diffMode, tabs: DiffMode.allCases, title: { Text($0.title) },
                                compact: true)
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
                .help("Close (back to the \(backName))")
                .accessibilityLabel("Close the diff")
                .padding(.trailing, 4)
            }
            // As tall as the compact tabs' padded track (24 pt pills inset 4 pt), the sidebar's look.
            .frame(height: 32)
        }
    }

    /// The file's icon, name and folder, and its status; the name keeps its width before the folder and the status.
    private var title: some View {
        let file = target.file
        return HStack(spacing: 8) {
            Image(systemName: file.systemImage)
                .foregroundStyle(file.tint)
                .accessibilityHidden(true)
            HStack(spacing: 4) {
                Text(file.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                if !file.folder.isEmpty {
                    Text(file.folder)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .help(file.originalPath.map { "\($0) → \(file.path)" } ?? file.path)
            .layoutPriority(1)
            Text(file.kindName)
                .font(.settingsCaption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// "Checkout This Version" (a commit's file), then File History and Blame (a tracked file; no Blame for an image).
    @ViewBuilder private var actions: some View {
        let file = target.file
        if case .commit = target.source, file.kind != .deleted {
            Button("Checkout This Version") { session.checkoutVersion(of: target) }
                .buttonStyle(RowTextButtonStyle())
                .lineLimit(1)
                .fixedSize()
                .help("Replace the file in the working tree with this commit's version")
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

    /// An icon button opening a tool (File History, Blame), the back button's look.
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

    /// The commit of a commit's or stash's file; nil for a WIP file (HEAD's history, the working tree's blame).
    private var rev: String? {
        if case .commit(let hash) = target.source { hash } else { nil }
    }

    /// Where Back and close return: the tool the diff was opened from, else the graph.
    private var backName: String {
        switch session.returnTool {
        case .fileHistory?: "History"
        case .blame?: "Blame"
        case nil: "Graph"
        }
    }

    @ViewBuilder private func counts(_ detail: FileDiffDetail?) -> some View {
        if let detail {
            if let additions = detail.additions, let deletions = detail.deletions {
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
        } else {
            SkeletonLine(width: 56, height: 11)
        }
    }
}

/// The loaded diff: a card per side (filling the panel together), or a card that says why there are no lines.
private struct DiffContent: View {
    let session: RepoSession
    let detail: FileDiffDetail

    var body: some View {
        switch detail.content {
        case .sections(let sections):
            // The cards with lines fill panel2 and share its height equally (each table scrolls); a side without
            // lines fits its text.
            VStack(spacing: SectionCardMetrics.spacing) {
                ForEach(sections) { section in
                    sectionCard(section)
                }
                if sections.allSatisfy({ $0.rows(session.diffMode).isEmpty }) {
                    Spacer(minLength: 0)
                }
            }
        case .images(let sides):
            VStack(spacing: SectionCardMetrics.spacing) {
                ForEach(sides) { side in
                    ImageDiffCard(side: side)
                }
            }
        case .binary:
            DiffNoticeCard(title: "Binary file", systemImage: "doc.zipper",
                           message: "Histq does not show the contents of binary files.")
        case .tooLarge(let bytes):
            DiffNoticeCard(
                title: "Large file", systemImage: "doc.badge.clock",
                message: "This file is \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)), "
                    + "over the \(ByteCountFormatter.string(fromByteCount: Int64(RepoSession.fileSizeLimit), countStyle: .file)) "
                    + "Histq shows at once."
            ) {
                Button("Load Anyway") { session.loadFileAnyway() }
                    .buttonStyle(RowTextButtonStyle(formRow: true))
            }
        case .unchanged:
            DiffNoticeCard(title: "No changes", systemImage: "checkmark.circle",
                           message: "This file has no changes to show.")
        }
    }

    private func sectionCard(_ section: DiffSection) -> some View {
        let rows = section.rows(session.diffMode)
        return SectionCard(section.side.title, systemImage: section.side.systemImage, contentPadding: 0) {
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

    private static let spacing: CGFloat = 12
    /// A pane's label row and the gap under it.
    private static let labelHeight: CGFloat = 24

    var body: some View {
        SectionCard(side.side.title, systemImage: side.side.systemImage) {
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

extension DiffNoticeCard where Action == EmptyView {
    init(title: String, systemImage: String, message: String) {
        self.init(title: title, systemImage: systemImage, message: message) { EmptyView() }
    }
}

/// The diff's skeleton: one card with a hunk header bar and line rows (number gutters and text capsules).
private struct DiffPlaceholder: View {
    private static let widths: [CGFloat] = [0.55, 0.7, 0.4, 0.62, 0.5, 0.75, 0.35, 0.6, 0.45, 0.66, 0.52, 0.3]

    var body: some View {
        VStack(spacing: SectionCardMetrics.spacing) {
            SectionCard("Changes", systemImage: "doc.text", countIsLoading: true, contentPadding: 0) {
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
    }
}

/// An image diff's skeleton: one card with two image boxes side by side.
private struct ImageDiffPlaceholder: View {
    var body: some View {
        SectionCard("Changes", systemImage: "photo", countIsLoading: true) {
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
}
