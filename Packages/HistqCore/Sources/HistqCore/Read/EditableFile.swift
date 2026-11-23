// The file editor's codec and open gate: `EditableText` turns a working-tree file's bytes into the text that is
// edited and back, byte exact when unedited (strict UTF-8, BOM kept aside, CRLF files edited as LF), and
// `EditableFile.read` opens a worktree path for editing without creating or following anything, refusing symlinks,
// special files, big, binary and non-UTF-8 files with a typed `Refusal`.
import Foundation

/// How a file's bytes are edited as text and written back.
public struct EditableText: Sendable {
    /// How line breaks are written back.
    public enum LineEnding: Sendable, Equatable {
        /// Every line break of the file is CRLF (and there is at least one): edited as LF, written as CRLF.
        case crlf
        /// Anything else (LF, mixed, lone CR, no line break at all): the text is edited and written as is.
        case verbatim
    }

    static let bom: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// The text to edit: the decoded bytes without the BOM, with CRLF turned into LF for `.crlf`.
    public let text: String
    /// The file starts with a UTF-8 BOM, which `encode` writes back exactly once.
    public let hasBOM: Bool
    public let lineEnding: LineEnding

    /// The bytes as editable text, or nil when they are not valid UTF-8 (never decoded lossily).
    public init?(decoding data: Data) {
        var bytes = [UInt8](data)
        hasBOM = bytes.starts(with: Self.bom)
        if hasBOM { bytes.removeFirst(Self.bom.count) }
        lineEnding = Self.lineEnding(of: bytes)
        // In a `.crlf` file every CR is followed by an LF, so dropping every CR turns CRLF into LF.
        if lineEnding == .crlf { bytes.removeAll { $0 == 0x0D } }
        guard let text = String(validating: bytes, as: UTF8.self) else { return nil }
        self.text = text
    }

    /// The bytes to write for `text`: a U+FEFF left at its start is dropped, the BOM put back when the file had one,
    /// and for `.crlf` every line break written as CRLF (a pasted CRLF first turned into LF, so it never doubles).
    public func encode(_ text: String) -> Data {
        var scalars = Substring(text).unicodeScalars
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        let utf8 = Substring(scalars).utf8
        var out = Data(capacity: utf8.count + (hasBOM ? Self.bom.count : 0))
        if hasBOM { out.append(contentsOf: Self.bom) }
        switch lineEnding {
        case .verbatim:
            out.append(contentsOf: utf8)
        case .crlf:
            var index = utf8.startIndex
            while index != utf8.endIndex {
                let byte = utf8[index]
                let next = utf8.index(after: index)
                if byte == 0x0D, next != utf8.endIndex, utf8[next] == 0x0A {
                    // CRLF → LF; the LF then writes CRLF.
                } else if byte == 0x0A {
                    out.append(contentsOf: [0x0D, 0x0A])
                } else {
                    out.append(byte)
                }
                index = next
            }
        }
        return out
    }

    /// `.crlf` when there is at least one CRLF, no lone LF and no lone CR; else `.verbatim`.
    static func lineEnding(of bytes: [UInt8]) -> LineEnding {
        var pairs = 0
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case 0x0D:
                guard index + 1 < bytes.count, bytes[index + 1] == 0x0A else { return .verbatim }
                pairs += 1
                index += 2
                continue
            case 0x0A:
                return .verbatim
            default:
                break
            }
            index += 1
        }
        return pairs > 0 ? .crlf : .verbatim
    }
}

public enum EditableFile {
    /// Why a worktree file cannot be opened for editing.
    public enum Refusal: Error, Sendable, Equatable {
        /// Not a plain relative path inside the worktree (`..`, `.git`, absolute), or a parent folder that is not a
        /// folder (a file or a symlink).
        case unsafePath
        /// The file or one of its parent folders does not exist.
        case missing
        /// The path is a symlink; it is never followed.
        case symlink
        /// Not a regular file (a folder, a FIFO, a device…).
        case notRegular
        /// Bigger than the limit; the size in bytes.
        case tooLarge(Int)
        /// A NUL byte in the first 8000 bytes.
        case binary
        /// Not valid UTF-8.
        case notUTF8
        /// Any other failure to look up, open or read the file; the `errno`.
        case unreadable(Int32)
    }

    /// The bytes at most this far in are checked for a NUL.
    static let binaryProbe = 8000

    /// Reads the worktree file `path` (relative to `cwd`) for editing: `data` is the raw bytes read, the base for
    /// later compares. Nothing is created: a missing parent folder is `.missing`. No symlink is followed, the
    /// file's own or a parent folder's.
    public static func read(path: String, cwd: URL, limit: Int) throws(Refusal) -> (data: Data, text: EditableText) {
        guard UndoJournal.isSafePath(path) else { throw .unsafePath }
        var folder = cwd
        for part in path.split(separator: "/", omittingEmptySubsequences: false).dropLast() {
            folder = folder.appending(path: String(part), directoryHint: .isDirectory)
            var info = stat()
            if lstat(folder.path, &info) != 0 {
                let code = errno
                switch code {
                case ENOENT: throw .missing
                case ENOTDIR: throw .unsafePath
                default: throw .unreadable(code)
                }
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw .unsafePath }
        }
        let file = cwd.appending(path: path, directoryHint: .notDirectory)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ELOOP: throw .symlink
            case ENOENT: throw .missing
            case ENOTDIR: throw .unsafePath
            default: throw .unreadable(code)
            }
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .unreadable(errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notRegular }
        guard info.st_size <= limit else { throw .tooLarge(Int(info.st_size)) }
        let data = try readAll(fd, limit: limit)
        guard !data.prefix(binaryProbe).contains(0) else { throw .binary }
        guard let text = EditableText(decoding: data) else { throw .notUTF8 }
        return (data, text)
    }

    /// Every byte of `fd` up to `limit`; a file that grew past it since `fstat` is `.tooLarge`.
    private static func readAll(_ fd: Int32, limit: Int) throws(Refusal) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0 {
                let code = errno
                if code == EINTR { continue }
                throw .unreadable(code)
            }
            if count == 0 { return data }
            data.append(contentsOf: buffer[..<count])
            if data.count > limit { throw .tooLarge(data.count) }
        }
    }
}
