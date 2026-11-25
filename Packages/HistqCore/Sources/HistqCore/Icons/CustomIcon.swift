// Uploaded images used as tab icons. A tab icon slot holds one String: an emoji or a reference `icon:<name>`, where
// `<name>` is the lowercase hex SHA-256 of the image's bytes plus the extension of its detected type. The images live
// in one folder (`Library`). Uploads and the references read from session and workspace files are untrusted: a
// reference is parsed strictly before it names a file, so it never leaves the folder, and an upload is size-checked
// before it is read and decoded only by ImageIO. An SVG, which ImageIO does not read, is recognised by its root
// element `<svg>` (parsed without resolving external entities) and has no pixel size to check; the app draws it.
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CustomIcon {
    /// The largest file accepted, in bytes.
    public static let maxBytes = 512 * 1024
    /// The accepted width and height, in pixels.
    public static let sides = 16...512
    /// The marker that starts a reference.
    public static let prefix = "icon:"

    /// The accepted image types (UTI) and the extension each is stored with.
    static let extensions: [String: String] = [
        UTType.png.identifier: "png",
        UTType.jpeg.identifier: "jpg",
        UTType.webP.identifier: "webp",
    ]
    /// The extension an SVG is stored with.
    public static let svgExtension = "svg"

    /// The reference for a stored file name.
    public static func ref(fileName: String) -> String {
        prefix + fileName
    }

    /// The file name a reference names, or nil when the value is not a valid reference.
    public static func fileName(ref: String) -> String? {
        guard ref.hasPrefix(prefix) else { return nil }
        let name = String(ref.dropFirst(prefix.count))
        return isValidFileName(name) ? name : nil
    }

    /// Whether the value is a valid reference.
    public static func isRef(_ value: String?) -> Bool {
        value.flatMap { fileName(ref: $0) } != nil
    }

    /// Exactly 64 lowercase hex digits, a dot and one accepted extension: nothing that can leave the folder.
    public static func isValidFileName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, extensions.values.contains(String(parts[1])) || parts[1] == svgExtension else {
            return false
        }
        let hash = parts[0].utf8
        return hash.count == 64 && hash.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Why an image was refused.
    public enum Problem: Error, Equatable {
        case tooLarge(bytes: Int)
        case unsupportedType
        case sizeOutOfRange(width: Int, height: Int)
        case unreadable

        /// A user-facing explanation.
        public var message: String {
            switch self {
            case let .tooLarge(bytes):
                "The image is \((bytes + 1023) / 1024) KB; the limit is \(CustomIcon.maxBytes / 1024) KB."
            case .unsupportedType:
                "The file is not a supported image. Use a PNG, JPEG, WebP or SVG image."
            case let .sizeOutOfRange(width, height):
                "The image is \(width) × \(height) px; each side must be \(CustomIcon.sides.lowerBound)–\(CustomIcon.sides.upperBound) px."
            case .unreadable:
                "The image could not be read."
            }
        }
    }

    /// Whether `data` is an XML document whose root element is `svg`. Only the start of the document is parsed.
    static func isSVG(_ data: Data) -> Bool {
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        let root = RootElement()
        parser.delegate = root
        parser.parse()
        return root.name == "svg"
    }

    /// Records the local name of the root element, then stops the parse.
    private final class RootElement: NSObject, XMLParserDelegate {
        var name: String?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            name = elementName.split(separator: ":").last.map(String.init)
            parser.abortParsing()
        }
    }

    /// The folder of uploaded images, one file per distinct image.
    public struct Library: Sendable {
        public let directory: URL

        public init(directory: URL) {
            self.directory = directory
        }

        /// Checks the image at `url`, stores it unless the same image is already stored (then marks it as the newest)
        /// and returns its reference. Throws a `Problem` for a refused image, or the error of a failed write.
        public func add(contentsOf url: URL) throws -> String {
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { throw Problem.unreadable }
            guard size <= CustomIcon.maxBytes else { throw Problem.tooLarge(bytes: size) }
            guard let data = try? Data(contentsOf: url) else { throw Problem.unreadable }
            guard data.count <= CustomIcon.maxBytes else { throw Problem.tooLarge(bytes: data.count) }
            if CustomIcon.isSVG(data) { return try store(data, ext: CustomIcon.svgExtension) }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw Problem.unreadable }
            guard let type = CGImageSourceGetType(source) as String?, let ext = CustomIcon.extensions[type] else {
                throw Problem.unsupportedType
            }
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int
            else { throw Problem.unreadable }
            guard CustomIcon.sides.contains(width), CustomIcon.sides.contains(height) else {
                throw Problem.sizeOutOfRange(width: width, height: height)
            }
            return try store(data, ext: ext)
        }

        /// Stores `data` under the SHA-256 of its bytes unless it is already stored (then marks it as the newest) and
        /// returns its reference.
        private func store(_ data: Data, ext: String) throws -> String {
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let name = hash + "." + ext
            let file = directory.appendingPathComponent(name, isDirectory: false)
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: file.path) {
                try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            } else {
                try data.write(to: file, options: .atomic)
            }
            return CustomIcon.ref(fileName: name)
        }

        /// The references of the stored images, newest first; [] when the folder does not exist.
        public func refs() -> [String] {
            let keys: [URLResourceKey] = [.contentModificationDateKey]
            guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
            else { return [] }
            let stored = files.compactMap { file -> (name: String, date: Date)? in
                let name = file.lastPathComponent
                guard CustomIcon.isValidFileName(name) else { return nil }
                let date = (try? file.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast
                return (name, date)
            }
            return stored
                .sorted { $0.date != $1.date ? $0.date > $1.date : $0.name < $1.name }
                .map { CustomIcon.ref(fileName: $0.name) }
        }

        /// Deletes the stored image of a reference; nothing for an invalid reference or a missing file.
        public func remove(ref: String) {
            guard let file = url(for: ref) else { return }
            try? FileManager.default.removeItem(at: file)
        }

        /// The file a reference names, or nil for an invalid reference. The file may not exist.
        public func url(for ref: String) -> URL? {
            CustomIcon.fileName(ref: ref).map { directory.appendingPathComponent($0, isDirectory: false) }
        }
    }
}
