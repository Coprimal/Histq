// What of a diff an AI request may see: a repo's `.aiignore` (a gitignore subset) keeps files out of every AI
// request, and lock or generated files are cut to their header because their contents only waste the size budget.
// `.aiignore` is privacy-grade, so the paths of a file are read from every line that names them (header, renames,
// `---`/`+++`), C-quoted paths are unquoted, and a header whose split is ambiguous is checked every way it can be
// read (fail closed). `AIPrompts.filtered` applies both before `budgeted`. `AIIgnore.load` reads a worktree's
// `.aiignore` (throwing on anything but a small regular file), and `filteredUnlessAllIgnored` reports a diff that
// `.aiignore` emptied, so neither case sends unfiltered or empty content.
import CryptoKit
import Foundation

/// The patterns of a `.aiignore` file: `#` comments, blank lines, `*` and `?` (never across `/`), `**` (any number of
/// folders), `[...]` classes (ranges, `!` or `^` negation), `\` escapes (`\#`, `\!`, `\ ` for a trailing space), a
/// trailing `/` (folders only) and a leading or inner `/` (anchored to the repo root); a pattern without a slash
/// matches a name at any depth. Matching ignores case so that it only ever over-excludes (the safe error): a class
/// matches when any case of the character would. As in gitignore, a file is matched when a pattern matches its path or
/// any folder above it. `!` negation is not supported: such lines are ignored.
public struct AIIgnore: Sendable, Equatable {
    struct Rule: Sendable, Equatable {
        var segments: [String]
        var anchored: Bool
        var foldersOnly: Bool
    }

    let rules: [Rule]

