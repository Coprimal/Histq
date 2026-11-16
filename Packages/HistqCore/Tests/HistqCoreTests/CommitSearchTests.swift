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
