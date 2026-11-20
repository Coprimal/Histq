// Groups a pull request's inline review comments (REST) into the threads GitHub shows under each review, and joins
// each thread's resolved state (GraphQL) to them. Pure: the detail model runs it off the main actor once both parts
// are loaded, and a missing state only leaves a thread without one.
import Foundation

/// A review thread: a comment on a file's lines and the replies to it, shown under the review it was written in.
public struct HostedReviewThread: Sendable, Equatable, Identifiable {
    /// The root comment's id, even when GitHub did not return the root: replies post to it (GitHub refuses a reply
    /// to a reply).
    public var id: Int
    /// The review the root comment was written in; nil when GitHub gave the root none (an `unattached` thread).
    public var reviewID: Int?
    public var path: String
    /// The commented lines in the current diff, or in the diff the comment was written on when it is outdated. Both
    /// come from the same diff, so a range never mixes the two; `startLine` is nil for a single line.
    public var startLine: Int?
    public var line: Int?
    /// `LEFT` (the old file) or `RIGHT` (the new file).
    public var side: String?
    /// The diff changed under the thread since it was written: from the state, else from the root having no line
    /// in the current diff.
    public var isOutdated: Bool
    /// The root's diff hunk, ending at the commented line.
    public var diffHunk: String?
    /// The root first, then the replies oldest first.
    public var comments: [HostedReviewComment]
    /// nil when the GraphQL load failed or has no thread for this root: resolving is unavailable then.
    public var state: HostedReviewThreadState?

    /// Groups `comments` into threads keyed by the review of each thread's root, each review's threads ordered by
    /// their root's date, and joins `states` on the root comment's id. A thread is a root comment and the replies
    /// that point at it (`inReplyToID`). When GitHub did not return a reply's root, the replies to that root still
    /// make one thread, headed by the earliest of them, whose `id` stays the missing root's (the id a reply posts
    /// to); its state joins on that id, else on the head's. A thread whose head has no review id goes to
    /// `unattached`, ordered the same way, for the caller to show at the end of the timeline: dropping it would hide
    /// an inline comment. `replyOnlyReviewIDs` are the reviews whose comments all went into threads of other
    /// reviews: GitHub makes such a review for each later reply and hides it from the timeline. It is read from the
    /// comments alone; whether such a review still shows when it has a body of its own is the caller's choice.
    public static func group(
        _ comments: [HostedReviewComment], states: [HostedReviewThreadState]
    ) -> (
        threadsByReview: [Int: [HostedReviewThread]], replyOnlyReviewIDs: Set<Int>, unattached: [HostedReviewThread]
    ) {
        // Paging can return a comment twice when one is added meanwhile.
        var seen = Set<Int>()
        let unique = comments.filter { seen.insert($0.id).inserted }
        let stateByRoot = Dictionary(
            states.compactMap { state in state.rootCommentID.map { ($0, state) } },
            uniquingKeysWith: { first, _ in first })
        var threadsByReview: [Int: [HostedReviewThread]] = [:]
        var unattached: [HostedReviewThread] = []
        for (rootID, members) in Dictionary(grouping: unique, by: { $0.inReplyToID ?? $0.id }) {
            let sorted = members.sorted(by: isEarlier)
            let head = sorted.first { $0.id == rootID } ?? sorted[0]
            let state = stateByRoot[rootID] ?? stateByRoot[head.id]
            let current = head.line != nil
            let thread = HostedReviewThread(
                id: rootID, reviewID: head.pullRequestReviewID, path: head.path,
                startLine: current ? head.startLine : head.originalStartLine,
                line: current ? head.line : head.originalLine, side: head.side,
                isOutdated: state?.isOutdated ?? !current, diffHunk: head.diffHunk,
                comments: [head] + sorted.filter { $0.id != head.id }, state: state)
            if let reviewID = head.pullRequestReviewID {
                threadsByReview[reviewID, default: []].append(thread)
            } else {
                unattached.append(thread)
            }
        }
        let byRootDate = { (a: HostedReviewThread, b: HostedReviewThread) in isEarlier(a.comments[0], b.comments[0]) }
        for reviewID in threadsByReview.keys {
            threadsByReview[reviewID]?.sort(by: byRootDate)
        }
        unattached.sort(by: byRootDate)
        let reviewIDs = Set(unique.compactMap(\.pullRequestReviewID))
        return (threadsByReview, reviewIDs.subtracting(threadsByReview.keys), unattached)
    }

    /// Oldest first, then by id when the dates tie or are missing, so the order is the same on every run.
    private static func isEarlier(_ a: HostedReviewComment, _ b: HostedReviewComment) -> Bool {
        (a.createdAt ?? .distantPast, a.id) < (b.createdAt ?? .distantPast, b.id)
    }
}
