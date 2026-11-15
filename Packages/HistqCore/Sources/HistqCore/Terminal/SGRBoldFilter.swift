// Removes the bold attribute from a terminal's output stream (Settings › Terminal "Bold text" off), so bold text is
// drawn in the normal weight. Only a complete `ESC [ <params> m` whose parameters are digits, `;` and `:` is rewritten:
// its top-level parameter 1 (also written `01`) goes, everything else stays byte for byte. A `1` after 38/48/58 is a
// color index or component (`38;5;1`, `38;2;r;g;b`; the colon forms are one token) and stays. A sequence left without
// parameters becomes `ESC \` (ST, a no-op), never `ESC[m`, which would reset every attribute, and never nothing, since
// its ESC may end an open string. Every other byte, and every other sequence
// (`ESC[1A`, `ESC[>4;1m`), passes unchanged.

/// A stateful filter over consecutive chunks of terminal output: a sequence cut between two chunks is held back
/// (at most `maxPending` bytes, then passed through unchanged) and finished with the next chunk.
public struct SGRBoldFilter: Sendable {
    /// The longest escape sequence held back; a longer one passes through unchanged.
    public static let maxPending = 64

    private var pending: [UInt8] = []

    public init() {}

    /// `chunk` with the bold attribute removed; a sequence cut at its end is kept for the next call.
    public mutating func filter(_ chunk: ArraySlice<UInt8>) -> [UInt8] {
        if pending.isEmpty, !chunk.contains(Self.esc) { return Array(chunk) }
        var output: [UInt8] = []
        output.reserveCapacity(chunk.count + pending.count)
        for byte in chunk { consume(byte, into: &output) }
        return output
    }

    /// The bytes held back, unchanged, emptying the filter (the filter is turned off, or the stream ends).
    public mutating func flush() -> [UInt8] {
        defer { pending = [] }
        return pending
    }

    private static let esc: UInt8 = 0x1B
    private static let bracket = UInt8(ascii: "[")

    private mutating func consume(_ byte: UInt8, into output: inout [UInt8]) {
        if pending.isEmpty {
            if byte == Self.esc { pending.append(byte) } else { output.append(byte) }
            return
        }
        if pending.count == 1 {
            guard byte == Self.bracket else {
                // Not a CSI: the escape goes out as it came, and this byte is read afresh (it may start another).
                output.append(contentsOf: flush())
                consume(byte, into: &output)
                return
            }
            pending.append(byte)
            return
        }
        switch byte {
        case 0x20...0x3F:
            // Parameter and intermediate bytes.
            pending.append(byte)
            if pending.count > Self.maxPending { output.append(contentsOf: flush()) }
        case 0x40...0x7E:
            // The final byte.
            pending.append(byte)
            output.append(contentsOf: Self.rewritten(flush()))
        default:
            // A control byte inside the sequence: what was held goes out unchanged; the byte is read afresh.
            output.append(contentsOf: flush())
            consume(byte, into: &output)
        }
    }

    /// `sequence` (a complete CSI, `ESC [` … final byte) without its bold parameter, or unchanged.
    private static func rewritten(_ sequence: [UInt8]) -> [UInt8] {
        guard sequence.last == UInt8(ascii: "m") else { return sequence }
        let parameters = sequence[2..<(sequence.count - 1)]
        let separators: Set<UInt8> = [UInt8(ascii: ";"), UInt8(ascii: ":")]
        guard parameters.allSatisfy({ (0x30...0x39).contains($0) || separators.contains($0) }) else { return sequence }
        let tokens = parameters.split(separator: UInt8(ascii: ";"), omittingEmptySubsequences: false)
        var kept: [ArraySlice<UInt8>] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            let value = number(token)
            if value == 1 {
                index += 1
                continue
            }
            // An extended color: its sub-parameters (`5;n` or `2;r;g;b`) are kept with it.
            var length = 1
            if value == 38 || value == 48 || value == 58, index + 1 < tokens.count {
                switch number(tokens[index + 1]) {
                case 5: length = 3
                case 2: length = 5
                default: break
                }
            }
            let end = min(index + length, tokens.count)
            kept.append(contentsOf: tokens[index..<end])
            index = end
        }
        guard kept.count < tokens.count else { return sequence }
        // Only bold was there (`ESC[1m`): send `ESC \` (ST, a no-op) in its place, never nothing. Its ESC still does
        // what the original's did: it ends an open OSC or DCS string, and pairs with a stray ESC before it.
        guard !kept.isEmpty else { return [esc, UInt8(ascii: "\\")] }
        var result: [UInt8] = [esc, bracket]
        for (position, token) in kept.enumerated() {
            if position > 0 { result.append(UInt8(ascii: ";")) }
            result.append(contentsOf: token)
        }
        result.append(UInt8(ascii: "m"))
        return result
    }

    /// The token's value when it is digits only (a colon form such as `38:5:1` is not a number); nil otherwise.
    private static func number(_ token: ArraySlice<UInt8>) -> Int? {
        guard !token.isEmpty, token.count <= 5, token.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return token.reduce(0) { $0 * 10 + Int($1 - 0x30) }
    }
}
