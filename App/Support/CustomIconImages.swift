// The uploaded tab icons (`CustomIcon` references) as images. `image(for:)` only reads the cache, so a draw never
// waits on the disk: a view asks `load(_:)` for a reference it has no image for, which decodes the file off the main
// thread with ImageIO and posts `didChange` once the image (or its absence) is known. A reference that does not parse
// or names a missing or undecodable file is recorded as missing once and never retried per draw, until an upload of
// the same image clears it. Uploads, removals and the listing of the folder go through `CustomIcon.Library`. An SVG
// is drawn by AppKit into a bitmap of `svgPixels` on its longer side; an uploaded SVG that AppKit cannot draw is
// deleted again and refused.
import AppKit
import HistqCore
import ImageIO

@MainActor
final class CustomIconImages {
    static let shared = CustomIconImages()

    /// Posted on the main thread when an image was loaded or found missing, uploaded or removed.
    static let didChange = Notification.Name("CustomIconImages.didChange")

    /// Loaded images, by reference.
    private var images: [String: NSImage] = [:]
    /// References whose load found no image: an invalid reference, a missing or undecodable file.
    private var missing: Set<String> = []
    /// References being loaded, with the token of their load: a load that `upload` or `remove` superseded (its token
    /// is gone) drops its result.
    private var inFlight: [String: Int] = [:]
    private var nextToken = 0

    private init() {}

    /// The cached image of `ref`; nil until `load(_:)` has loaded it. Never reads the disk.
    func image(for ref: String) -> NSImage? {
        images[ref]
    }

    /// Whether the load of `ref` found no image.
    func isMissing(_ ref: String) -> Bool {
        missing.contains(ref)
    }

    /// Decodes the image of `ref` off the main thread, then caches it or records it as missing and posts `didChange`.
    /// Nothing when it is cached, missing or already being loaded.
    func load(_ ref: String) async {
        guard images[ref] == nil, !missing.contains(ref), inFlight[ref] == nil else { return }
        nextToken += 1
        let token = nextToken
        inFlight[ref] = token
        let decoded = await Task.detached(priority: .utility) { IconFiles.decode(ref) }.value
        guard inFlight[ref] == token else { return }
        inFlight[ref] = nil
        if let decoded {
            let size = NSSize(width: decoded.cgImage.width, height: decoded.cgImage.height)
            images[ref] = NSImage(cgImage: decoded.cgImage, size: size)
        } else {
            missing.insert(ref)
        }
        postChange()
    }

    /// Checks and stores the image at `url` off the main thread and returns its reference. Throws a
    /// `CustomIcon.Problem` for a refused image, or the error of a failed write.
    func upload(_ url: URL) async throws -> String {
        let ref = try await Task.detached(priority: .userInitiated) { try IconFiles.add(url) }.value
        forget(ref)
        postChange()
        return ref
    }

    /// Deletes the stored image of `ref`; tabs still using it show it as missing.
    func remove(_ ref: String) {
        forget(ref)
        IconFiles.library.remove(ref: ref)
        missing.insert(ref)
        postChange()
    }

    /// The references of the stored images, newest first, read off the main thread.
    func refs() async -> [String] {
        await Task.detached(priority: .userInitiated) { IconFiles.library.refs() }.value
    }

    /// Drops what is known of `ref`, including a load in flight, so the next `load(_:)` reads the file again.
    private func forget(_ ref: String) {
        images[ref] = nil
        missing.remove(ref)
        inFlight[ref] = nil
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}

/// The off-main half: the folder and the decoding.
private enum IconFiles {
    /// A decoded image. CGImage is immutable, so crossing to the main actor is safe.
    struct Decoded: @unchecked Sendable {
        let cgImage: CGImage
    }

    /// Created on first use, normally off the main thread (`StatePaths.directory` creates the folder).
    static let library = CustomIcon.Library(directory: StatePaths.directory("Icons"))
    /// The longer side, in pixels, an SVG is drawn at: sharp at every size a tab icon or thumbnail takes.
    static let svgPixels: CGFloat = 128

    /// Stores the image at `url` and returns its reference; an SVG that cannot be drawn is deleted and refused.
    static func add(_ url: URL) throws -> String {
        let ref = try library.add(contentsOf: url)
        if ref.hasSuffix("." + CustomIcon.svgExtension), decode(ref) == nil {
            library.remove(ref: ref)
            throw CustomIcon.Problem.unreadable
        }
        return ref
    }

    /// The first frame of the image `ref` names, decoded now; nil for an invalid reference or a missing or
    /// undecodable file.
    static func decode(_ ref: String) -> Decoded? {
        guard let url = library.url(for: ref) else { return nil }
        if url.pathExtension == CustomIcon.svgExtension { return drawSVG(url) }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        return CGImageSourceCreateImageAtIndex(source, 0, options).map(Decoded.init)
    }

    /// The SVG at `url` drawn into a bitmap of `svgPixels` on its longer side, its aspect kept; nil when it does not
    /// read or has no size.
    private static func drawSVG(_ url: URL) -> Decoded? {
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data),
              image.size.width > 0, image.size.height > 0 else { return nil }
        let scale = svgPixels / max(image.size.width, image.size.height)
        let width = max(1, Int((image.size.width * scale).rounded()))
        let height = max(1, Int((image.size.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().map(Decoded.init)
    }
}
