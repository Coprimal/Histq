// Decides at launch whether onboarding shows by itself: only on a truly empty state (no recent repos or
// workspaces, no saved repo tab, no saved workspace layout). An existing user is marked done silently, and QA
// launches (a state dir or repo paths on the command line) never show it nor mark it done. Pure: no I/O.
import Foundation

public enum OnboardingGate {
    /// What the launch does with onboarding.
    public enum Decision: Equatable, Sendable {
        /// Show onboarding.
        case show
        /// An existing user: record onboarding as done without showing it.
        case markDone
        /// Leave everything as it is.
        case stay
    }

    /// The decision from the launch's state. `forced` is the launch flag that asks for onboarding; `stateDirMode` is a
    /// launch with its own state dir; `launchedWithPaths` is a launch with repo paths on its command line.
    public static func decide(done: Bool, recentRepos: Int, recentWorkspaces: Int, session: SavedSession?,
                              stateDirMode: Bool, launchedWithPaths: Bool, forced: Bool) -> Decision {
        if forced { return .show }
        if done { return .stay }
        if stateDirMode || launchedWithPaths { return .stay }
        if recentRepos > 0 || recentWorkspaces > 0 || session.map(hasUserState) == true { return .markDone }
        return .show
    }

    /// Whether the session holds something only a user makes: a repo tab (open or in a closed group; Welcome tabs
    /// have no path) or a saved workspace layout.
    static func hasUserState(_ session: SavedSession) -> Bool {
        if session.workspaces?.isEmpty == false { return true }
        return session.windows.contains { window in
            let closed = window.closedTabGroups?.flatMap(\.tabs) ?? []
            return (window.tabs + closed).contains { $0.path != nil }
        }
    }
}
