// The first-run onboarding of one window: the current step with Back / Next / skip, the tour's demo repository
// (made with git off the main actor only when the tour step is entered, removed when the tour is left or the
// onboarding ends) and the window actions it needs, injected as closures so it never depends on WindowModel.
import Foundation
import HistqCore
import os

@Observable
@MainActor
final class OnboardingModel {
    /// The steps, in the order the card walks them. Raw values are the `-HistqOnboarding <step>` ids.
    enum Step: String, CaseIterable {
        case welcome, git, profile, github, ai, tabPosition, layout, avatars, rowHeight, laneColors, fadeWorktrees,
             tour, finish

        /// The step a `-HistqOnboarding <step>` id names, or nil for an id this build does not know.
        init?(launch step: String) {
            self.init(rawValue: step)
        }
    }

    /// The tour's demo repository.
    enum Demo: Equatable {
        case idle
        case creating
        /// The main repository's folder, opened through `openDemo`.
        case ready(URL)
        /// Why it could not be made (plain text, from git).
        case failed(String)
    }

    private(set) var current: Step = .welcome
    var index: Int { Step.allCases.firstIndex(of: current) ?? 0 }
    private(set) var demo: Demo = .idle

    /// Whether the tour's spotlight runs over the demo tab (set by the tour; nothing sets it before the spotlight
    /// exists, so the card stays up on the tour step).
    var spotlightRunning = false
    /// Whether the card shows: on every step except the tour while its spotlight runs.
    var showsCard: Bool { !(current == .tour && spotlightRunning) }

    /// Set when no usable git was found (by the git step's check, or when the tour could not resolve git).
    var gitMissing = false
    /// Whether the tour can run: it needs git to make its demo repository.
    var tourAvailable: Bool { !gitMissing }
    /// Why the tour is unavailable, for the tour step's card; nil when it is available.
    var tourNote: String? {
        tourAvailable ? nil : "The tour needs git to make its demo repository, and no usable git was found. "
            + "Install the Command Line Tools or choose a git in Settings › General."
    }

    /// A repository cloned during the onboarding: it opens through `openRepo` after the demo closes, when the
    /// onboarding finishes or is skipped.
    var pendingClone: URL?

    @ObservationIgnored private let openDemo: (URL) -> Void
    @ObservationIgnored private let closeDemo: () -> Void
    @ObservationIgnored private let openRepo: (URL) -> Void
    @ObservationIgnored private let end: () -> Void
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    @ObservationIgnored private var ended = false

    private nonisolated static let logger = Logger(subsystem: "com.math2it.histq", category: "onboarding")

    init(openDemo: @escaping (URL) -> Void = { _ in }, closeDemo: @escaping () -> Void = {},
         openRepo: @escaping (URL) -> Void = { _ in }, end: @escaping () -> Void = {}) {
        self.openDemo = openDemo
        self.closeDemo = closeDemo
        self.openRepo = openRepo
        self.end = end
    }

    // MARK: Navigation

    /// Opens the onboarding at `step` (the welcome step by default).
    func start(at step: Step = .welcome) {
        go(to: step)
    }

    /// The next step; on the last one, finishes.
    func next() {
        let steps = Step.allCases
        guard index + 1 < steps.count else { return finish() }
        go(to: steps[index + 1])
    }

    /// The previous step; nothing on the first one.
    func back() {
        guard index > 0 else { return }
        go(to: Step.allCases[index - 1])
    }

    /// Leaves the current step without applying it.
    func skipStep() {
        next()
    }

    /// Ends the onboarding from any step.
    func skipAll() {
        close()
    }

    /// Ends the onboarding after its last step.
    func finish() {
        close()
    }

    /// Closes the demo tab and removes the demo repository (a creation in flight is cancelled and cleans up after
    /// itself). Also for ending the onboarding without marking it done, e.g. when its window closes.
    func discardDemo() {
        demoTask?.cancel()
        demoTask = nil
        if case .ready(let repo) = demo {
            closeDemo()
            Self.remove(base: repo.deletingLastPathComponent(), parent: StatePaths.onboardingDemoParent)
        }
        demo = .idle
        spotlightRunning = false
    }

    private func go(to step: Step) {
        guard !ended else { return }
        if current == .tour, step != .tour { discardDemo() }
        current = step
        if step == .tour { createDemo() }
    }

    /// Marks the onboarding done, closes the demo, opens a pending clone and hands the window back. Runs once.
    private func close() {
        guard !ended else { return }
        ended = true
        Preferences.defaults.set(true, forKey: PrefKey.onboardingDone.rawValue)
        discardDemo()
        if let pendingClone {
            self.pendingClone = nil
            openRepo(pendingClone)
        }
        end()
    }

    // MARK: Demo repository

    private func createDemo() {
        guard tourAvailable, demo == .idle else { return }
        demo = .creating
        let parent = StatePaths.onboardingDemoParent
        demoTask = Task { [weak self] in
            let outcome = await Self.makeDemo(in: parent)
            guard let self, !Task.isCancelled, !self.ended, self.current == .tour else {
                // Left the tour while git ran: drop what it made.
                if case .made(let repo) = outcome { Self.remove(base: repo.deletingLastPathComponent(), parent: parent) }
                return
            }
            self.demoTask = nil
            switch outcome {
            case .made(let repo):
                self.demo = .ready(repo)
                self.openDemo(repo)
            case .noGit:
                self.gitMissing = true
                self.demo = .idle
            case .failed(let message):
                self.demo = .failed(message)
            }
        }
    }

    private enum Outcome: Sendable {
        case made(URL)
        case noGit
        case failed(String)
    }

    /// Resolves git and builds the demo repository under `parent`. The read base suffices: the generator
    /// isolates its config and turns hooks and signing off, so the login shell's PATH is not waited for.
    @concurrent
    private nonisolated static func makeDemo(in parent: URL) async -> Outcome {
        let toolchain: GitToolchain.Resolved
        do {
            toolchain = try await GitToolchain.resolve()
        } catch {
            return .noGit
        }
        do {
            let runner = GitRunner(executable: toolchain.executable.url)
            let env = GitInvocation.environment(profile: nil, base: toolchain.readBase, access: .write)
            return .made(try await DemoRepository.create(in: parent, runner: runner, baseEnv: env))
        } catch let error as GitError {
            let lines = error.stderrTail.split(whereSeparator: \.isNewline).map(String.init)
            return .failed(lines.last { $0.hasPrefix("fatal:") || $0.hasPrefix("error:") } ?? lines.last
                ?? "git failed.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Deletes a demo base folder off the main actor; `DemoRepository.remove` refuses anything but a marked
    /// folder directly inside `parent`.
    private nonisolated static func remove(base: URL, parent: URL) {
        Task.detached(priority: .utility) {
            do {
                try DemoRepository.remove(base: base, parent: parent)
            } catch {
                logger.error("Demo repository not removed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
