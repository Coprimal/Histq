// The uploaded images to pick a tab icon from (`CustomIconImages`): an Upload… button, then the stored images newest
// first, the selected one ringed in blue. A click selects at once; each image has a small delete button. The list and
// every thumbnail load off the main thread and reload on `CustomIconImages.didChange` (an upload drops the cached
// image of its reference, so a thumbnail loads it again).
import AppKit
import HistqCore
import SwiftUI
import UniformTypeIdentifiers

struct IconLibraryPicker: View {
    /// The chosen image reference; nil for none.
    @Binding var selection: String?
    /// For the toast of a refused image.
    let model: WindowModel
    /// The stored references, newest first; empty until listed.
    @State private var refs: [String] = []
    /// Bumped on `CustomIconImages.didChange`: lists the images again and redraws the thumbnails.
    @State private var version = 0
    /// The open panel or an upload is running.
    @State private var uploading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button("Upload…", action: upload)
                .buttonStyle(RowTextButtonStyle(formRow: true))
                .disabled(uploading)
                .help("Add a PNG, JPEG or WebP image of up to \(CustomIcon.maxBytes / 1024) KB, "
                    + "\(CustomIcon.sides.lowerBound)–\(CustomIcon.sides.upperBound) px a side")
            if !refs.isEmpty {
                HStack(spacing: 8) {
                    Text("Uploaded")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(refs, id: \.self) { ref in
                                Thumbnail(ref: ref, version: version, selected: ref == selection) {
                                    selection = ref
                                } onDelete: {
                                    delete(ref)
                                }
                            }
                        }
                    }
                }
            }
        }
        // Keyed on the version: a newer listing cancels an older one, whose result is then dropped.
        .task(id: version) {
            let listed = await CustomIconImages.shared.refs()
            guard !Task.isCancelled else { return }
            refs = listed
        }
        .onReceive(NotificationCenter.default.publisher(for: CustomIconImages.didChange)) { _ in version &+= 1 }
    }

    /// Asks for an image file, stores it off the main thread and selects it; a refused image shows a toast.
    private func upload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.prompt = "Upload"
        uploading = true
        Task { @MainActor in
            defer { uploading = false }
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do {
                selection = try await CustomIconImages.shared.upload(url)
            } catch {
                model.showToast(OperationToast(kind: .failure, title: "Image not added",
                                               detail: (error as? CustomIcon.Problem)?.message
                                                   ?? error.localizedDescription))
            }
        }
    }

    /// Deletes the stored image; it leaves the list at once, and the selection when it was selected.
    private func delete(_ ref: String) {
        refs.removeAll { $0 == ref }
        if selection == ref { selection = nil }
        CustomIconImages.shared.remove(ref)
    }
}

/// One stored image, fitted in a small square: a click selects it, the selected one has a blue ring, and a small
/// delete button sits on its corner.
private struct Thumbnail: View {
    let ref: String
    /// `IconLibraryPicker.version`: the cached image is read again when it changes.
    let version: Int
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    private static let side: CGFloat = 30
    private static let image: CGFloat = 20
    private static let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)

    var body: some View {
        Button(action: onSelect) {
            Group {
                if let image = CustomIconImages.shared.image(for: ref) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if CustomIconImages.shared.isMissing(ref) {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                } else {
                    Color.clear
                }
            }
            .frame(width: Self.image, height: Self.image)
            .frame(width: Self.side, height: Self.side)
            .background(Self.shape.fill(Palette.inputSurface))
            .overlay(Self.shape.fill(hovered ? Palette.hoverFill : .clear).allowsHitTesting(false))
            .overlay(Self.shape.strokeBorder(selected ? Palette.primaryFill : .clear, lineWidth: 2))
            .contentShape(Self.shape)
        }
        .buttonStyle(.plain)
        .help("Use this image")
        .accessibilityLabel("Uploaded image")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .background(Circle().fill(Palette.inputSurface))
            }
            .buttonStyle(RowIconButtonStyle())
            .help("Delete this image")
            .accessibilityLabel("Delete image")
        }
        .onHover { hovered = $0 }
        // Keyed on the version too: an upload drops the cached image of its reference, which then loads again.
        .task(id: "\(ref)#\(version)") {
            await CustomIconImages.shared.load(ref)
        }
    }
}
