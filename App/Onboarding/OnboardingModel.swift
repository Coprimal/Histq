// The first-run onboarding of one window: the current step with Back / Next / skip, the tour's demo repository
// (made with git off the main actor only when the tour step is entered, removed when the tour is left or the
// onboarding ends), the tour's stops over its tab (the spotlight's target, one stop at a time) and the window actions
// it needs, injected so it never depends on WindowModel.
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

    /// Whether the tour's spotlight runs over the demo tab: set with the first stop's target, so the card stays up on
    /// the tour step while the demo is made and opens.
    private(set) var spotlightRunning = false
    /// The tour's stops for the window as it was when the demo opened; empty before.
    private(set) var tourStops: [TourStop] = []
    /// The stop the spotlight frames, an index in `tourStops`.
    private(set) var stopIndex = 0
    /// The stop the spotlight frames; nil while it does not run.
    var currentStop: TourStop? { spotlightRunning && tourStops.indices.contains(stopIndex) ? tourStops[stopIndex] : nil }
    /// Whether the card shows: on every step except the tour while its spotlight runs.
    var showsCard: Bool { !(current == .tour && spotlightRunning) }
    /// Whether the tour is on its way: its demo is made or opens and the spotlight has not started yet. Skip onboarding
    /// waits meanwhile, as the demo tab's opening would close its confirmation and the spotlight would cover it.
    var tourStarting: Bool {
        guard current == .tour, !spotlightRunning else { return false }
        switch demo {
        case .creating, .ready: return true
        case .idle, .failed: return false
        }
    }

    /// Set when no usable git was found (by the git step's check, or when the tour could not resolve git).
    var gitMissing = false
    /// Whether the tour can run: it needs git to make its demo repository.
    var tourAvailable: Bool { !gitMissing }
    /// Why the tour is unavailable, for the tour step's card; nil when it is available.
    var tourNote: String? {
        tourAvailable ? nil : "The tour needs git to make its demo repository, and no usable git was found. "
            + "Install the Command Line Tools or choose a git in Settings › General."
    }

    /// The repositories cloned during the onboarding (the GitHub step's clone form), in order: each opens through
    /// `openRepo` after the demo closes, when the onboarding finishes or is skipped.
    var pendingClones: [URL] = []
    /// The setup steps' Welcome model: the git step's check and its fixes (Install Command Line Tools, Choose git, Check
    /// Again), and the GitHub step's clone, whose end adds to `pendingClones`. A clone still running when the
    /// onboarding ends is handed to a Welcome tab of the window (`WindowModel.endOnboarding`).
    @ObservationIgnored let welcome = WelcomeModel(open: { _ in })
    /// The profile step's fields, kept here so Back keeps what was typed; Next on that step writes them.
    @ObservationIgnored let profile = OnboardingProfileDraft()

    @ObservationIgnored private let openDemo: (URL) -> RepoSession?
    @ObservationIgnored private let closeDemo: () -> Void
    /// The window's spotlight, which the tour points at each stop's target.
    @ObservationIgnored private let spotlight: SpotlightRegistry?
    /// The window's stops (`TourStops.stops` for its `TourContext`), read when the demo opens.
    @ObservationIgnored private let makeStops: () -> [TourStop]
    @ObservationIgnored private let openRepo: (URL) -> Void
    @ObservationIgnored private let end: () -> Void
    /// Asks before Skip onboarding with the window's modal; runs its argument only when confirmed.
    @ObservationIgnored private let confirmSkipAll: (@escaping @MainActor () -> Void) -> Void
    @ObservationIgnored private var demoTask: Task<Void, Never>?
    /// The demo tab's session, while it is open.
    @ObservationIgnored private weak var demoSession: RepoSession?
    /// Opening the tour or moving it to another stop; one at a time, so repeated keys never overlap.
    @ObservationIgnored private var tourTask: Task<Void, Never>?
    /// The `-HistqOnboarding tour:<id>` stop the next tour starts at (once); nil: the first stop.
    @ObservationIgnored private var startStop: String?
    @ObservationIgnored private var ended = false

    private nonisolated static let logger = Logger(subsystem: "com.math2it.histq", category: "onboarding")

    init(openDemo: @escaping (URL) -> RepoSession? = { _ in nil }, closeDemo: @escaping () -> Void = {},
         openRepo: @escaping (URL) -> Void = { _ in }, end: @escaping () -> Void = {},
         confirmSkipAll: @escaping (@escaping @MainActor () -> Void) -> Void = { _ in },
         postToast: @escaping (OperationToast) -> Void = { _ in },
         spotlight: SpotlightRegistry? = nil, stops: @escaping () -> [TourStop] = { [] }) {
        self.openDemo = openDemo
        self.closeDemo = closeDemo
        self.spotlight = spotlight
        self.makeStops = stops
        self.openRepo = openRepo
        self.end = end
        self.confirmSkipAll = confirmSkipAll
        // A clone made in the GitHub step waits for the end of the onboarding, so the tour's demo never replaces it. It
        // is in the recent repos at once, so it stays easy to find if the window closes before then.
        welcome.open = { [weak self] url in
            RecentRepos.shared.add(url)
            self?.pendingClones.append(url)
        }
        // A clone's warnings (its submodules failed) show as the window's toasts.
        welcome.postToast = postToast
    }

    // MARK: Navigation

    /// Opens the onboarding at `step` (the welcome step by default); on the tour, at the stop `stop` names (or the
    /// next one the window has), else its first.
    func start(at step: Step = .welcome, stop: String? = nil) {
        startStop = stop
        go(to: step)
    }

    /// Applies the current step (the profile step writes its profile), then the next step; on the last one, finishes.
    func next() {
        if current == .profile { profile.commit() }
        advance()
    }

    /// The previous step; nothing on the first one.
    func back() {
        guard index > 0 else { return }
        go(to: Step.allCases[index - 1])
    }

    /// Leaves the current step without applying it.
    func skipStep() {
        advance()
    }

    /// Skip onboarding: asks first, and ends the onboarding from any step only once confirmed.
    func requestSkipAll() {
        guard !tourStarting else { return }
        confirmSkipAll { [weak self] in self?.skipAll() }
    }

    /// Ends the onboarding from any step; only through `requestSkipAll`'s confirmation.
    private func skipAll() {
        close()
    }

    /// Ends the onboarding after its last step.
    func finish() {
        close()
    }

    /// Ends the spotlight, closes the demo tab and removes the demo repository (a creation in flight is cancelled and
    /// cleans up after itself). Also for ending the onboarding without marking it done, e.g. when its window closes.
    func discardDemo() {
        demoTask?.cancel()
        demoTask = nil
        tourTask?.cancel()
        tourTask = nil
        // First, so the content may take the keyboard again once the demo tab closes.
        if spotlightRunning { spotlight?.activeTarget = nil }
        spotlightRunning = false
        tourStops = []
        stopIndex = 0
        demoSession = nil
        if case .ready(let repo) = demo {
            closeDemo()
            Self.remove(base: repo.deletingLastPathComponent(), parent: StatePaths.onboardingDemoParent)
        }
        demo = .idle
    }

    // MARK: Tour

    /// The next stop the window shows; after the last one, the finish step.
    func nextStop() {
        move(by: 1)
    }

    /// The previous stop the window shows; before the first one, the step before the tour.
    func previousStop() {
        move(by: -1)
    }

    /// Leaves the tour for the finish step.
    func skipTour() {
        guard current == .tour else { return }
        next()
    }

    /// The next step, or finishes on the last one.
    private func advance() {
        let steps = Step.allCases
        guard index + 1 < steps.count else { return finish() }
        go(to: steps[index + 1])
    }

    private func go(to step: Step) {
        guard !ended else { return }
        if current == .tour, step != .tour { discardDemo() }
        current = step
        if step == .tour { createDemo() }
    }

    /// Marks the onboarding done, closes the demo, opens the pending clones and hands the window back (which takes a
    /// clone still running, `WindowModel.endOnboarding`). Runs once.
    private func close() {
        guard !ended else { return }
        ended = true
        Preferences.defaults.set(true, forKey: PrefKey.onboardingDone.rawValue)
        discardDemo()
        let clones = pendingClones
        pendingClones = []
        for url in clones { openRepo(url) }
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
                self.demoSession = self.openDemo(repo)
                self.startTour()
            case .noGit:
                self.gitMissing = true
                self.demo = .idle
            case .failed(let message):
                self.demo = .failed(message)
            }
        }
    }

    /// Once the demo tab shows its graph: the window's stops, then the spotlight on the launch's stop (or the first)
    /// or, when none of them shows, the finish step.
    private func startTour() {
        tourTask = Task { [weak self] in
            guard let self, await self.waitForDemo() else { return }
            let stops = self.makeStops()
            self.tourStops = stops
            let start = self.startStop.flatMap { TourStops.index(of: $0, in: stops) } ?? 0
            self.startStop = nil
            guard let index = await self.firstShown(from: start, by: 1) else {
                if self.isTouring { self.next() }
                return
            }
            self.tourTask = nil
            self.stopIndex = index
            self.spotlightRunning = true
            self.spotlight?.activeTarget = stops[index].target
        }
    }

    /// Moves the spotlight `step` stops on, skipping those the window does not show; past either end, leaves the tour.
    /// Nothing while a move or the opening runs.
    private func move(by step: Int) {
        guard isTouring, spotlightRunning, tourTask == nil else { return }
        let from = stopIndex + step
        tourTask = Task { [weak self] in
            guard let self else { return }
            let index = await self.firstShown(from: from, by: step)
            guard self.isTouring else { return }
            self.tourTask = nil
            guard let index else { return step > 0 ? self.next() : self.back() }
            self.stopIndex = index
            self.spotlight?.activeTarget = self.tourStops[index].target
        }
    }

    /// Still on this tour: not left, not ended, not cancelled.
    private var isTouring: Bool { !Task.isCancelled && !ended && current == .tour && demoSession != nil }

    /// Waits until the demo tab's refs and graph have loaded and its graph has laid out (at most a few seconds: a
    /// slow load starts the tour anyway, and stops without a frame are skipped). False when the tour was left meanwhile.
    private func waitForDemo() async -> Bool {
        _ = await waitUntil(.seconds(6)) { [weak self] in
            guard let self, let session = self.demoSession else { return true }
            return session.refs.value != nil && session.log.value != nil && self.spotlight?.frame(of: .graph) != nil
        }
        await Self.settle()
        return isTouring
    }

    /// The first stop from `index` on, going `step` at a time, whose target the window shows once its `prepare` ran
    /// on the demo tab; nil past either end or when the tour was left. A stop gets a short while to lay out (a panel
    /// shows once its selection loads) before it is skipped.
    private func firstShown(from index: Int, by step: Int) async -> Int? {
        var index = index
        while tourStops.indices.contains(index) {
            guard isTouring, let session = demoSession else { return nil }
            let stop = tourStops[index]
            stop.prepare?(session)
            await Self.settle()
            let shown = await waitUntil(.seconds(1)) { [weak self] in
                stop.resolves(frame: self?.spotlight?.frame(of: stop.target))
            }
            guard isTouring else { return nil }
            if shown { return index }
            index += step
        }
        return nil
    }

    /// Polls `condition` every 50 ms until it holds, the tour is left or `timeout` passes; whether it held.
    private func waitUntil(_ timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard isTouring, ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    /// A few frames, for SwiftUI and AppKit to lay out a selection's change and report the frames.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(80))
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
