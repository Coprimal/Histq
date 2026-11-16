# Changelog

All notable changes to Histq are listed here. `scripts/publish-release.sh` uses the `## [X.Y.Z]` section of the version being released as the GitHub Release notes.

## [Unreleased]

### Added
- Commit graph of the whole history, fast even with tens of thousands of commits, with branches, tags, stashes, remotes, worktrees, and search by commit subject or hash (Cmd-F).
- Commit details panel with the commit's message, author and changed files.
- Staging of files, hunks or single lines, with unified and full-file diffs and syntax colors.
- Conflict editor: tick single lines (or a whole side) from side A and side B into the Output, or edit the Output by hand.
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
- Load models in Settings › AI lists the provider's models to pick from.
- A response language for AI explanations and a separate language for AI commit messages, in Settings › AI.
- A faded branch label on a selected commit that has no branch label of its own.
- Graph lanes that fold into each other as the graph column narrows, down to one column of avatars, and branch and tag labels that shrink to "…", then to an icon.
- Settings › Appearance › Graph columns, to hide the message, author or date column.
- Conflict editor: Save with unresolved conflicts asks whether to Save Output (write and stage it) or Create Conflict Chunks (write git's conflict markers, the file stays conflicted).
- Conflict editor: a save prompt when you leave the editor with unsaved choices, and Reset in the Output pane.
- Toasts at the bottom right after a push, pull, fetch, commit or other operation, saying whether it worked or failed, and what a push, pull or fetch changed (or that there was nothing to do). They close after a few seconds or with their x; Settings › General › Notifications shows all, errors only or none.

### Changed
- Commit details appear as soon as you click a commit, and their cards keep their place while the files load.
- Double-clicking the title bar or the tab row zooms or minimizes the window, as set in System Settings.
- The repository and branch dropdowns in the toolbar have a fixed width and cut long names with "…".
- The graph's selection highlight starts at the avatar, and avatars are as tall as the row.
- The graph column can be widened only as far as its lanes need.
- The conflict editor highlights the lines of each side and of the Output like GitKraken.
- New branch and laptop icons, and a filled check on the checked-out branch.

## [0.1.0] - YYYY-MM-DD

- First version.
