# Changelog

All notable changes to Histq are listed here. `scripts/publish-release.sh` uses the `## [X.Y.Z]` section of the version being released as the GitHub Release notes.

## [Unreleased]

### Added
- Commit graph of the whole history, fast even with tens of thousands of commits, with branches, tags, stashes, remotes, worktrees and search.
- Commit details panel with the commit's message, author and changed files.
- Staging of files, hunks or single lines, with unified and full-file diffs and syntax colors.
- Conflict editor: pick lines from side A and side B into the Output, or edit the Output by hand.
- Interactive rebase and squash from a sheet: reorder commits and pick, reword, edit, squash, fixup or drop them, with no editor.
- Undo and redo for local operations: commit, amend, checkout, reset, merge, rebase, cherry-pick, revert, branch create, delete and rename, and discard.
- Worktrees: add, open, remove and prune linked worktrees.
- Profiles: a per-tab identity, commit signing (GPG or SSH), SSH key and GitHub account, applied per git process without editing your `.git/config`. Histq can generate ed25519 keys and asks before it trusts a new SSH host key.
- Native macOS tabs or a vertical tab list, and the last session restored at launch.
- Command palette (Cmd-K): check out a branch, switch tabs, open settings or run any repository action from one search field.
- GitHub pull requests and issues: lists, details, reviews, merge, comments and a Create Pull Request form, with sign-in through the browser, a pasted token or the `gh` CLI's token.
- AI assistance from a cloud provider you choose (OpenAI, Anthropic, Google Gemini, xAI or an OpenAI-compatible server): commit messages, commit and change explanations, and conflict resolution suggestions.
- A terminal drawer per tab (Ctrl-`), started in the repository folder with the tab's profile.
- Automatic updates through Sparkle, and "Check for Updates…" in the Histq menu.

## [0.1.0] - YYYY-MM-DD

- First version.
