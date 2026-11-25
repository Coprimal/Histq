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
    /// Each Activity comment's Edit is a pencil in its header, beside the reaction button, its "…" menu left with
    /// Delete (GitLab's).
    var headerEdit = false
    /// With `headerEdit`: Delete is a trash icon beside Edit too, its "…" menu gone (Azure DevOps's).
    var headerDelete = false
    /// Each Activity comment's header shows "Author" on the item author's comments and the commenter's member role
    /// ("Owner", "Developer") the provider reads (`memberRoles`), as GitLab's badges.
    var roleBadges = false
    /// The Commits tab groups the commits under day headings ("Nov 20, 2026"), each "<author> <commitVerb> <time>"
    /// with a copy button beside its short id (GitLab's, GitHub's).
    var commitsByDay = false
    /// The Commits tab's verb with `commitsByDay`: GitLab's "authored", GitHub's "committed".
    var commitVerb = "authored"
    /// The description's own reactions as chips under it inside the page, with the picker (GitHub's), where the
    /// provider has `itemReactions`; the award bar (`reactionBar`) is GitLab's place for them.
    var descriptionReactions = false
    /// What the description's header says its author did ("opened this pull request" when nil; GitHub's "commented").
    var descriptionVerb: String? = nil
    /// The host's history entries (`timelineEvents`) one line each on a rail among the comments and reviews, without
    /// the Activity's filter (GitHub's Conversation).
    var timelineEvents = false
    /// GitHub's merge box after the timeline: reviews and checks rows over the merge state (Update branch when out of
    /// date), and for a merged pull request "<who> merged commit <sha> into <base>" with Delete branch / Restore
    /// branch.
    var githubMergeBox = false
    /// GitHub's side cards: today's Reviewers, Assignees and Labels, then Milestone and Participants.
    var githubSidebar = false
    /// A thread's resolve button says "Resolve thread" / "Reopen thread" (GitLab's) instead of "Resolve conversation"
    /// / "Unresolve conversation".
    var threadWords = false
    /// A thread's resolve button says "Resolve" / "Reopen" (Bitbucket's).
    var shortResolveWords = false
    /// Files changed lists the files as a folder tree (single-child folders joined, `.github/workflows`) in a wider
    /// column, instead of one row per file with its folder under its name (GitHub's).
    var filesTree = false
    /// A comment by the item's author has only the "Author" badge, not also their role (GitHub's); else both
    /// (GitLab's "Author" and "Owner").
    var authorBadgeOnly = false
    /// The description in a card of its own ("Created by <login> <time>"), then a "Comments" card with the filter
    /// (All / Unresolved / Mine, `PRCommentFilter`) and the comment box above the comments (GitHub's new page). With
    /// an `activity`, that card is the Activity's (its title and filter; Bitbucket's).
    var commentsCard = false
    /// With `commentsCard`: the description card's title, its text alone under it (Bitbucket's "Description"); nil
    /// keeps GitHub's "Created by" header in the page.
    var descriptionTitle: String? = nil
    /// The comment box's prompt ("Leave a comment" when nil; Bitbucket's "What do you want to say?").
    var composerPrompt: String? = nil
    /// Approve and Request changes in the header, the comment box without its Review tab (Bitbucket's).
    var reviewButtonsInHeader = false
    /// The merge area first on the Overview: the state, the pull request's own strategies, Close source branch and
    /// Merge, or "Merged pull request" (Bitbucket's), in place of the Actions card under the timeline.
    var bitbucketMergeArea = false
    /// Bitbucket's sidebar: Builds, Merge checks, Reviewers, Tasks, then Jira work items with `jiraCard`.
    var bitbucketSidebar = false
    /// With `bitbucketSidebar`: the Jira work items card, opening the host (Bitbucket Cloud's).
    var jiraCard = false
    /// With `bitbucketMergeArea`: the merge area's checkbox that deletes the source branch once merged, always shown
    /// under this title for a branch of this repository, unchecked first (Data Center's "Delete source branch after
    /// merging": its pull request carries no choice); nil keeps Cloud's "Close source branch", shown where the pull
    /// request says its choice.
    var deleteSourceBranchTitle: String? = nil
    /// With `bitbucketMergeArea`: the merge checks (`mergeChecks`) listed under the merge state in the merge area
    /// (Azure DevOps's policies), read without `bitbucketSidebar`.
    var mergeChecksInMergeArea = false
    /// Azure DevOps's sidebar: Reviewers under "Required" and "Optional" with each one's vote, then Tags (labels).
    var azureSidebar = false
    /// The host's own words for the page's states and buttons; none keeps Histq's.
    var words = PRPageWords()

    static let `default` = PRPageLayout(name: "default")
    static let gitlab = PRPageLayout(
        name: "gitlab", tabs: [.conversation, .commits, .checks, .files],
        tabTitles: [.conversation: "Overview", .checks: "Pipelines", .files: "Changes"],
        mergeSentence: .requestedToMerge, reactionBar: true, mergeBoxes: true, activity: .gitLabMergeRequest,
        issueActivity: .gitLabIssue, issueSentence: .created, sidebar: true, collapsesReplies: true,
        startThread: true, headerEdit: true, roleBadges: true, commitsByDay: true, threadWords: true)
    static let github = PRPageLayout(
        name: "github", tabs: [.conversation, .commits, .checks, .files], tabTitles: [.conversation: "Overview"],
        mergeSentence: .stateFirst, issueSentence: .openedStateFirst, roleBadges: true, commitsByDay: true,
        commitVerb: "committed", descriptionReactions: true, descriptionVerb: "commented", timelineEvents: true,
        githubMergeBox: true, githubSidebar: true, filesTree: true, authorBadgeOnly: true, commentsCard: true)

    func title(of tab: PRTab) -> String { tabTitles[tab] ?? tab.title }

    /// A lookup, not a `switch`, so a new kind builds without a value of its own.
    private static let byKind: [HostingKind: PRPageLayout] = [
        .gitlab: .gitlab, .github: .github, .bitbucketCloud: .bitbucket, .bitbucketDataCenter: .bitbucketDataCenter,
        .azureDevOps: .azureDevOps,
    ]

    #if DEBUG
    /// DEBUG `-HistqPageLayout default`: every kind gets `.default`.
    private static let forcesDefault = AppState.launchFlag("-HistqPageLayout") == "default"
    #endif

    static let bitbucket = PRPageLayout(
        name: "bitbucket", tabs: [.conversation, .files, .commits], tabTitles: [.conversation: "Overview"],
        mergeSentence: .bitbucket, activity: .bitbucketPullRequest, commitsByDay: true, commitVerb: "committed",
        shortResolveWords: true, filesTree: true, commentsCard: true, descriptionTitle: "Description",
        composerPrompt: "What do you want to say?", reviewButtonsInHeader: true, bitbucketMergeArea: true,
        bitbucketSidebar: true, jiraCard: true)

    /// Bitbucket Data Center's page: Cloud's (`.bitbucket`) with Data Center's Activity filter, "Delete source branch
    /// after merging", and no Jira card (no core REST endpoint).
    static let bitbucketDataCenter = PRPageLayout(
        name: "bitbucketDataCenter", tabs: [.conversation, .files, .commits], tabTitles: [.conversation: "Overview"],
        mergeSentence: .bitbucket, activity: .bitbucketDataCenterPullRequest, commitsByDay: true,
        commitVerb: "committed", shortResolveWords: true, filesTree: true, commentsCard: true,
        descriptionTitle: "Description", composerPrompt: "What do you want to say?", reviewButtonsInHeader: true,
        bitbucketMergeArea: true, bitbucketSidebar: true, deleteSourceBranchTitle: "Delete source branch after merging")

    /// Azure DevOps's page (the 20.6 screenshots): tabs Overview / Files / Commits; the header's "proposes to merge"
    /// sentence with "N/M comments resolved" and Approve / Wait for author; the merge card first ("No merge
    /// conflicts", the blocking policies, Azure's strategies and Complete); Description; the Activity newest first
    /// with each thread's status; Reviewers (Required / Optional, by vote) and Tags.
    static let azureDevOps = PRPageLayout(
        name: "azureDevOps", tabs: [.conversation, .files, .commits],
        tabTitles: [.conversation: "Overview", .files: "Files"], mergeSentence: .azureDevOps,
        activity: .azureDevOpsPullRequest, headerEdit: true, headerDelete: true, commitsByDay: true,
        commitVerb: "committed", shortResolveWords: true, filesTree: true, commentsCard: true, descriptionTitle: "Description", composerPrompt: "Add a comment…",
        reviewButtonsInHeader: true, bitbucketMergeArea: true, mergeChecksInMergeArea: true, azureSidebar: true,
        words: PRPageWords(
            states: ["Open": "Active", "Merged": "Completed", "Closed": "Abandoned"],
            requestChanges: "Wait for author", changesRequested: "Waiting for author", complete: "Complete",
            noConflicts: "No merge conflicts", conflicts: "Merge conflicts", completed: "Completed",
            abandoned: "Abandoned", close: "Abandon", reopen: "Reactivate", reopenThread: "Reactivate"))

    static func `for`(_ kind: HostingKind) -> PRPageLayout {
        #if DEBUG
        if forcesDefault { return .default }
        #endif
        return byKind[kind] ?? .default
    }
}

