// A tab's AI chat (`AIChatModel`): its saved chats live in `StatePaths.directory("ai-chat")/<stateKey>.json`, so each
// worktree has its own. Explain jobs open in the chat; their context is read off the main actor as `aiPrompt(for:)`
// reads the Explain prompts (read environment, `.aiignore`), and each send reads the `.aiignore` digest that decides
// which saved contexts may be sent again. Only closing the tab or the window stops a running chat.
import Foundation
import HistqCore

extension RepoSession {
    /// The chat of `aiChat`: every turn's system prompt takes Settings › AI's language and Explain instructions as
    /// they are at its click, and its `.aiignore` digest is the worktree's at its send (nil without a backend).
    func makeAIChat() -> AIChatModel {
        let file = StatePaths.directory("ai-chat")
            .appending(path: "\(Self.stateKey(url)).json", directoryHint: .notDirectory)
        return AIChatModel(
            storeURL: file,
            system: {
                AIPrompts.chatSystem(
                    language: Self.aiLanguages().response,
                    instructions: Preferences.defaults.string(forKey: PrefKey.aiExplainInstructions.rawValue) ?? "")
            },
            ignoreDigest: { [weak self] in
                guard let worktree = try? await self?.backend().directories.worktree else { return nil }
                return await Self.aiIgnoreDigest(worktree: worktree)
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

    /// The header's AI button: shows or hides the chat card (a running turn goes on).
    func toggleAIChat() {
        aiChat.isExpanded.toggle()
    }

    /// The tab or its window closed: stops the running turn (its partial answer is saved).
    func stopAIChat() {
        aiChat.stop()
    }

    /// The hidden context of an Explain turn: the commit's or the working changes' diff read with the read environment
    /// (never a profile), without what the worktree's `.aiignore` and the skip list leave out, as the Explain prompts
    /// of `aiPrompt` get it, with the digest of that `.aiignore`. Throws `noChanges` for a bad hash or no working
    /// changes, and for a job that is not an Explain.
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

    /// `aiFiltered` with the digest of the very `.aiignore` it filtered with (read once, so the two always agree).
    private nonisolated static func aiChatFiltered(_ diff: String, worktree: URL) throws -> (String, String) {
        let ignore = try aiIgnore(worktree: worktree)
        guard let kept = AIPrompts.filteredUnlessAllIgnored(diff, ignore: ignore) else { throw AIJobError.allIgnored }
        return (kept, AIIgnore.digest(ignore))
    }

    /// The worktree's current `AIIgnore.digest`, read off the main actor; nil when `.aiignore` can't be read, so
    /// every saved context counts as stale.
    @concurrent
    nonisolated static func aiIgnoreDigest(worktree: URL) async -> String? {
        do { return AIIgnore.digest(try aiIgnore(worktree: worktree)) } catch { return nil }
    }
}
