// The graph's per-worktree view: hidden branches and tags, soloed and pinned branches and the "hide stale branches"
// switch. The app saves it as JSON in `repo-view/<stateKey>.json` (never in `.git`); a workspace file embeds it per repo.
import Foundation

public struct RepoViewState: Codable, Equatable, Sendable {
    public static let empty = RepoViewState()

    /// Full ref names (`refs/heads/x`, `refs/remotes/o/x`); `hidden` also tags (`refs/tags/v1`).
    public var hidden: [String] = []
    public var solo: [String] = []
    public var pinned: [String] = []
    public var hideStale = false

    public init() {}

    public init(hidden: [String] = [], solo: [String] = [], pinned: [String] = [], hideStale: Bool = false) {
        self.hidden = hidden
        self.solo = solo
        self.pinned = pinned
        self.hideStale = hideStale
    }

    /// A missing field reads as its default, so a file from an older build still loads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hidden = try container.decodeIfPresent([String].self, forKey: .hidden) ?? []
        solo = try container.decodeIfPresent([String].self, forKey: .solo) ?? []
        pinned = try container.decodeIfPresent([String].self, forKey: .pinned) ?? []
        hideStale = try container.decodeIfPresent(Bool.self, forKey: .hideStale) ?? false
    }
}
