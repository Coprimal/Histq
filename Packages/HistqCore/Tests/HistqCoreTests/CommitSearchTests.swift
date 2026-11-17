// Key feature test for the graph's commit search (task 4.1): a subject matches whatever its case, and a hash prefix
// (or any other part of it) finds its commit from 4 hex characters on, never from 3.
import Foundation
import HistqCore
import Testing

struct CommitSearchTests {
    private static func commit(_ hash: String, _ subject: String) -> Commit {
        Commit(hash: hash, parents: [], authorName: "Jane", authorEmail: "jane@example.com",
               authorDate: Date(timeIntervalSince1970: 0), committerDate: Date(timeIntervalSince1970: 0),
               subject: subject, body: "")
    }

    @Test("A subject matches regardless of case, in log order")
    func subjectMatchIgnoresCase() {
        let commits = [
            Self.commit("1111111111111111111111111111111111111111", "Series step 2"),
            Self.commit("2222222222222222222222222222222222222222", "Add config"),
            Self.commit("3333333333333333333333333333333333333333", "SERIES finale"),
        ]
        #expect(CommitSearch.matches(commits, query: "series") == [0, 2])
    }

    @Test("Spaces, tabs, -, _ and / match each other, a run of them as one")
    func separatorsMatchEachOther() {
        let commits = [
            Self.commit("1111111111111111111111111111111111111111",
                        "Merge pull request #79 from IdetaAutomation/urgent-fix-conv-url-in-cluster"),
            Self.commit("2222222222222222222222222222222222222222", "Urgent  fix for the café"),
            Self.commit("3333333333333333333333333333333333333333", "Urgent release"),
        ]
        #expect(CommitSearch.matches(commits, query: "urgent fix") == [0, 1])
        #expect(CommitSearch.matches(commits, query: "URGENT_fix") == [0, 1])
        #expect(CommitSearch.matches(commits, query: "automation urgent") == [0])
        #expect(CommitSearch.matches(commits, query: "fix-for the cafe") == [1])
    }

    @Test("Every word of the query must be in the subject, in any order, also inside a longer word")
    func everyWordInAnyOrder() {
        let commits = [
            Self.commit("1111111111111111111111111111111111111111", "Refactored imports from lib updates"),
            Self.commit("2222222222222222222222222222222222222222", "Update lib versions"),
            Self.commit("3333333333333333333333333333333333333333", "Update docs"),
            Self.commit("4444444444444444444444444444444444444444", "Move library code"),
        ]
        #expect(CommitSearch.matches(commits, query: "update lib") == [0, 1])
        #expect(CommitSearch.matches(commits, query: "lib  update") == [0, 1])
        #expect(CommitSearch.matches(commits, query: "update lib docs").isEmpty)
        #expect(CommitSearch.matches(commits, query: "lib") == [0, 1, 3])
    }

    @Test("The body is searched too, its line breaks as spaces, a word never spanning two commits")
    func bodyIsSearched() {
        let commits = [
            Commit(hash: "1111111111111111111111111111111111111111", parents: [], authorName: "Jane",
                   authorEmail: "jane@example.com", authorDate: Date(timeIntervalSince1970: 0),
                   committerDate: Date(timeIntervalSince1970: 0), subject: "Fix crash",
                   body: "The cluster URL was wrong.\n\nConv\nurl now built per cluster."),
            Self.commit("2222222222222222222222222222222222222222", "Add docs"),
        ]
        #expect(CommitSearch.matches(commits, query: "cluster url") == [0])
        #expect(CommitSearch.matches(commits, query: "conv url") == [0])
        #expect(CommitSearch.matches(commits, query: "crash cluster") == [0])
        #expect(CommitSearch.matches(commits, query: "cluster docs").isEmpty)
    }

    @Test("4 hex characters find the commit by hash prefix; 3 do not")
    func hashPrefixNeedsFourCharacters() {
        let commits = [
            Self.commit("5a5baf0c0ffee000000000000000000000000000", "Polish feature"),
            Self.commit("af780d0000000000000000000000000000000000", "Update changelog"),
        ]
        #expect(CommitSearch.matches(commits, query: "5a5b") == [0])
        #expect(CommitSearch.matches(commits, query: "5a5").isEmpty)
    }

    @Test("4 hex characters find the commit by any part of its hash, not only its start")
    func hashPartMatchesAnywhere() {
        let commits = [
            Self.commit("5a5baf0c0ffee000000000000000000000000000", "Polish feature"),
            Self.commit("af780d0000000000000000000000000000000000", "Update changelog"),
            Self.commit("00000000000000000000000000000000c0ffee12", "Release"),
        ]
        #expect(CommitSearch.matches(commits, query: "c0ffee") == [0, 2])
        #expect(CommitSearch.matches(commits, query: "780D") == [1])
        #expect(CommitSearch.matches(commits, query: "ee12") == [2])
    }
}
