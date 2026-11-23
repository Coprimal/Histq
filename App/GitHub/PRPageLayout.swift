// The pull request and issue pages' per-host layout (`PRPageLayout`) and their dates (`PRPageDates`): relative ("2 days
// ago") with the absolute date in the user's format as a tooltip, on every host's page, HTML and native rows alike.
import Foundation
import HistqCore

/// What a host's pull request and issue pages show and where, chosen by the account kind (`for(_:)`). `.default` is
/// the page as it was before Phase 15 (relative dates apart) and is never edited: whatever a provider supports, it
/// renders nothing the host-like pages add. Each host gets a value of its own (`.gitlab` here; later ones for the other
/// kinds), never an edit of `.default`; a kind without one gets `.default`.
struct PRPageLayout: Sendable, Equatable {
    /// The timing log's word (`pr 1 layout gitlab`).
    let name: String
    /// The pull request's tabs, in the host's order.
    var tabs: [PRTab] = PRTab.allCases
    /// The tabs the host names otherwise (GitLab's "Overview"); the others keep `PRTab.title`.
    var tabTitles: [PRTab: String] = [:]
    /// The header's sentence under the title.
    var mergeSentence: PRMergeSentence = .wantsToMerge
    /// The award bar under the tabs, first on the Conversation tab (GitLab's Overview): the pull request's own
    /// reactions, where the provider has `itemReactions`.
    var reactionBar = false
    /// GitLab's approval box and merge box under the award bar, before the activity, in GitLab's wording (the merge
    /// box replaces the Actions card under the timeline).
    var mergeBoxes = false
    /// The host's Activity in place of the Conversation card: its title, history entries (system notes, state, label
    /// and milestone changes) on the timeline, the filter and the sort; nil keeps today's Conversation card.
    var activity: PRActivity? = nil
    /// The issue page's Activity, as `activity` is the pull request's.
    var issueActivity: PRActivity? = nil
    /// The issue header's sentence under the title.
    var issueSentence: PRIssueSentence = .openedThisIssue
    /// The host's right sidebar (`HostSidebar`: GitLab's Assignees, Reviewers, Labels, Milestone, Time tracking,
    /// Participants, in its order and words) on the pull request and issue pages, in place of today's side cards.
    var sidebar = false
    /// A thread with replies starts with them collapsed under a "N replies · Last reply by X" summary (GitLab's);
    /// false keeps today's rule (only a resolved thread starts collapsed, to its header).
    var collapsesReplies = false
    /// The bottom composer's "Comment" / "Start thread" choice, where the provider starts threads.
    var startThread = false

    static let `default` = PRPageLayout(name: "default")
    static let gitlab = PRPageLayout(
        name: "gitlab", tabs: [.conversation, .commits, .checks, .files],
        tabTitles: [.conversation: "Overview", .checks: "Pipelines", .files: "Changes"],
        mergeSentence: .requestedToMerge, reactionBar: true, mergeBoxes: true, activity: .gitLabMergeRequest,
        issueActivity: .gitLabIssue, issueSentence: .created, sidebar: true, collapsesReplies: true,
        startThread: true)

    func title(of tab: PRTab) -> String { tabTitles[tab] ?? tab.title }

    /// A lookup, not a `switch`, so a new kind builds without a value of its own.
    private static let byKind: [HostingKind: PRPageLayout] = [.gitlab: .gitlab]

    #if DEBUG
    /// DEBUG `-HistqPageLayout default`: every kind gets `.default`.
    private static let forcesDefault = AppState.launchFlag("-HistqPageLayout") == "default"
    #endif

    static func `for`(_ kind: HostingKind) -> PRPageLayout {
        #if DEBUG
        if forcesDefault { return .default }
        #endif
        return byKind[kind] ?? .default
    }
}

/// A host's Activity: the card's title, the filter's categories after "All activity" (in the host's order), the
/// category of a comment or thread, and of a history entry by its `action` (`byAction`), or every entry's (`history`,
/// the issue's "History only"). An entry with no category shows under "All activity" only. The table is the 15.5
/// filter categories note of the plan's phase 15.
struct PRActivity: Sendable, Equatable {
    static let all = "All activity"

    let title: String
    let categories: [String]
    let comments: String
    var byAction: [String: String] = [:]
    var history: String? = nil