/// A host's own words on the pull request page (`PRPageLayout.words`, Azure DevOps's); each nil keeps Histq's.
struct PRPageWords: Sendable, Equatable {
    /// The state pill's titles by Histq's ("Open", "Merged", "Closed", "Draft").
    var states: [String: String] = [:]
    /// The header's Request changes, and its title once the viewer asked for changes.
    var requestChanges: String? = nil
    var changesRequested: String? = nil
    /// The merge area's Merge button.
    var complete: String? = nil
    /// The merge state's title when the branch merges cleanly, and with conflicts.
    var noConflicts: String? = nil
    var conflicts: String? = nil
    /// The merge area's title for a merged and for a closed pull request.
    var completed: String? = nil
    var abandoned: String? = nil
    /// The Close and Reopen buttons (the noun dropped).
    var close: String? = nil
    var reopen: String? = nil
    /// A resolved thread's button, with `shortResolveWords` ("Reopen" when nil).
    var reopenThread: String? = nil
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
    /// The category of the viewer's own comments and threads ("My comments"); nil without one.
    var mine: String? = nil
    /// Each account as its name and `@login` (GitLab's); false: its name alone (Bitbucket's).
    var handles = true
    /// A diff thread's header: "started a thread on the diff" (GitLab's) when nil, else this verb then the file's name
    /// ("commented on index.js", Bitbucket's); a general comment then always "commented".
    var fileVerb: String? = nil
    /// The order, fixed (Bitbucket's newest first, no sort toggle); nil: the user's sort (GitLab's).
    var newestFirst: Bool? = nil
    /// The entries under day headings ("Wednesday, November 19, 2025", Bitbucket's).
    var dayHeadings = false
    /// The filter's title for every entry, with their count ("Show everything (7)", Azure DevOps's); nil: "All
    /// activity". The filter's value stays `PRActivity.all`.
    var allTitle: String? = nil
    /// Each thread's status in its header, by the host's raw status (Azure DevOps's `active`, `fixed`…), in place of
    /// the "Resolved" line; empty shows none.
    var statusTitles: [String: String] = [:]
    /// The tab's count takes every note, the diff threads' comments too, as gitlab.com's Overview does (its
    /// `user_notes_count`); false counts the general comments only.
    var countsThreadNotes = false

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
            comments: comments, byAction: byAction, countsThreadNotes: true)
    }()

    /// Bitbucket Cloud's Activity: All activity, All comments, My comments, Commits (its Tasks and Statuses are not
    /// in the API's activity), names without handles, "commented on <file>", newest first under day headings.
    static let bitbucketPullRequest = PRActivity(
        title: "Activity", categories: ["All comments", "My comments", "Commits", "Tasks"], comments: "All comments",
        byAction: ["commit": "Commits", "task": "Tasks"], mine: "My comments", handles: false, fileVerb: "commented on",
        newestFirst: true, dayHeadings: true)

    /// Bitbucket Data Center's Activity: Cloud's, its filter All activity, All comments, My comments, Commits (the
    /// rescopes), Reviews (approved, removed approval, requested changes); no Tasks (its tasks are blocker comments,
    /// not activities: the Tasks card lists them) and no Statuses.
    static let bitbucketDataCenterPullRequest = PRActivity(
        title: "Activity", categories: ["All comments", "My comments", "Commits", "Reviews"], comments: "All comments",
        byAction: ["commit": "Commits", "approved": "Reviews", "unapproved": "Reviews", "changes_requested": "Reviews"],
        mine: "My comments", handles: false, fileVerb: "commented on", newestFirst: true, dayHeadings: true)

    /// Azure DevOps's Activity: Show everything, then comments only or updates (its system entries) only; names
    /// without handles, "commented on <file>", newest first (the composer on top, "created the pull request" last),
    /// each thread's status as Azure names it.
    static let azureDevOpsPullRequest = PRActivity(
        title: "Activity", categories: ["Comments", "Updates"], comments: "Comments", history: "Updates",
        handles: false, fileVerb: "commented on", newestFirst: true, allTitle: "Show everything",
        statusTitles: [
            "active": "Active", "pending": "Pending", "fixed": "Resolved", "wontFix": "Won't fix",
            "byDesign": "By design", "closed": "Closed",
        ])

    static let gitLabIssue = PRActivity(
        title: "Activity", categories: ["Comments only", "History only"], comments: "Comments only",
        history: "History only")
}

