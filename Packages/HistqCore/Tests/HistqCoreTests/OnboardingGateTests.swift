// Tests for the first-run gate: onboarding shows only on a truly empty state (a Welcome-only session counts as
// empty), an existing user (a recent repo, a saved repo tab, a saved workspace layout) is marked done silently, a
// state-dir launch stays as it is, and the forcing flag shows it whatever the state.
import Foundation
import HistqCore
import Testing

struct OnboardingGateTests {
    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        var done = false
        var recentRepos = 0
        var session: SavedSession?
        var stateDirMode = false
        var forced = false
        let expected: OnboardingGate.Decision

        var testDescription: String { name }
    }

    static func window(_ tabs: [SavedTab]) -> SavedWindow {
        SavedWindow(x: 0, y: 0, width: 1200, height: 800, group: 0, tabIndex: 0, isSelectedInGroup: true, tabs: tabs)
    }

    static let cases: [Case] = [
        Case(name: "empty state shows", expected: .show),
        Case(name: "a Welcome-only session shows", session: SavedSession(windows: [window([SavedTab()])]),
             expected: .show),
        Case(name: "a session tab with a path marks done",
             session: SavedSession(windows: [window([SavedTab(path: "/tmp/repo")])]), expected: .markDone),
        Case(name: "a recent repo marks done", recentRepos: 1, expected: .markDone),
        Case(name: "a session with only workspaces marks done",
             session: SavedSession(windows: [], workspaces: [
                 WorkspaceLayout(path: "/tmp/work.histqws", open: true, windows: []),
             ]), expected: .markDone),
        Case(name: "state-dir mode stays", stateDirMode: true, expected: .stay),
        Case(name: "done and not forced stays", done: true, expected: .stay),
        Case(name: "forced shows even when done with a recent repo", done: true, recentRepos: 1, forced: true,
             expected: .show),
    ]

    @Test("the launch decision", arguments: cases)
    func decide(_ c: Case) {
        let decision = OnboardingGate.decide(
            done: c.done, recentRepos: c.recentRepos, recentWorkspaces: 0, session: c.session,
            stateDirMode: c.stateDirMode, launchedWithPaths: false, forced: c.forced)
        #expect(decision == c.expected)
    }
}
