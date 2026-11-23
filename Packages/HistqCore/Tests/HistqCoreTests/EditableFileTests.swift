// Key feature and security tests for the file editor's codec and open gate: unedited text round-trips byte exact
// (LF, CRLF, mixed, lone CR, no trailing newline, BOM), edits keep CRLF files CRLF and the BOM once, and the open gate
// refuses a symlink, binary and non-UTF-8 content, and a missing folder without creating it.
import Foundation
import HistqCore
import Testing

struct EditableFileTests {
    static func bytes(_ text: String) -> Data { Data(text.utf8) }
    static let bom = Data([0xEF, 0xBB, 0xBF])

    @Test func uneditedTextRoundTripsByteExact() throws {
        let table: [(name: String, data: Data, ending: EditableText.LineEnding)] = [
            ("LF", Self.bytes("one\ntwo\n"), .verbatim),
            ("CRLF", Self.bytes("one\r\ntwo\r\n"), .crlf),
            ("mixed", Self.bytes("one\r\ntwo\nthree\r\n"), .verbatim),
            ("lone CR", Self.bytes("one\rtwo\r\n"), .verbatim),
            ("no trailing newline", Self.bytes("one\r\ntwo"), .crlf),
            ("BOM", Self.bom + Self.bytes("one\r\ntwo\r\n"), .crlf),
            ("empty", Data(), .verbatim),
        ]
        for row in table {
            let codec = try #require(EditableText(decoding: row.data), "\(row.name)")
            #expect(codec.lineEnding == row.ending, "\(row.name)")
            #expect(codec.encode(codec.text) == row.data, "\(row.name)")
        }
        let crlf = try #require(EditableText(decoding: Self.bytes("a\r\nb\r\n")))
        #expect(Array(crlf.text.utf8) == Array("a\nb\n".utf8))
        let bom = try #require(EditableText(decoding: Self.bom + Self.bytes("x")))
        #expect(bom.hasBOM)
        #expect(Array(bom.text.utf8) == Array("x".utf8))
    }

    @Test func editsEncodeAsExpected() throws {
        // A CRLF file with an inserted line and a pasted CRLF line: CRLF everywhere, never CR CR LF.
        let crlf = try #require(EditableText(decoding: Self.bytes("one\r\ntwo\r\n")))
        let edited = crlf.encode("one\ninserted\npasted\r\ntwo\n")
        #expect(edited == Self.bytes("one\r\ninserted\r\npasted\r\ntwo\r\n"))
        #expect(edited.range(of: Self.bytes("\r\r\n")) == nil)

        // Text typed at the start of a BOM file, and a stray U+FEFF pasted there: the BOM leads, exactly once.
        let bom = try #require(EditableText(decoding: Self.bom + Self.bytes("body\n")))
        #expect(bom.encode("typed body\n") == Self.bom + Self.bytes("typed body\n"))
        #expect(bom.encode("\u{FEFF}typed body\n") == Self.bom + Self.bytes("typed body\n"))

        // A file with no line break, edited with a Return: LF.
        let single = try #require(EditableText(decoding: Self.bytes("one line")))
        #expect(single.lineEnding == .verbatim)
        #expect(single.encode("one\nline") == Self.bytes("one\nline"))
    }

    @Test func openGateRefusesUnsafeFiles() throws {
        let root = try Fixtures.makeTempDirectory("HistqEditableFile")
        defer { Fixtures.removeTempDirectory(root) }
        try Self.bytes("target\n").write(to: root.appending(path: "target.txt"))
        try FileManager.default.createSymbolicLink(
            at: root.appending(path: "link.txt"), withDestinationURL: root.appending(path: "target.txt"))
        try Data([0x61, 0x00, 0x62]).write(to: root.appending(path: "binary.bin"))
        try Data([0x61, 0xC3, 0x28]).write(to: root.appending(path: "latin.txt"))

        let read = try EditableFile.read(path: "target.txt", cwd: root, limit: 1 << 20)
        #expect(read.data == Self.bytes("target\n"))
        #expect(throws: EditableFile.Refusal.symlink) {
            try EditableFile.read(path: "link.txt", cwd: root, limit: 1 << 20)
        }
        #expect(throws: EditableFile.Refusal.binary) {
            try EditableFile.read(path: "binary.bin", cwd: root, limit: 1 << 20)
        }
        #expect(throws: EditableFile.Refusal.notUTF8) {
            try EditableFile.read(path: "latin.txt", cwd: root, limit: 1 << 20)
        }
        #expect(throws: EditableFile.Refusal.missing) {
            try EditableFile.read(path: "gone/deeper/file.txt", cwd: root, limit: 1 << 20)
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "gone").path))
    }
}
