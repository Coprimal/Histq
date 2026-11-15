// The terminal's "Bold text" off: the bold SGR parameter leaves the output, nothing else changes (colors that use 1 as
// an index, cursor moves, private sequences), also when a sequence is cut between two reads of the pty.
import HistqCore
import Testing

struct SGRBoldFilterTests {
    private func filtered(_ chunks: String...) -> String {
        var filter = SGRBoldFilter()
        let bytes = chunks.flatMap { filter.filter(Array($0.utf8)[...]) } + filter.flush()
        return String(decoding: bytes, as: UTF8.self)
    }

    @Test("bold leaves a sequence with other parameters: ESC[1;31m → ESC[31m, ESC[01;34m → ESC[34m")
    func boldRemovedFromParameters() {
        #expect(filtered("a\u{1B}[1;31mred\u{1B}[0m") == "a\u{1B}[31mred\u{1B}[0m")
        #expect(filtered("\u{1B}[01;34mdir") == "\u{1B}[34mdir")
        #expect(filtered("\u{1B}[0;1m") == "\u{1B}[0m")
    }

    @Test("a sequence of bold alone becomes ESC \\ (a no-op), never ESC[m (which resets every attribute) nor nothing")
    func boldOnlyBecomesNoOp() {
        #expect(filtered("\u{1B}[1mbold") == "\u{1B}\\bold")
        // Its ESC still ends an open OSC string, so the text after it stays text, not part of the title.
        #expect(filtered("\u{1B}]0;t\u{1B}[1mx") == "\u{1B}]0;t\u{1B}\\x")
    }

    @Test("a 1 inside an extended color stays: ESC[38;5;1m, ESC[1;38;2;1;1;1m, ESC[38:5:1m")
    func extendedColorKept() {
        #expect(filtered("\u{1B}[38;5;1m") == "\u{1B}[38;5;1m")
        #expect(filtered("\u{1B}[1;38;2;1;1;1m") == "\u{1B}[38;2;1;1;1m")
        #expect(filtered("\u{1B}[38:5:1;1m") == "\u{1B}[38:5:1m")
    }

    @Test("other sequences pass unchanged: cursor moves, private modes, 22, a plain reset")
    func otherSequencesUnchanged() {
        for text in ["\u{1B}[1A", "\u{1B}[1;5H", "\u{1B}[>4;1m", "\u{1B}[?1h", "\u{1B}[22m", "\u{1B}[m", "\u{1B}(B1"] {
            #expect(filtered(text) == text)
        }
    }

    @Test("a sequence cut between two chunks is held back and filtered whole")
    func splitAcrossChunks() {
        #expect(filtered("x\u{1B}[1;3", "2my") == "x\u{1B}[32my")
        #expect(filtered("x\u{1B}", "[1mz") == "x\u{1B}\\z")
        var filter = SGRBoldFilter()
        #expect(filter.filter(Array("a\u{1B}[1".utf8)[...]) == Array("a".utf8))
        #expect(filter.flush() == Array("\u{1B}[1".utf8))
    }

    @Test("a sequence longer than the bound passes through unchanged")
    func overlongSequencePassesThrough() {
        let long = "\u{1B}[" + String(repeating: "1;", count: 40) + "m"
        #expect(filtered(long) == long)
    }
}
