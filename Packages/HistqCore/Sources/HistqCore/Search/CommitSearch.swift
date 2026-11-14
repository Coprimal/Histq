// The graph's commit search (⌘F): which commits of the log a query finds, by subject (case- and diacritic-insensitive)
// or, for a query of 4 or more hex characters, by hash prefix. Pure and synchronous, so the app runs it off the main
// actor. A per-commit Foundation compare costs about 1 µs (75 ms for 50,000 commits in a Debug build), so the subjects
// are folded once into one byte buffer (`Index`, built once per log) and each query is a `memmem` scan of it.
import Foundation

public enum CommitSearch {
    /// The shortest query that also matches hash prefixes: shorter hex strings hit too many subjects' words and hashes.
    public static let minimumHashPrefix = 4

    /// A log's subjects folded (lowercase, no diacritics) and joined by newlines, which a subject never holds, with
    /// where each starts; and the hashes, fixed width. Build it once per log snapshot, off the main actor.
    public struct Index: Sendable {
        /// The folded subjects, each followed by a newline.
        fileprivate let subjects: [UInt8]
        /// `subjects`' offset of each commit's subject, in log order.
        fileprivate let starts: [Int]
        /// Every hash, lowercase, `hashWidth` bytes each (a shorter one is padded with NUL).
        fileprivate let hashes: [UInt8]
        fileprivate let hashWidth: Int

        /// The commits indexed.
        public var count: Int { starts.count }

        /// Indexes `commits`. A cancelled task gets an empty index.
        public init(_ commits: [Commit]) {
            var subjects: [UInt8] = []
            subjects.reserveCapacity(commits.count * 48)
            var starts: [Int] = []
            starts.reserveCapacity(commits.count)
            let hashWidth = commits.first?.hash.utf8.count ?? 40
            var hashes: [UInt8] = []
            hashes.reserveCapacity(commits.count * hashWidth)
            for (index, commit) in commits.enumerated() {
                if index.isMultiple(of: 1024), Task.isCancelled {
                    self.init(subjects: [], starts: [], hashes: [], hashWidth: hashWidth)
                    return
                }
                starts.append(subjects.count)
                CommitSearch.appendFolded(commit.subject, to: &subjects)
                subjects.append(0x0A)
                // git writes hashes in lowercase; every hash of a repo has the same width (SHA-1 or SHA-256).
                let hash = commit.hash.utf8.prefix(hashWidth)
                hashes.append(contentsOf: hash)
                if hash.count < hashWidth { hashes.append(contentsOf: repeatElement(0, count: hashWidth - hash.count)) }
            }
            self.init(subjects: subjects, starts: starts, hashes: hashes, hashWidth: hashWidth)
        }

        private init(subjects: [UInt8], starts: [Int], hashes: [UInt8], hashWidth: Int) {
            self.subjects = subjects
            self.starts = starts
            self.hashes = hashes
            self.hashWidth = hashWidth
        }
    }

    /// The indices into `commits` of the commits `query` finds, in log order, each once: the subject contains the
    /// trimmed query (case- and diacritic-insensitive), or the query is at least `minimumHashPrefix` hex characters
    /// and the hash starts with it. An empty or whitespace-only query finds nothing. A cancelled task gets an empty
    /// list. Searching a log more than once: build its `Index` once and use `matches(in:query:)`.
    public static func matches(_ commits: [Commit], query: String) -> [Int] {
        matches(in: Index(commits), query: query)
    }

    /// `matches(_:query:)` on an index of the commits.
    public static func matches(in index: Index, query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let bySubject = subjectMatches(in: index, needle: needle)
        let isHash = needle.count >= minimumHashPrefix && needle.allSatisfy(\.isHexDigit)
        guard isHash, !Task.isCancelled else { return Task.isCancelled ? [] : bySubject }
        return merged(bySubject, hashMatches(in: index, prefix: Array(needle.lowercased().utf8)))
    }

    /// The commits whose folded subject contains the folded `needle`: one `memmem` per hit, the next search starting
    /// at the next subject, so a subject counts once.
    private static func subjectMatches(in index: Index, needle: String) -> [Int] {
        var folded: [UInt8] = []
        appendFolded(needle, to: &folded)
        // A subject has no newline: a query with one finds no subject (and must not match across two).
        guard !folded.isEmpty, !folded.contains(0x0A) else { return [] }
        var found: [Int] = []
        index.subjects.withUnsafeBytes { haystack in
            folded.withUnsafeBytes { pattern in
                guard let base = haystack.baseAddress, let patternBase = pattern.baseAddress else { return }
                var offset = 0
                while offset < haystack.count {
                    if found.count.isMultiple(of: 1024), Task.isCancelled {
                        found = []
                        return
                    }
                    guard let hit = memmem(base + offset, haystack.count - offset, patternBase, pattern.count) else { break }
                    let position = base.distance(to: UnsafeRawPointer(hit))
                    let commit = commitIndex(at: position, starts: index.starts)
                    found.append(commit)
                    offset = commit + 1 < index.starts.count ? index.starts[commit + 1] : haystack.count
                }
            }
        }
        return found
    }

    /// The commits whose hash starts with `prefix` (lowercase bytes).
    private static func hashMatches(in index: Index, prefix: [UInt8]) -> [Int] {
        guard prefix.count <= index.hashWidth else { return [] }
        var found: [Int] = []
        index.hashes.withUnsafeBytes { hashes in
            prefix.withUnsafeBytes { pattern in
                guard let base = hashes.baseAddress, let patternBase = pattern.baseAddress else { return }
                for commit in 0..<index.count where memcmp(base + commit * index.hashWidth, patternBase, pattern.count) == 0 {
                    found.append(commit)
                }
            }
        }
        return found
    }

    /// The commit whose subject holds byte `position`: the last start at or before it.
    private static func commitIndex(at position: Int, starts: [Int]) -> Int {
        var low = 0
        var high = starts.count
        while high - low > 1 {
            let middle = (low + high) / 2
            if starts[middle] <= position { low = middle } else { high = middle }
        }
        return low
    }

    /// Two ascending index lists as one, each index once.
    private static func merged(_ lhs: [Int], _ rhs: [Int]) -> [Int] {
        guard !rhs.isEmpty else { return lhs }
        guard !lhs.isEmpty else { return rhs }
        var result: [Int] = []
        result.reserveCapacity(lhs.count + rhs.count)
        var left = 0
        var right = 0
        while left < lhs.count || right < rhs.count {
            if right == rhs.count || (left < lhs.count && lhs[left] < rhs[right]) {
                result.append(lhs[left])
                left += 1
            } else {
                if left < lhs.count, lhs[left] == rhs[right] { left += 1 }
                result.append(rhs[right])
                right += 1
            }
        }
        return result
    }

    /// Appends `text` lowercased and without diacritics, as UTF-8: an ASCII text byte by byte (most subjects), any
    /// other through Foundation's folding.
    /// Copies the bytes, then lowercases them in place (a pointer loop: this runs for every commit, in Debug builds
    /// too).
    fileprivate static func appendFolded(_ text: String, to bytes: inout [UInt8]) {
        let start = bytes.count
        bytes.append(contentsOf: text.utf8)
        let isASCII = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return true }
            var pointer = base + start
            let end = base + buffer.count
            while pointer < end {
                let byte = pointer.pointee
                if byte >= 0x80 { return false }
                if byte >= 0x41, byte <= 0x5A { pointer.pointee = byte | 0x20 }
                pointer += 1
            }
            return true
        }
        guard !isASCII else { return }
        bytes.removeSubrange(start...)
        bytes.append(contentsOf: text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
    }
}
