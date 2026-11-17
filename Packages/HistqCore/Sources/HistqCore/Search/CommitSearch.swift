// The graph's commit search (⌘F): which commits of the log a query finds, by message, subject and body (every word of
// the query, in any order; case- and diacritic-insensitive; spaces, line breaks, "-", "_" and "/" alike)
// or, for a query of 4 or more hex characters, by any part of the hash. Pure and synchronous, so the app runs it off the main
// actor. A per-commit Foundation compare costs about 1 µs (75 ms for 50,000 commits in a Debug build), so the messages
// are folded once into one byte buffer (`Index`, built once per log) and each query is a `memmem` scan of it.
import Foundation

public enum CommitSearch {
    /// The shortest query that also matches part of a hash: shorter hex strings hit too many messages' words and hashes.
    public static let minimumHashPrefix = 4

    /// A log's messages (subject and body) folded (lowercase, no diacritics, line breaks made spaces) and joined by
    /// newlines, with where each starts; and the hashes, fixed width. Build it once per log snapshot, off the main actor.
    public struct Index: Sendable {
        /// The folded messages, each followed by a newline.
        fileprivate let messages: [UInt8]
        /// `messages`' offset of each commit's message, in log order.
        fileprivate let starts: [Int]
        /// Every hash, lowercase, `hashWidth` bytes each (a shorter one is padded with NUL).
        fileprivate let hashes: [UInt8]
        fileprivate let hashWidth: Int

        /// The commits indexed.
        public var count: Int { starts.count }

        /// Indexes `commits`. A cancelled task gets an empty index.
        public init(_ commits: [Commit]) {
            var messages: [UInt8] = []
            messages.reserveCapacity(commits.count * 64)
            var starts: [Int] = []
            starts.reserveCapacity(commits.count)
            let hashWidth = commits.first?.hash.utf8.count ?? 40
            var hashes: [UInt8] = []
            hashes.reserveCapacity(commits.count * hashWidth)
            for (index, commit) in commits.enumerated() {
                if index.isMultiple(of: 1024), Task.isCancelled {
                    self.init(messages: [], starts: [], hashes: [], hashWidth: hashWidth)
                    return
                }
                starts.append(messages.count)
                CommitSearch.appendFolded(commit.subject, to: &messages)
                if !commit.body.isEmpty {
                    messages.append(0x20)
                    CommitSearch.appendFolded(commit.body, to: &messages)
                }
                messages.append(0x0A)
                // git writes hashes in lowercase; every hash of a repo has the same width (SHA-1 or SHA-256).
                let hash = commit.hash.utf8.prefix(hashWidth)
                hashes.append(contentsOf: hash)
                if hash.count < hashWidth { hashes.append(contentsOf: repeatElement(0, count: hashWidth - hash.count)) }
            }
            self.init(messages: messages, starts: starts, hashes: hashes, hashWidth: hashWidth)
        }

        private init(messages: [UInt8], starts: [Int], hashes: [UInt8], hashWidth: Int) {
            self.messages = messages
            self.starts = starts
            self.hashes = hashes
            self.hashWidth = hashWidth
        }
    }

    /// The indices into `commits` of the commits `query` finds, in log order, each once: the message (subject and
    /// body) contains every word of the trimmed query, in any order (case- and diacritic-insensitive), or the query is at least `minimumHashPrefix` hex characters
    /// and the hash contains it (anywhere, not only at its start). An empty or whitespace-only query finds nothing. A cancelled task gets an empty
    /// list. Searching a log more than once: build its `Index` once and use `matches(in:query:)`.
    public static func matches(_ commits: [Commit], query: String) -> [Int] {
        matches(in: Index(commits), query: query)
    }

