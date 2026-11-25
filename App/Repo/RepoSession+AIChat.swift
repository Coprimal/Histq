// A tab's AI chat (`AIChatModel`): its saved chats live in `StatePaths.directory("ai-chat")/<stateKey>.json`, so each
// worktree has its own. Explain jobs open in the chat; their context is read off the main actor with the read
// environment and the worktree's `.aiignore`, and each send reads the `.aiignore` digest that decides which saved
// contexts may be sent again (one that can't be read fails the turn: nothing is sent). Only closing the tab or the
// window stops a running chat.
import Foundation
import HistqCore

extension RepoSession {
    /// The chat of `aiChat`: every turn's system prompt takes Settings › AI's language and Explain instructions as
    /// they are at its click, and its `.aiignore` digest is the worktree's at its send (nil without a backend).
    func makeAIChat() -> AIChatModel {
        let file = StatePaths.directory("ai-chat")
            .appending(path: "\(Self.stateKey(url)).json", directoryHint: .notDirectory)
        let url = url
        return AIChatModel(
            storeURL: file,
            system: {
                AIPrompts.chatSystem(
                    language: Self.aiLanguages().response,
                    instructions: Preferences.defaults.string(forKey: PrefKey.aiExplainInstructions.rawValue) ?? "")
            },
            ignoreDigest: { [weak self] in
                guard let worktree = try? await self?.backend().directories.worktree else { return nil }
                return try await Self.aiIgnoreDigest(worktree: worktree)
            },
            resolve: { [weak self] references in
                guard let backend = try await self?.backend() else { throw CancellationError() }
                return try await Self.aiChatContext(references, backend: backend, cwd: url)
            })
    }

    /// An Explain click (commit or working changes): a new chat with the job's label opens in this call and the card
    /// expands; the diff is read and sent after. Other jobs are not chat jobs and do nothing here.
    func explainInChat(_ job: AIJob) {
        let label: String
        let modelText: String
        switch job {
        case .explainCommit(let hash, let message):
            let subject = message.prefix { !$0.isNewline }.trimmingCharacters(in: .whitespaces)
            label = "Explain commit \(hash.prefix(7))" + (subject.isEmpty ? "" : " \(subject)")
            modelText = "Explain this commit."
        case .explainWorkingChanges:
            label = "Explain the uncommitted changes"
            modelText = "Explain these working changes."
        case .commitMessage, .improveMessage, .squashMessage, .resolution, .pullRequest:
            return
        }
        let url = url
        aiChat.isExpanded = true
        aiChat.startExplain(label: label, modelText: modelText, logName: job.logName) { [weak self] in
            guard let backend = try await self?.backend() else { throw CancellationError() }
            return try await Self.aiChatContext(job, backend: backend, cwd: url)
        }
    }

    /// Add to AI Chat: `references` become chips of the current chat and the card opens; nothing is read or sent.
    func addToAIChat(_ references: [AIChatReference]) {
        aiChat.attach(references)
        aiChat.isExpanded = true
    }

    /// Explain on references: a new chat opens in the expanded card and sends at once (read off the main actor).
    func explainInChat(refs references: [AIChatReference]) {
        aiChat.isExpanded = true
        aiChat.explain(references)
    }

    /// The commits of the graph's selection an AI action takes, in graph order (newest first): the WIP row, stashes
    /// and other worktrees' rows are left out (as `RepoMenus.patchSelection` reads them).
    var aiSelection: [String] {
        graphSelection.compactMap { item in
            if case .commit(let hash) = item { hash } else { nil }
        }
    }

    /// Local branch `name` as a `.branch` reference, both as full ref names (a tag of the same name never wins). Its
    /// base: the base of the open pull request whose head is its upstream (the badge's chip), else the remote default
    /// branch (`origin/HEAD`, read off the main actor), else the local `main` or `master`; only refs that exist, never
    /// the branch itself. Nil when the branch or every base is missing.
    func branchReference(_ name: String) async -> AIChatReference? {
        guard let refs = refs.value, let branch = refs.localBranches.first(where: { $0.name == name }) else {
            return nil
        }
        let reference = { (base: String) in AIChatReference.branch(name: branch.refName, base: base) }
        if let base = branch.upstream.flatMap({ github.branchPullRequests[$0] })?.base,
           let tracking = refs.remoteBranches.first(where: { $0.name == base }) {
            return reference(tracking.refName)
        }
        if let backend = try? await backend(), let head = await Self.remoteDefaultBranch(backend: backend, cwd: url),
           refs.remoteBranches.contains(where: { $0.refName == head }) {
            return reference(head)
        }
        let fallback = ["main", "master"].lazy.compactMap { main in
            refs.localBranches.first { $0.name == main && $0.refName != branch.refName }
        }.first
        return fallback.map { reference($0.refName) }
    }

