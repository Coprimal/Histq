import Foundation
import HistqCore
import Testing

struct HostedTimelineOrderTests {
    @Test("one list by time: threads of no shown review at their first comment's time, a fixed tie order, general replies nested under their root at any depth")
    func orderAndNesting() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        func at(_ time: String) -> String { "\"created_at\": \"2026-11-12T\(time):00Z\"" }
        // General comments (Bitbucket-like): 801 → 806 → 807 and 801 → 808, a deleted-style root 809 with reply
        // 810, 805, a reply 830 whose parent is not in the answer (a root then), and 840 without a date (the
        // earliest).
        let parents = [806: 801, 807: 806, 808: 801, 810: 809, 830: 999]
        var comments = try decoder.decode([HostedComment].self, from: Data("""
            [{"id": 807, \(at("14:20"))}, {"id": 805, \(at("15:30"))}, {"id": 801, \(at("14:00"))},
             {"id": 806, \(at("14:10"))}, {"id": 830, \(at("15:40"))}, {"id": 810, \(at("15:10"))},
             {"id": 809, \(at("15:00"))}, {"id": 808, \(at("14:05"))}, {"id": 840}]
            """.utf8))
        for index in comments.indices { comments[index].parentID = parents[comments[index].id] }
        // Reviews 701 and 703 are shown; 702 and 704 (pending, say) are not.
        let reviews = try decoder.decode([HostedReview].self, from: Data("""
            [{"id": 703, "state": "COMMENTED", "submitted_at": "2026-11-12T15:30:00Z"},
             {"id": 701, "state": "APPROVED", "submitted_at": "2026-11-12T15:00:00Z"}]
            """.utf8))
        // Threads: 811 with no review (and reply 812), 813 of hidden review 702, 10 of shown 701, 20 of hidden 704.
        let reviewComments = try decoder.decode([HostedReviewComment].self, from: Data("""
            [{"id": 812, "in_reply_to_id": 811, "path": "a", \(at("15:20"))},
             {"id": 811, "path": "a", \(at("14:55"))},
             {"id": 813, "pull_request_review_id": 702, "path": "a", \(at("14:57"))},
             {"id": 10, "pull_request_review_id": 701, "path": "b", \(at("14:56"))},
             {"id": 20, "pull_request_review_id": 704, "path": "c", \(at("15:30"))}]
            """.utf8))
        let grouped = HostedReviewThread.group(reviewComments, states: [])
        let threads = grouped.threadsByReview.values.flatMap { $0 } + grouped.unattached

        func describe(_ entries: [HostedTimelineOrder.Entry]) -> [String] {
            entries.map { entry in
                switch entry {
                case .comment(let root, let replies):
                    "c\(root.id)" + replies.map { " \($0.comment.id)/\($0.depth)" }.joined()
                case .review(let review, let threads): "r\(review.id)" + threads.map { " t\($0.id)" }.joined()
                case .thread(let thread):
                    "t\(thread.id) " + thread.comments.map { String($0.id) }.joined(separator: ",")
                case .event(let event): "e-" + event.id
                }
            }
        }
        let expected = [
            "c840",
            "c801 808/1 806/1 807/2",
            "t811 811,812",
            "t813 813",
            // 15:00: the comment before the review.
            "c809 810/1",
            "r701 t10",
            // 15:30: comment, review, thread.
            "c805",
            "r703",
            "t20 20",
            "c830",
        ]
        #expect(describe(HostedTimelineOrder.entries(comments: comments, reviews: reviews, threads: threads))
            == expected)
        // The input's order never changes the answer.
        #expect(describe(HostedTimelineOrder.entries(
            comments: comments.reversed(), reviews: reviews.reversed(), threads: threads.reversed())) == expected)

        // History entries go in at their date, after a comment, review and thread of the same time (then by id), a
        // dateless one with the earliest (after a dateless comment); the others keep their order.
        func event(_ id: String, _ time: String?) -> HostedTimelineEvent {
            HostedTimelineEvent(
                id: id, actor: nil, createdAt: time.flatMap { ISO8601DateFormatter().date(from: "2026-11-12T\($0):00Z") },
                text: id)
        }
        let events = [event("s3", "15:30"), event("s1", "14:02"), event("s0", nil), event("s2", "15:30"),
                      event("s4", "16:00")]
        let withEvents = [
            "c840", "e-s0",
            "c801 808/1 806/1 807/2",
            "e-s1",
            "t811 811,812",
            "t813 813",
            "c809 810/1",
            "r701 t10",
            "c805",
            "r703",
            "t20 20",
            "e-s2", "e-s3",
            "c830",
            "e-s4",
        ]
        #expect(describe(HostedTimelineOrder.entries(
            comments: comments, reviews: reviews, threads: threads, events: events)) == withEvents)
        #expect(describe(HostedTimelineOrder.entries(
            comments: comments.reversed(), reviews: reviews.reversed(), threads: threads.reversed(),
            events: events.reversed())) == withEvents)
    }

    @Test("pending first: the threads whose root is a pending comment move to the front in their order, the rest keep theirs; a pending reply in a published thread leaves it in place")
    func pendingFirst() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var comments = try decoder.decode([HostedReviewComment].self, from: Data("""
            [{"id": 10, "path": "a", "created_at": "2026-11-12T10:00:00Z"},
             {"id": 11, "in_reply_to_id": 10, "path": "a", "created_at": "2026-11-12T13:00:00Z"},
             {"id": 20, "path": "b", "created_at": "2026-11-12T12:00:00Z"},
             {"id": 30, "path": "c", "created_at": "2026-11-12T11:00:00Z"}]
            """.utf8))
        // 11 (a pending reply into published thread 10) and roots 20, 30 are pending.
        for index in comments.indices where comments[index].id != 10 { comments[index].isPending = true }
        let general = try decoder.decode([HostedComment].self, from: Data("""
            [{"id": 5, "created_at": "2026-11-12T09:00:00Z"}, {"id": 6, "created_at": "2026-11-12T14:00:00Z"}]
            """.utf8))
        let threads = HostedReviewThread.group(comments, states: []).unattached
        func describe(_ entries: [HostedTimelineOrder.Entry]) -> [String] {
            entries.map { entry in
                switch entry {
                case .comment(let root, _): "c\(root.id)"
                case .thread(let thread): "t\(thread.id)"
                case .review(let review, _): "r\(review.id)"
                case .event(let event): "e-" + event.id
                }
            }
        }
        let entries = HostedTimelineOrder.entries(comments: general, reviews: [], threads: threads)
        #expect(describe(entries) == ["c5", "t10", "t30", "t20", "c6"])
        #expect(describe(HostedTimelineOrder.pendingFirst(entries)) == ["t30", "t20", "c5", "t10", "c6"])
        #expect(describe(HostedTimelineOrder.pendingFirst(entries.reversed())) == ["t20", "t30", "c6", "t10", "c5"])
        let published = HostedTimelineOrder.entries(comments: general, reviews: [], threads: [])
        #expect(HostedTimelineOrder.pendingFirst(published) == published)
    }
}