    /// `matches(_:query:)` on an index of the commits.
    public static func matches(in index: Index, query: String) -> [Int] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        let byMessage = messageMatches(in: index, needle: needle)
        let isHash = needle.count >= minimumHashPrefix && needle.allSatisfy(\.isHexDigit)
        guard isHash, !Task.isCancelled else { return Task.isCancelled ? [] : byMessage }
        return merged(byMessage, hashMatches(in: index, part: Array(needle.lowercased().utf8)))
    }

    /// The commits whose folded message contains every word of the folded `needle`, in any order and each anywhere
    /// (also inside a longer word), as GitKraken: "update lib" finds "Refactored imports from lib updates".
    private static func messageMatches(in index: Index, needle: String) -> [Int] {
        var folded: [UInt8] = []
        appendFolded(needle, to: &folded)
        let words = folded.split(separator: 0x20)
        guard let first = words.first else { return [] }
        var found = wordMatches(in: index, word: Array(first))
        for word in words.dropFirst() where !found.isEmpty {
            let hits = Set(wordMatches(in: index, word: Array(word)))
            found = found.filter(hits.contains)
        }
        return Task.isCancelled ? [] : found
    }

    /// The commits whose folded message contains `word` (which holds no newline, so a hit never spans two messages):
    /// one `memmem` per hit, the next search starting at the next message, so a message counts once.
    private static func wordMatches(in index: Index, word: [UInt8]) -> [Int] {
        var found: [Int] = []
        index.messages.withUnsafeBytes { haystack in
            word.withUnsafeBytes { pattern in
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

    /// The commits whose hash contains `part` (lowercase bytes): one `memmem` per hash, so a hit never spans two.
    private static func hashMatches(in index: Index, part: [UInt8]) -> [Int] {
        guard part.count <= index.hashWidth else { return [] }
        var found: [Int] = []
        index.hashes.withUnsafeBytes { hashes in
            part.withUnsafeBytes { pattern in
                guard let base = hashes.baseAddress, let patternBase = pattern.baseAddress else { return }
                for commit in 0..<index.count
                where memmem(base + commit * index.hashWidth, index.hashWidth, patternBase, pattern.count) != nil {
                    found.append(commit)
                }
            }
        }
        return found
    }

    /// The commit whose message holds byte `position`: the last start at or before it.
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

    /// Appends `text` lowercased and without diacritics, as UTF-8: an ASCII text byte by byte (most messages), any
    /// other through Foundation's folding. Each run of word separators (spaces, tabs, line breaks, `-`, `_`, `/`) becomes one
    /// space, so "urgent fix", "urgent-fix" and "URGENT_fix" find each other, as in GitKraken.
    fileprivate static func appendFolded(_ text: String, to bytes: inout [UInt8]) {
        let start = bytes.count
        bytes.append(contentsOf: text.utf8)
        guard !normalize(&bytes, from: start, asciiOnly: true) else { return }
        bytes.removeSubrange(start...)
        bytes.append(contentsOf: text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).utf8)
        normalize(&bytes, from: start, asciiOnly: false)
    }

    /// Lowercases the ASCII letters of `bytes` from `start` and turns each run of separators into one space, in place
    /// (a pointer loop: this runs for every commit, in Debug builds too). With `asciiOnly`, stops at the first
    /// non-ASCII byte and returns false (the bytes are then half done); else keeps such bytes as they are.
    @discardableResult
    private static func normalize(_ bytes: inout [UInt8], from start: Int, asciiOnly: Bool) -> Bool {
        let kept: Int? = bytes.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return start }
            var read = base + start
            var write = read
            let end = base + buffer.count
            var afterSeparator = false
            while read < end {
                let byte = read.pointee
                read += 1
                if byte >= 0x80, asciiOnly { return nil }
                // Space, tab, line feed, carriage return, "-", "_", "/".
                if byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x2D || byte == 0x5F
                    || byte == 0x2F {
                    if afterSeparator { continue }
                    afterSeparator = true
                    write.pointee = 0x20
                } else {
                    afterSeparator = false
                    write.pointee = byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte
                }
                write += 1
            }
            return base.distance(to: write)
        }
        guard let kept else { return false }
        bytes.removeSubrange(kept...)
        return true
    }
}