    /// `origin/HEAD`'s target (`refs/remotes/origin/main`), read with the read environment; nil when it is not set.
    @concurrent
    private nonisolated static func remoteDefaultBranch(backend: Backend, cwd: URL) async -> String? {
        guard let env = try? await backend.readEnvironment(cwd: cwd),
              let result = try? await backend.runner.run(
                  ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"], cwd: cwd, env: env, allowedExitCodes: [0, 1]),
              result.exitCode == 0
        else { return nil }
        let ref = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ref.hasPrefix("refs/remotes/") ? ref : nil
    }

    /// The open pull request `pull` as a `.pullRequest` reference (its detail page): title and description as the
    /// model has them at the click, head and base as full local ref names on the hosting remote (the
    /// remote-tracking branch, else the local branch of that name). Nothing is fetched: a missing branch, or the head
    /// of a fork (a same-named branch here is another one), is left empty, so only the description is sent.
    func pullRequestReference(_ pull: HostedPullRequest) -> AIChatReference {
        let remote = github.api?.remote
        let refs = refs.value
        func local(_ branch: String) -> String {
            guard let refs else { return "" }
            if let remote, let tracking = refs.remoteBranches.first(where: { $0.name == "\(remote)/\(branch)" }) {
                return tracking.refName
            }
            return refs.localBranches.first { $0.name == branch }?.refName ?? ""
        }
        return .pullRequest(
            number: pull.number, title: pull.title, body: pull.body ?? "", base: local(pull.base.ref),
            head: pull.isFromSameRepository ? local(pull.head.ref) : "")
    }

    /// The header's AI button: shows or hides the chat card (a running turn goes on).
    func toggleAIChat() {
        aiChat.isExpanded.toggle()
    }

    /// The tab or its window closed: stops the running turn (its partial answer is saved).
    func stopAIChat() {
        aiChat.stop()
    }

    /// The hidden context of an Explain turn: the commit's or the working changes' diff read with the read environment
    /// (never a profile), without what the worktree's `.aiignore` and the skip list leave out (`AIPrompts.filtered`),
    /// with the digest of that `.aiignore`. Throws `noChanges` for a bad hash or no working changes, and for a job
    /// that is not an Explain.
    @concurrent
    nonisolated static func aiChatContext(
        _ job: AIJob, backend: Backend, cwd: URL
    ) async throws -> AIChatModel.Context {
        let worktree = backend.directories.worktree
        switch job {
        case .explainCommit(let hash, let message):
            guard GitOperations.isObjectID(hash) else { throw AIJobError.noChanges }
            let env = try await backend.readEnvironment(cwd: cwd)
            let diff = try await DiffReader.patchText(.commit(hash), runner: backend.runner, cwd: cwd, env: env)
            let (kept, digest) = try aiChatFiltered(diff, worktree: worktree)
            return (AIPrompts.chatExplainCommitContext(message: message, diff: kept), digest)
        case .explainWorkingChanges:
            // Staged then unstaged: `git diff HEAD` would fail on an unborn branch.
            let env = try await backend.readEnvironment(cwd: cwd)
            async let staged = DiffReader.patchText(.staged, runner: backend.runner, cwd: cwd, env: env)
            async let unstaged = DiffReader.patchText(.unstaged, runner: backend.runner, cwd: cwd, env: env)
            let diff = try await staged + unstaged
            guard !diff.isEmpty else { throw AIJobError.noChanges }
            let (kept, digest) = try aiChatFiltered(diff, worktree: worktree)
            return (AIPrompts.chatExplainWorkingChangesContext(diff: kept), digest)
        case .commitMessage, .improveMessage, .squashMessage, .resolution, .pullRequest:
            throw AIJobError.noChanges
        }
    }

    /// The hidden context of attached references (`AIChatReference.resolve`) read with the read environment, filtered
    /// with the worktree's `.aiignore` (an unreadable one throws `aiIgnoreUnreadable`: nothing is resolved unfiltered),
    /// with the digest of that same `.aiignore`. When nothing resolved to data no request is sent: throws `allIgnored`
    /// when `.aiignore` left out every file of a diff, else `noChanges` (every diff empty, such as unstaged changes
    /// that are only untracked files, or a branch with nothing past its base).
    @concurrent
    nonisolated static func aiChatContext(
        _ references: [AIChatReference], backend: Backend, cwd: URL
    ) async throws -> AIChatModel.Context {
        let ignore = try aiIgnore(worktree: backend.directories.worktree)
        let env = try await backend.readEnvironment(cwd: cwd)
        let resolved = try await AIChatReference.resolve(
            references, runner: backend.runner, cwd: cwd, env: env, ignore: ignore)
        guard resolved.hasData else { throw resolved.allIgnored ? AIJobError.allIgnored : AIJobError.noChanges }
        return (resolved.text, AIIgnore.digest(ignore))
    }

    /// `aiFiltered` with the digest of the very `.aiignore` it filtered with (read once, so the two always agree).
    private nonisolated static func aiChatFiltered(_ diff: String, worktree: URL) throws -> (String, String) {
        let ignore = try aiIgnore(worktree: worktree)
        guard let kept = AIPrompts.filteredUnlessAllIgnored(diff, ignore: ignore) else { throw AIJobError.allIgnored }
        return (kept, AIIgnore.digest(ignore))
    }

    /// The worktree's current `AIIgnore.digest`, read off the main actor; throws `aiIgnoreUnreadable` when
    /// `.aiignore` can't be read, so the turn records that error and sends nothing.
    @concurrent
    nonisolated static func aiIgnoreDigest(worktree: URL) async throws -> String {
        AIIgnore.digest(try aiIgnore(worktree: worktree))
    }
}
