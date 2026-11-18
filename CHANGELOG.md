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
- Settings › AI › Commit messages: Summary only (Generate Message writes the summary line and keeps your description) and Custom instructions, added to the prompt and followed over its default style.
- Image files (PNG, JPEG, GIF, HEIC, WebP…) show their versions before and after the change, side by side, instead of "Binary file", for commits, staged and unstaged changes and untracked files.
- File History: every commit that changed a file, with Follow renames, from a file's context menu or the diff header's History button; a row opens the file's diff at that commit.
- Blame: who last changed each line of a file, at a commit or in the working tree, from a file's context menu or the diff header's Blame button.
- Compare two commits or branches, or a commit with the working tree, from a 2-row selection and from the branch and commit menus.
- Hide and Show a branch in the graph from its menu; a hidden branch is dimmed in the sidebar, and its eye shows it again.
- Solo one or more branches, so the graph shows only them and the current branch.
- Pin to Left: a pinned branch keeps the graph's leftmost lane.
- Hide Stale Branches (no commit for 90 days), from the Local and Remote cards' menus or the command palette.
- An "N hidden · Show All" chip over the graph while branches are hidden or soloed.
- Auto-stash: a checkout or pull with uncommitted changes asks Stash & Checkout, Carry Changes or Cancel (Stash & Pull or Cancel for a pull), with "Always do this"; Settings › General › Uncommitted changes sets Ask, Always stash or Never stash.
- When stashed changes cannot all come back, they stay in the stash and a toast names it ("Changes kept in stash 1a2b3c4"); a pull stopped on conflicts brings them back on continue or abort.
- Stash Changes in a file or folder from the WIP file menus; other staged files stay staged but are also saved in that stash.
- Apply This File from a stash's file menu, which asks first when the file has local changes.
- Undo of a Stash & Checkout whose stash held staged changes refuses, because bringing the stash back stages them again.
- Undo and redo for staging and unstaging whole files (Stage, Unstage, Stage All, Unstage All; not single lines or hunks).
- Undo and redo for stash save, drop, apply and pop: undoing a drop or a pop puts the stash back with its message.
- Undo and redo for creating and deleting local tags.
- Undo of resolving a conflicted file in the conflict editor while the merge, rebase, cherry-pick or revert is still stopped: the file's conflict comes back.
- Stacked layout (View menu, command palette or Settings › Appearance): a file diff, the conflict editor, file history, blame or a pull request opens in a pane under the graph, so the graph stays visible.
- Focus layout (Option-Cmd-F): the sidebar and detail panel hide and the graph or diff takes the whole width; Option-Cmd-F again returns to the layout used before.
- View › Reset Layout restores the default panel widths, the Stacked split and the Classic layout.
- Optimize Repository, from the toolbar's repository menu or the command palette: writes a commit-graph so history and the graph load faster in big repositories.
- Show Reflog: where HEAD has been, with Checkout, Create Branch Here and Copy SHA on each entry, and the commit's details even when it is no longer in the graph.
- Ignore an untracked file, all files with its extension or its folder from the WIP file and folder menus, in `.gitignore` or, with Exclude Locally, in `.git/info/exclude` (this clone only).

### Changed
- Commit details appear as soon as you click a commit, and their cards keep their place while the files load.
- Double-clicking the title bar or the tab row zooms or minimizes the window, as set in System Settings.
- The repository and branch dropdowns in the toolbar have a fixed width and cut long names with "…".
- The graph's selection highlight starts at the avatar, and avatars are as tall as the row.
- The graph column can be widened only as far as its lanes need.
- The conflict editor highlights the lines of each side and of the Output like GitKraken.
- New branch and laptop icons, and a filled check on the checked-out branch.
- A click on a branch checked out with uncommitted changes (in this worktree or another one), or on a worktree with changes in the Worktrees card, selects the row of those changes instead of the last commit; opening a worktree in a tab does the same.
- A click on another worktree's changes row in the graph shows its unstaged and staged files instead of opening it in a tab; a double-click in the Worktrees card or Open in New Tab opens it.
- The graph's WIP rows show how many files are edited, added and deleted, with GitKraken's icons, instead of "3 unstaged".
- Another worktree's changes row sits right above that worktree's last commit, as in GitKraken, instead of at the top of the graph.
- Cmd-Z right after staging a file now unstages it, instead of undoing the operation before it.
- A stash apply or pop that stops on conflicts shows a warning toast ("Applied with conflicts: this apply cannot be undone") instead of a failure; the conflicted files are in the WIP panel.

## [0.1.0] - YYYY-MM-DD

- First version.