    public init(text: String) {
        var rules: [Rule] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            // A BOM would otherwise stick to the first pattern and silently disable it.
            var line = rawLine.trimmingCharacters(in: CharacterSet.whitespaces.union(["\u{FEFF}"]))
            // `\ ` keeps the trailing space the trim just took.
            if line.hasSuffix("\\"), rawLine.contains(line + " ") { line += " " }
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
            let foldersOnly = line.hasSuffix("/")
            if foldersOnly { line.removeLast() }
            let anchored = line.contains("/")
            let segments = line.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            rules.append(Rule(segments: segments, anchored: anchored, foldersOnly: foldersOnly))
        }
        self.rules = rules
    }

    /// True when `path` (relative to the repo root, `/`-separated) or a folder above it is matched. With `orFolder`,
    /// `path` itself is also read as a folder (folders-only rules apply to it), for a path that may name either.
    public func matches(_ path: String, orFolder: Bool = false) -> Bool {
        let components = path.split(separator: "/").map(String.init)
        for end in components.indices {
            let prefix = Array(components[...end])
            let isFolder = orFolder || end < components.count - 1
            for rule in rules where isFolder || !rule.foldersOnly {
                let matched = rule.anchored
                    ? Self.matchSegments(rule.segments, prefix)
                    : Self.glob(rule.segments[0], prefix[prefix.count - 1])
                if matched { return true }
            }
        }
        return false
    }

    /// Pattern segments against path segments: `**` matches any number of segments (one or more when it ends the
    /// pattern, as `dir/**` matches what is inside `dir`). Dynamic programming, so many `**` never blow up.
    static func matchSegments(_ pattern: [String], _ path: [String]) -> Bool {
        // `next[j]`: pattern[(i + 1)...] matches path[j...].
        var next = Array(repeating: false, count: path.count + 1)
        next[path.count] = true
        for i in pattern.indices.reversed() {
            var row = Array(repeating: false, count: path.count + 1)
            for j in (0...path.count).reversed() {
                if pattern[i] == "**" {
                    row[j] = i == pattern.count - 1 ? j < path.count : next[j] || (j < path.count && row[j + 1])
                } else {
                    row[j] = j < path.count && glob(pattern[i], path[j]) && next[j + 1]
                }
            }
            next = row
        }
        return next[0]
    }

    /// One token of a pattern segment: a run of anything, one character, a bracket class or a literal.
    enum Token {
        case star
        case any
        case set([(Character, Character)], negated: Bool)
        case literal(Character)

        /// Literals ignore case; a class is tried with `c` and its lower and upper case, and matches when any of them
        /// is inside (or, negated, outside) its ranges, so a case difference never lets a name through.
        func matches(_ c: Character) -> Bool {
            switch self {
            case .star, .any: return true
            case .literal(let l): return l.lowercased() == c.lowercased()
            case .set(let ranges, let negated):
                let variants = [String(c), c.lowercased(), c.uppercased()].compactMap { $0.count == 1 ? $0.first : nil }
                return variants.contains { v in ranges.contains { $0.0 <= v && v <= $0.1 } != negated }
            }
        }
    }

    /// A pattern segment as tokens: `\x` is a literal x; `[...]` a class with ranges, `!` or `^` negation, a `]`
    /// first and a `-` first or last taken literally. An unterminated `[` and a trailing `\` are literals.
    static func tokens(_ pattern: [Character]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        while i < pattern.count {
            let c = pattern[i]
            i += 1
            switch c {
            case "*": tokens.append(.star)
            case "?": tokens.append(.any)
            case "\\" where i < pattern.count:
                tokens.append(.literal(pattern[i]))
                i += 1
            case "[":
                if let (set, end) = bracket(pattern, from: i) {
                    tokens.append(set)
                    i = end
                } else {
                    tokens.append(.literal(c))
                }
            default: tokens.append(.literal(c))
            }
        }
        return tokens
    }

    /// The class opened by the `[` before `start`, and the index after its `]`; nil when it is not closed.
    static func bracket(_ p: [Character], from start: Int) -> (Token, Int)? {
        var i = start
        let negated = i < p.count && (p[i] == "!" || p[i] == "^")
        if negated { i += 1 }
        var items: [Character] = []
        var escaped: [Bool] = []
        while i < p.count, p[i] != "]" || items.isEmpty {
            if p[i] == "\\", i + 1 < p.count {
                i += 1
                escaped.append(true)
            } else {
                escaped.append(false)
            }
            items.append(p[i])
            i += 1
        }
        guard i < p.count else { return nil }
        var ranges: [(Character, Character)] = []
        var k = 0
        while k < items.count {
            if k + 2 < items.count, items[k + 1] == "-", !escaped[k + 1] {
                ranges.append((items[k], items[k + 2]))
                k += 3
            } else {
                ranges.append((items[k], items[k]))
                k += 1
            }
        }
        return (.set(ranges, negated: negated), i + 1)
    }

    /// One name against one pattern segment (`*` any run, `?` one character, `[...]` a class, `\` an escape),
    /// case-insensitively as `Token.matches` (over-excluding is the safe error), by Characters so a decomposed (NFD)
    /// file name still matches a composed pattern. Backtracks only to the last `*`, so it stays linear-ish.
    static func glob(_ pattern: String, _ name: String) -> Bool {
        let p = tokens(Array(pattern))
        let n = Array(name)
        var pi = 0
        var ni = 0
        var star: Int?
        var starName = 0
        while ni < n.count {
            if pi < p.count, case .star = p[pi] {
                star = pi
                starName = ni
                pi += 1
            } else if pi < p.count, p[pi].matches(n[ni]) {
                pi += 1
                ni += 1
            } else if let star {
                pi = star + 1
                starName += 1
                ni = starName
            } else {
                return false
            }
        }
        while pi < p.count, case .star = p[pi] { pi += 1 }
        return pi == p.count
    }

    /// Why a `.aiignore` could not be loaded: it exists but is a symlink, not a regular file, over 64 KB or unreadable.
    public enum LoadError: Error, Equatable, Sendable {
        case unreadable
    }

    /// The `.aiignore` of `worktree`: only a regular file of at most 64 KB, opened without following a symlink and
    /// without blocking; nil when it is missing. One that exists but is anything else, too big or unreadable throws
    /// `LoadError.unreadable`, so nothing is sent unfiltered.
    public static func load(worktree: URL) throws -> AIIgnore? {
        let limit = 64 * 1024
        let fd = open(worktree.appending(path: ".aiignore").path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw LoadError.unreadable
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = try? handle.read(upToCount: limit + 1) ?? Data(), data.count <= limit
        else { throw LoadError.unreadable }
        return AIIgnore(text: String(decoding: data, as: UTF8.self))
    }

    /// A fingerprint of the rules `ignore` applies (nil: no `.aiignore`), so a saved AI chat context can tell whether
    /// it was filtered with the rules in force now. Comments and blank lines do not change it.
    public static func digest(_ ignore: AIIgnore?) -> String {
        guard let ignore else { return "none" }
        // Every part length-prefixed, so two rule lists never write the same text.
        var text = ""
        for rule in ignore.rules {
            text += "\(rule.anchored ? 1 : 0)\(rule.foldersOnly ? 1 : 0)\(rule.segments.count);"
            for segment in rule.segments { text += "\(segment.utf8.count):\(segment)" }
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

extension AIPrompts {
    /// `filtered`, or nil when `.aiignore` left out every file (only the closing note would be sent). An empty diff
    /// is returned as it is.
    public static func filteredUnlessAllIgnored(_ diff: String, ignore: AIIgnore?) -> String? {
        let kept = filtered(diff, ignore: ignore)
        let hasFile = kept.split(separator: "\n").contains {
            $0.hasPrefix("diff --git ") || $0.hasPrefix("diff --cc ") || $0.hasPrefix("diff --combined ")
        }
        return kept == diff || hasFile ? kept : nil
    }

    /// `text` (git's or a hook's output) without the lines that name a file `ignore` excludes, and a closing line
    /// "(N lines naming files excluded by .aiignore left out)" when any went (the lines then end in `\n`); nil
    /// `ignore`, or no such line, returns `text` as it is. Fails closed: a line is split into words at every character
    /// a path rarely holds (spaces, quotes, `:`, brackets, commas), and each word, as written and without its closing
    /// dots, is checked whole and from each of its folders on (so `/abs/repo/secrets/key`, `a/secrets/key` and
    /// `./secrets/key` all match `secrets/**`). Only the naming line goes: output printed under it without the path
    /// (a code frame) stays.
    public static func droppingIgnoredLines(_ text: String, ignore: AIIgnore?) -> String {
        guard let ignore else { return text }
        var dropped = 0
        let kept = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).filter { line in
            let named = line.split { !isPathCharacter($0) }.contains { word in
                // As written and without a sentence's closing dots ("see certs/server.pem.").
                let trimmed = word.prefix(through: word.lastIndex { $0 != "." } ?? word.startIndex)
                return [word, trimmed].contains { word in
                    let parts = word.split(separator: "/").filter { !$0.allSatisfy { $0 == "." } }
                    return parts.indices.contains { ignore.matches(parts[$0...].joined(separator: "/")) }
                }
            }
            if named { dropped += 1 }
            return !named
        }
        guard dropped > 0 else { return text }
        var out = kept.joined(separator: "\n")
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        return out + "(\(dropped) line\(dropped == 1 ? "" : "s") naming files excluded by .aiignore left out)"
    }

    /// A character a word of `droppingIgnoredLines` keeps: letters, digits and `/ . _ - ~ @ + \` (C-quoted bytes).
    private static func isPathCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "/._-~@+\\".contains(character)
    }

    /// Lock and generated files, by name: their contents are left out of AI requests (the header stays).
    static let skippedNames = [
        "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "Package.resolved", "Podfile.lock", "Cargo.lock",
        "Gemfile.lock", "composer.lock", "poetry.lock", "go.sum", "*.min.js", "*.min.css", "*.map", "*.pb.go",
        "*_generated.*", "*.g.dart", "*.designer.cs",
    ].map { $0.lowercased() }

    /// True when the file name of `path` is on the skip list (case-insensitively: `Form1.Designer.cs`).
    static func isLockOrGenerated(_ path: String) -> Bool {
        let name = (path.split(separator: "/").last.map(String.init) ?? path).lowercased()
        return skippedNames.contains { AIIgnore.glob($0, name) }
    }

    /// Every path a file of a diff (its lines from `splitFiles`) may have: the old and new names from the
    /// `rename`/`copy` and `---`/`+++` lines of its extended header (before the first `@@` or binary patch), else
    /// from its `diff --git`/`--cc`/`--combined` header. An unquoted `diff --git` header with spaces cannot be split
    /// for sure, so every split is returned.
    static func filePaths(_ lines: [Substring]) -> [String] {
        var paths: [String] = []
        func add(_ name: Data?) { if let name { paths.append(String(decoding: name, as: UTF8.self)) } }
        for line in lines.dropFirst() {
            if line.hasPrefix("@@") || line.hasPrefix("GIT binary patch") { break }
            for label in ["rename from ", "rename to ", "copy from ", "copy to "] where line.hasPrefix(label) {
                add(PathQuoting.name(Data(line.dropFirst(label.count).utf8)))
            }
            if line.hasPrefix("--- ") { add(PathQuoting.patchName(Data(line.dropFirst(4).utf8), prefix: "a/")) }
            if line.hasPrefix("+++ ") { add(PathQuoting.patchName(Data(line.dropFirst(4).utf8), prefix: "b/")) }
        }
        guard paths.isEmpty, let header = lines.first else { return paths }
        for label in ["diff --cc ", "diff --combined "] where header.hasPrefix(label) {
            add(PathQuoting.name(Data(header.dropFirst(label.count).utf8)))
            return paths
        }
        let rest = Data(header.dropFirst("diff --git ".count).utf8)
        if rest.first == UInt8(ascii: "\""), let (a, b) = PathQuoting.gitHeaderNames(rest) {
            add(a)
            add(b)
            return paths
        }
        for index in rest.indices where rest[index] == UInt8(ascii: " ") {
            add(PathQuoting.patchName(rest[..<index], prefix: "a/"))
            add(PathQuoting.patchName(rest[(index + 1)...], prefix: "b/"))
        }
        return paths
    }
}