/// The "Comments" card's filter (`PRPageLayout.commentsCard`, GitHub's): every comment, review and history entry;
/// only the review conversations not resolved; or only what the viewer wrote. Kept in `PRActivityView.filter`, whose
/// rebuilds it shares; any other value reads as `all`.
enum PRCommentFilter: String, CaseIterable, Sendable {
    case all = "All"
    case unresolved = "Unresolved"
    case mine = "Mine"

    init(filter: String) { self = Self(rawValue: filter) ?? .all }
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
    /// GitHub's "[Open] stub wants to merge 2 commits into [main] from [stub:feature]", the state badge first (merged:
    /// "<merged by> merged 2 commits into [main] from [stub:feature] <time>").
    case stateFirst
    /// Bitbucket's "[avatar] stub [feature] → [main] [Open] · Created 1 week ago · Last updated 2 days ago".
    case bitbucket
    /// Azure DevOps's "[Active] [avatar] stub proposes to merge [feature] [copy] into [main] 1/3 comments resolved".
    case azureDevOps
}

/// The issue header's sentence under the title.
enum PRIssueSentence: Sendable, Equatable {
    /// "reviewer opened this issue 2 days ago · 1 comment".
    case openedThisIssue
    /// GitLab's "[Open] reviewer opened this issue 2 days ago", the state badge first (no comment count).
    case created
    /// GitHub's "[Open] reviewer opened this issue 2 days ago · 1 comment", the state badge first.
    case openedStateFirst
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
