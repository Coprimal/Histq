// Key feature and untrusted-input tests for uploaded tab icons (custom icon upload plan, phase 1 task 3): a reference
// read from a file names a file only when it parses strictly (no traversal, no other shape), and the library stores a
// valid image once under its hash while refusing a wrong size or a non-image without writing anything. The images are
// made in the test with CoreGraphics + ImageIO, in a temp folder.
import CoreGraphics
import CryptoKit
import Foundation
import HistqCore
import ImageIO
import Testing
import UniformTypeIdentifiers

/// A well-formed name's hash part: 64 lowercase hex digits.
private let hash = String(repeating: "0123456789abcdef", count: 4)

struct CustomIconTests {
    /// A PNG of `width` × `height` pixels, filled with one colour.
    static func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1,
                                                                        nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The names of the files in `folder`; [] when it does not exist.
    static func files(in folder: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    }

    // MARK: - References

    @Test("a malformed or path-traversal reference names no file", arguments: [
        "icon:../x.png",
        "icon:../\(hash).png",
        "icon:\(hash)/../x.png",
        "icon:sub/\(hash).png",
        "icon:/\(hash).png",
        "icon:\(hash.uppercased()).png",
        "icon:\(hash).gif",
        "icon:\(hash).PNG",
        "icon:\(hash).png.png",
        "icon:\(hash)..png",
        "icon:\(hash)",
        "icon:\(hash.dropLast()).png",
        "icon:\(hash)0.png",
        "icon:",
        "\(hash).png",
        "ICON:\(hash).png",
        " icon:\(hash).png",
    ])
    func rejectsMalformedReference(ref: String) throws {
        #expect(CustomIcon.fileName(ref: ref) == nil)
        #expect(!CustomIcon.isRef(ref))
        let library = CustomIcon.Library(directory: URL(filePath: "/tmp/HistqIcons", directoryHint: .isDirectory))
        #expect(library.url(for: ref) == nil)
    }

    @Test("a valid reference names its file directly inside the folder", arguments: ["png", "jpg", "webp", "svg"])
    func acceptsValidReference(ext: String) throws {
        let name = "\(hash).\(ext)"
        let ref = CustomIcon.ref(fileName: name)
        #expect(ref == "icon:\(name)")
        #expect(CustomIcon.fileName(ref: ref) == name)
        #expect(CustomIcon.isRef(ref))

        let directory = URL(filePath: "/tmp/HistqIcons", directoryHint: .isDirectory)
        let url = try #require(CustomIcon.Library(directory: directory).url(for: ref))
        #expect(url.lastPathComponent == name)
        #expect(url.deletingLastPathComponent().standardizedFileURL.path == directory.standardizedFileURL.path)
    }

    // MARK: - Library

    @Test("a valid PNG added twice is stored once, under the SHA-256 of its bytes, with the same reference")
    func addStoresOnceUnderHash() throws {
        let folder = try Fixtures.makeTempDirectory("HistqCustomIcon")
        defer { Fixtures.removeTempDirectory(folder) }
        let data = try Self.png(width: 32, height: 32)
        let upload = folder.appending(path: "upload.png")
        try data.write(to: upload)
        let library = CustomIcon.Library(directory: folder.appending(path: "Icons", directoryHint: .isDirectory))

        let first = try library.add(contentsOf: upload)
        let second = try library.add(contentsOf: upload)

        let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() + ".png"
        #expect(first == second)
        #expect(CustomIcon.fileName(ref: first) == expected)
        #expect(Self.files(in: library.directory) == [expected])
        #expect(try Data(contentsOf: try #require(library.url(for: first))) == data)
        #expect(library.refs() == [first])
    }

    @Test("a PNG with a side out of range and a non-image are refused and nothing is stored")
    func addRefusesWithoutStoring() throws {
        let folder = try Fixtures.makeTempDirectory("HistqCustomIcon")
        defer { Fixtures.removeTempDirectory(folder) }
        let library = CustomIcon.Library(directory: folder.appending(path: "Icons", directoryHint: .isDirectory))

        let tiny = folder.appending(path: "tiny.png")
        try Self.png(width: 8, height: 8).write(to: tiny)
        #expect(throws: CustomIcon.Problem.sizeOutOfRange(width: 8, height: 8)) { try library.add(contentsOf: tiny) }

        let text = folder.appending(path: "notes.png")
        try Data("not an image, just text\n".utf8).write(to: text)
        #expect(throws: CustomIcon.Problem.self) { try library.add(contentsOf: text) }

        #expect(Self.files(in: library.directory).isEmpty)
        #expect(library.refs().isEmpty)
    }
    @Test("an SVG is stored with its extension; XML with another root is refused")
    func addsSVG() throws {
        let folder = try Fixtures.makeTempDirectory("HistqCustomIcon")
        defer { Fixtures.removeTempDirectory(folder) }
        let library = CustomIcon.Library(directory: folder.appending(path: "Icons", directoryHint: .isDirectory))

        let svg = folder.appending(path: "logo.svg")
        try Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 8 8"/>"#.utf8).write(to: svg)
        let ref = try library.add(contentsOf: svg)
        #expect(ref.hasSuffix(".svg"))
        #expect(library.refs() == [ref])

        let html = folder.appending(path: "page.svg")
        try Data("<html><body/></html>".utf8).write(to: html)
        #expect(throws: CustomIcon.Problem.self) { try library.add(contentsOf: html) }
        #expect(library.refs() == [ref])
    }
}
