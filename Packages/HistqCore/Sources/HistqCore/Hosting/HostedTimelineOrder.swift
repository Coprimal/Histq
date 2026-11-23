// The Conversation timeline's order: general comments, reviews, inline threads and history entries (system notes,
// state, label and milestone changes) in one list by time, each general comment's replies grouped under it. Pure: the detail runs it off the main actor while it builds the page, and the
// description (always first) is the app's.
import Foundation

public enum HostedTimelineOrder {
    /// A reply under a general root, `depth` 1 for a direct reply, 2 for a reply to that reply, and so on.
    public struct Reply: Sendable, Equatable {
        public let comment: HostedComment
        public let depth: Int
    }

    public enum Entry: Sendable, Equatable {
        /// A general root and its replies, each after the one it answers (siblings oldest first).
        case comment(HostedComment, replies: [Reply])
        /// A shown review and its threads, oldest root first.
        case review(HostedReview, threads: [HostedReviewThread])
        /// A thread of no shown review (a GitLab or Bitbucket thread, a pending GitHub review's), at its first
        /// comment's time.
        case thread(HostedReviewThread)
        /// A history entry (`HostedTimelineEvent`), at its date.
        case event(HostedTimelineEvent)
    }

    /// The entries by time: a general root at its date, a review at its submission, a thread of no shown review at
    /// its first comment's, a history entry at its date. Equal times go comments, then reviews, then threads, then
    /// entries, each by id, and a missing date
    /// counts as the earliest, so the same answer always gives the same order. A thread whose `reviewID` is one of
    /// `reviews` (the shown ones, the caller's choice) goes under it. A general comment with a `parentID` goes under
    /// its parent; one whose parent is not in `comments` is a root, so no comment is ever dropped.
    public static func entries(
        comments: [HostedComment], reviews: [HostedReview], threads: [HostedReviewThread],
        events: [HostedTimelineEvent] = []
    ) -> [Entry] {
        let ids = Set(comments.map(\.id))
        var children: [Int: [HostedComment]] = [:]
        var roots: [HostedComment] = []
        for comment in comments {
            if let parent = comment.parentID, parent != comment.id, ids.contains(parent) {
                children[parent, default: []].append(comment)
            } else {
                roots.append(comment)
            }
        }
        for parent in children.keys {
            children[parent]?.sort { key(of: $0) < key(of: $1) }
        }
        // Depth first, each reply after the one it answers; `seen` guards against a parent loop.
        var seen = Set<Int>()
        func replies(of id: Int, depth: Int) -> [Reply] {
            (children[id] ?? []).flatMap { child -> [Reply] in
                guard seen.insert(child.id).inserted else { return [] }
                return [Reply(comment: child, depth: depth)] + replies(of: child.id, depth: depth + 1)
            }
        }
        var keyed: [(key: SortKey, entry: Entry)] = roots.map { root in
            seen.insert(root.id)
            return (SortKey(date: root.createdAt, rank: 0, id: root.id),
                    .comment(root, replies: replies(of: root.id, depth: 1)))
        }
        // A loop of replies has no root: its earliest comment heads it.
        for comment in comments.sorted(by: { key(of: $0) < key(of: $1) }) where !seen.contains(comment.id) {
            seen.insert(comment.id)
            keyed.append((SortKey(date: comment.createdAt, rank: 0, id: comment.id),
                          .comment(comment, replies: replies(of: comment.id, depth: 1))))
        }

        let shown = Set(reviews.map(\.id))
        var byReview: [Int: [HostedReviewThread]] = [:]
        for thread in threads {
            if let review = thread.reviewID, shown.contains(review) {
                byReview[review, default: []].append(thread)
            } else {
                keyed.append((SortKey(date: thread.comments.first?.createdAt, rank: 2, id: thread.id),
                              .thread(thread)))
            }
        }
        for review in reviews {
            let threads = (byReview[review.id] ?? []).sorted { threadKey($0) < threadKey($1) }
            keyed.append((SortKey(date: review.submittedAt, rank: 1, id: review.id),
                          .review(review, threads: threads)))
        }
        for event in events {
            keyed.append((SortKey(date: event.createdAt, rank: 3, id: 0, key: event.id), .event(event)))
        }
        return keyed.sorted { $0.key < $1.key }.map(\.entry)
    }

    private struct SortKey: Comparable {
        let date: Date?
        /// Comments 0, reviews 1, threads 2, entries 3.
        let rank: Int
        let id: Int
        /// An entry's id (the others' is `id`).
        var key = ""

        static func < (a: Self, b: Self) -> Bool {
            (a.date ?? .distantPast, a.rank, a.id, a.key) < (b.date ?? .distantPast, b.rank, b.id, b.key)
        }
    }

    private static func key(of comment: HostedComment) -> SortKey {
        SortKey(date: comment.createdAt, rank: 0, id: comment.id)
    }

    private static func threadKey(_ thread: HostedReviewThread) -> SortKey {
        SortKey(date: thread.comments.first?.createdAt, rank: 2, id: thread.id)
    }
}
