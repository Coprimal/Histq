// A tab's AI chat (`AIChatModel`): its saved chats live in `StatePaths.directory("ai-chat")/<stateKey>.json`, so each
// worktree has its own. Explain jobs open in the chat; their context is read off the main actor with the read
// environment and the worktree's `.aiignore`, and each send reads the `.aiignore` digest that decides which saved
// contexts may be sent again (one that can't be read fails the turn: nothing is sent). The chat's git tools run with
// the read environment (no profile) and the `.aiignore` read before each call. Only closing the tab or the window
// stops a running chat.
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
            },
            runTool: { [weak self] call in
                guard let backend = try? await self?.backend() else {
                    return (AIToolResult(id: call.id, content: Self.aiToolUnreadable, isError: true), nil, nil)
                }
                return await Self.aiChatTool(call, backend: backend, cwd: url)
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

    /// Explain Conflict: a new chat for the conflict region `target` (captured at the click) opens in this call and the
    /// card expands; the `.aiignore` check and the context are built off the main actor, then sent.
    func explainConflictInChat(_ target: AIResolutionTarget) {
        aiChat.isExpanded = true
        aiChat.startExplain(
            label: "Explain conflict \(target.conflict + 1) of \(target.path)",
            modelText: "Explain this merge conflict.", logName: "explain-conflict"
        ) { [weak self] in
            guard let worktree = try await self?.backend().directories.worktree else { throw CancellationError() }
            return try await Self.aiChatContext(target, worktree: worktree)
        }
    }

    /// Ask AI on a failure toast: a new chat shown as "Why did Push main fail?" opens in this call and the card
    /// expands; `title` (the operation, "Push main"), git's `message` (hook output included) and a failed commit's
    /// `commitMessage`, captured at the click, are filtered, redacted and cut off the main actor
    /// (`aiChatErrorContext`), then sent.
    func askAIAboutFailure(title: String, message: String, commitMessage: String? = nil) {
        let shown = String(AIPrompts.redactingSecrets(title).prefix(200))
        aiChat.isExpanded = true
        aiChat.startExplain(
            label: "Why did \(shown) fail?",
            modelText: "Explain why this git operation failed and how to fix it.", logName: "ask-ai"
        ) { [weak self] in
            guard let worktree = try await self?.backend().directories.worktree else { throw CancellationError() }
            return try await Self.aiChatErrorContext(
                title: title, message: message, commitMessage: commitMessage, worktree: worktree)
        }
    }

    /// A form the AI card can show over is up (`CreatePRView`, `InteractiveRebaseView`): Continue in Chat leaves it
    /// open, so the chat is seen only once it closes.
    var hasFormModal: Bool {
        pullRequestForm != nil || rebaseRequest != nil
    }

    /// Continue in Chat on a finished Apply-type card: closes only the AI card (a form under it stays, with its
    /// input), then a new chat is seeded in this call with the job's title as the user's line, a fixed sentence for
    /// the model, the job's data blocks (`AIPrompt.data`, never `AIPrompt.user`) as the hidden context, stamped with
    /// the digest of the `.aiignore` they were filtered with (`AIRun.ignoreDigest`), and the answer as the assistant's
    /// entry. Nothing is sent until the user follows up. The card opens at once, or once the form closes
    /// (`openAIChatAfterForm`).
    func continueInChat(run: AIRun) {
        guard let prompt = run.prompt, let answer = run.answer, let modelText = Self.seedModelText(run.job) else {
            return
        }
        closeAI()
        aiChat.seed(label: run.job.title, modelText: modelText, context: AIPrompts.chatSeedContext(prompt.data),
                    answer: Self.seedAnswer(answer), ignoreDigest: run.ignoreDigest)
        if hasFormModal {
            aiChatOpensAfterForm = true
        } else {
            aiChat.isExpanded = true
        }
    }

    /// A form closed (`rebaseRequest` or `pullRequestForm` set): opens the chat card Continue in Chat seeded over it,
    /// once no form is left.
    func openAIChatAfterForm() {
        guard aiChatOpensAfterForm, !hasFormModal else { return }
        aiChatOpensAfterForm = false
        aiChat.isExpanded = true
    }

    /// Continue in Chat on Suggest All's card: the regions that finished, each one's blocks after its "Conflict k:"
    /// line in one hidden context cut to `AIPrompts.diffBudget`, and one assistant entry listing their answers. The
    /// context is stamped with the regions' `.aiignore` digest only when every region was built with the same one;
    /// otherwise it has none, so it is omitted from every request.
    func continueInChat(batch: AIBatch) {
        let done = batch.targets.indices.compactMap { index -> (AIResolutionTarget, AIPrompt, String, String?)? in
            let run = batch.runs[index]
            guard let prompt = run.prompt, let answer = run.answer else { return nil }
            return (batch.targets[index], prompt, answer, run.ignoreDigest)
        }
        guard let first = done.first else { return }
        let path = first.0.path
        let ignoreDigest = done.allSatisfy { $0.3 == first.3 } ? first.3 : nil
        closeAI()
        let context = AIPrompts.chatSeedContext(conflicts: done.map { ($0.0.conflict + 1, $0.1.data) })
        let answers = done.map { target, _, answer, _ in
            let text = Self.seedAnswer(answer)
            let fence = String(repeating: "`", count: max(3, Self.longestBacktickRun(text) + 1))
            return "Conflict \(target.conflict + 1):\n\n\(fence)\n\(text)\(text.utf8.last == 0x0A ? "" : "\n")\(fence)"
        }
        aiChat.seed(
            label: "Suggest All for \(path)",
            modelText: "Earlier you wrote conflict resolutions for the data below; your answers follow.",
            context: context, answer: answers.joined(separator: "\n\n"), ignoreDigest: ignoreDigest)
        aiChat.isExpanded = true
    }

    /// The fixed sentence the model gets for a seeded job (no names or paths); nil for a job that is not Apply-type.
    private static func seedModelText(_ job: AIJob) -> String? {
        let what: String? = switch job {
        case .commitMessage: "a commit message"
        case .resolution: "a conflict resolution"
        case .pullRequest: "a pull request description"
        case .squashMessage: "a squash message"
        case .improveMessage: "an improved commit message"
        case .explainCommit, .explainWorkingChanges: nil
        }
        return what.map { "Earlier you wrote \($0) for the data below; your answer follows." }
    }

    /// The assistant's entry of a seed: an empty resolution ("delete both sides") as an app note, since an empty
    /// entry is never kept.
    private static func seedAnswer(_ answer: String) -> String {
        answer.allSatisfy(\.isWhitespace) ? "(An empty resolution: delete both sides.)" : answer
    }

    private static func longestBacktickRun(_ text: String) -> Int {
        var longest = 0
        var run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        return longest
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

    /// The header's AI button: a hidden bubble shows with its card open, a closed card opens, an open one closes and
    /// hides the bubble in every tab (a running turn goes on).
    func toggleAIChat() {
        if aiChat.isExpanded && !AISetup.shared.chatBubbleHidden {
            aiChat.isExpanded = false
            AISetup.shared.setChatBubbleHidden(true)
        } else {
            aiChat.isExpanded = true
        }
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

    /// The hidden context of an Explain Conflict turn (`AIPrompts.chatConflictContext`), with the digest of the
    /// worktree's `.aiignore`. Throws `fileIgnored` when that `.aiignore` excludes the file (as `.resolution` does) and
    /// `aiIgnoreUnreadable` when it can't be read, so nothing is sent.
    @concurrent
    nonisolated static func aiChatContext(
        _ target: AIResolutionTarget, worktree: URL
    ) async throws -> AIChatModel.Context {
        let ignore = try aiIgnore(worktree: worktree)
        if ignore?.matches(target.path) == true { throw AIJobError.fileIgnored }
        let text = AIPrompts.chatConflictContext(
            path: target.path, base: target.base, a: target.a, b: target.b, labels: target.labels,
            operation: target.operation)
        return (text, AIIgnore.digest(ignore))
    }

    /// The hidden context of an Ask AI turn (`AIPrompts.chatErrorContext`), with the digest of the worktree's
    /// `.aiignore`. git's output can quote repository files (a hook's linter, test or secret-scanner output), so its
    /// lines that name a file that `.aiignore` excludes are left out, and URL credentials and token-shaped secrets are
    /// masked, before it is cut. The digest is of the very `.aiignore` that filtered it, so a later change omits the
    /// context from follow-ups. Throws `aiIgnoreUnreadable` when `.aiignore` can't be read, so nothing is sent.
    @concurrent
    nonisolated static func aiChatErrorContext(
        title: String, message: String, commitMessage: String?, worktree: URL
    ) async throws -> AIChatModel.Context {
        let ignore = try aiIgnore(worktree: worktree)
        let text = AIPrompts.chatErrorContext(
            title: title, message: message, commitMessage: commitMessage, ignore: ignore)
        return (text, AIIgnore.digest(ignore))
    }

    /// `diff` through `AIPrompts.filtered` with the worktree's `.aiignore`, and the digest of that very `.aiignore`
    /// (read once, so the two always agree); throws `allIgnored` when `.aiignore` left out every file (only the
    /// closing note would be sent). An empty diff is returned as it is.
    nonisolated static func aiChatFiltered(_ diff: String, worktree: URL) throws -> (String, String) {
        let ignore = try aiIgnore(worktree: worktree)
        guard let kept = AIPrompts.filteredUnlessAllIgnored(diff, ignore: ignore) else { throw AIJobError.allIgnored }
        return (kept, AIIgnore.digest(ignore))
    }

    /// The error result of a tool call when the repository can't be read (no backend, no read environment).
    nonisolated static let aiToolUnreadable = "The repository can't be read; nothing was read."

    /// One git tool call of the chat (`AIGitTools.run`), off the main actor, with the read environment (never a
    /// profile) and the worktree's `.aiignore` loaded for this call, whose digest stamps the tool entry. An unreadable
    /// `.aiignore` gives a fixed error result and git never runs.
    @concurrent
    nonisolated static func aiChatTool(
        _ call: AIToolCall, backend: Backend, cwd: URL
    ) async -> AIChatModel.ToolRun {
        let ignore: AIIgnore?
        do {
            ignore = try aiIgnore(worktree: backend.directories.worktree)
        } catch {
            let message = "The .aiignore file can't be read; nothing was read."
            return (AIToolResult(id: call.id, content: message, isError: true), nil, nil)
        }
        guard let env = try? await backend.readEnvironment(cwd: cwd) else {
            return (AIToolResult(id: call.id, content: aiToolUnreadable, isError: true), nil, nil)
        }
        let output = await AIGitTools.run(call, runner: backend.runner, cwd: cwd, env: env, ignore: ignore)
        return (output.result, output.summary, AIIgnore.digest(ignore))
    }

    /// The worktree's current `AIIgnore.digest`, read off the main actor; throws `aiIgnoreUnreadable` when
    /// `.aiignore` can't be read, so the turn records that error and sends nothing.
    @concurrent
    nonisolated static func aiIgnoreDigest(worktree: URL) async throws -> String {
        AIIgnore.digest(try aiIgnore(worktree: worktree))
    }
}