    /// The category of a history entry of `action`; nil when it has none.
    func category(ofEntry action: String?) -> String? {
        history ?? action.flatMap { byAction[$0] }
    }

    static let gitLabMergeRequest: PRActivity = {
        let approvals = "Approvals", people = "Assignees & reviewers", comments = "Comments"
        let commits = "Commits & branches", edits = "Edits", labels = "Labels", lock = "Lock status"
        let mentions = "Mentions", status = "Merge request status", tracking = "Tracking"
        var byAction: [String: String] = [:]
        for (category, actions) in [
            (approvals, ["approved", "unapproved", "requested_changes"]), (people, ["assignee", "reviewer"]),
            (comments, ["discussion"]), (commits, ["commit", "branch"]),
            (edits, ["description", "title", "outdated", "issue_type", "task"]), (labels, ["label"]),
            (lock, ["locked", "unlocked"]), (mentions, ["cross_reference"]),
            (status, ["opened", "closed", "merged", "state"]), (tracking, ["milestone", "time_tracking"]),
        ] {
            for action in actions { byAction[action] = category }
        }
        return PRActivity(
            title: "Activity",
            categories: [approvals, people, comments, commits, edits, labels, lock, mentions, status, tracking],
            comments: comments, byAction: byAction)
    }()

    static let gitLabIssue = PRActivity(
        title: "Activity", categories: ["Comments only", "History only"], comments: "Comments only",
        history: "History only")
}

/// What the Activity shows now: the filter's choice (`PRActivity.all` or a category) and the order.
struct PRActivityView: Sendable, Equatable {
    var filter = PRActivity.all
    var newestFirst = false

    /// The sort, remembered for the app (GitLab's toggle), read where a layout has an Activity.
    static let newestFirstKey = "hostedActivityNewestFirst"
}

/// The pull request header's sentence under the title.
enum PRMergeSentence: Sendable, Equatable {
    /// "stub wants to merge 2 commits into [main] from [feature]", the state pill by "Open on <host>".
    case wantsToMerge
    /// GitLab's "[Open] stub requested to merge [feature] [copy] into [main] 2 days ago", the state badge first.
    case requestedToMerge
}

/// The issue header's sentence under the title.
enum PRIssueSentence: Sendable, Equatable {
    /// "reviewer opened this issue 2 days ago · 1 comment".
    case openedThisIssue
    /// GitLab's "[Open] reviewer opened this issue 2 days ago", the state badge first (no comment count).
    case created
}

/// The pages' dates against `now`, one detail load's "now" (`loadNow()`), pinned for that load: every rebuild and
/// patch of it uses the same one, so an optimistic patch never changes date text; only a real reload takes a new one.
/// Made once per page or view, not per date (its formatters are costly to make).
struct PRPageDates {
    let now: Date
    private let absoluteFormatter: DateFormatter
    private let relativeFormatter: RelativeDateTimeFormatter

    init(now: Date) {
        self.now = now
        absoluteFormatter = DateFormatter()
        absoluteFormatter.locale = Locale(identifier: Locale.current.identifier)
        absoluteFormatter.dateFormat = Preferences.defaults.string(forKey: PrefKey.dateFormat.rawValue)
            ?? "MM/dd/yy @ HH:mm"
        relativeFormatter = RelativeDateTimeFormatter()
        // The pages' wording is English.
        relativeFormatter.locale = Locale(identifier: "en_US")
        relativeFormatter.unitsStyle = .full
        relativeFormatter.dateTimeStyle = .numeric
    }

    /// "just now" under a minute (or after `now`: an optimistic comment written since the load), else "5 minutes
    /// ago", "2 days ago", "1 week ago"…
    func relative(_ date: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    /// `date` in the user's date format (Settings › Appearance, 24 h by default): the tooltip.
    func absolute(_ date: Date) -> String {
        absoluteFormatter.string(from: date)
    }

    /// A detail load's "now": the clock, or in DEBUG the fixed date of `-HistqNow <ISO 8601 date>`, so the relative
    /// dates of stub shots never drift between runs.
    static func loadNow() -> Date {
        #if DEBUG
        if let fixedNow { return fixedNow }
        #endif
        return .now
    }

    #if DEBUG
    // Stub launches only: a real account always gets the clock.
    private static let fixedNow = GitHubStub.isEnabled
        ? AppState.launchFlag("-HistqNow").flatMap { ISO8601DateFormatter().date(from: $0) } : nil
    #endif
}
