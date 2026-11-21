# Changelog

All notable changes to Histq are listed here. `scripts/publish-release.sh` uses the `## [X.Y.Z]` section of the version being released as the GitHub Release notes.

## [Unreleased]

### Added
- When an update is available, it downloads in the background and a green Update button shows in the toolbar: one click installs it and relaunches Histq. The app menu's item then reads "Install Update and Relaunch".
- "Merge X into Y" is a submenu with three choices: Fast-forward if possible, Fast-forward only, and Always create a merge commit (no fast-forward). The command palette lists each one as its own row.
- "Fast-forward the current branch to X" in a branch's menu: an undoable fast-forward-only merge, refused when the branches have diverged.
- A Submodules card in the sidebar, in repositories that have submodules: each submodule's recorded commit and state (Not initialized, Not checked out, New commits, its uncommitted changes, its branch), and a detail with the recorded and checked-out commits and the commits between.
- Submodule actions from a row's menu, the card's menu, the repository menu and the command palette: Open in New Tab, Initialize or Update, Sync URL, Stage New Pointer, Set URL…, Set Branch…, Copy, Reveal in Finder and Remove…, plus Add Submodule…, Update All and Sync All.
- A moved submodule pointer, in the working tree or in a commit, shows a card with the old and new commits and the commits between, instead of a text diff, with Open Submodule, Stage and Discard.
- Clone submodules (on by default) in the clone form clones the repository's submodules at every level after the clone.
- Settings › General › Update submodules automatically (on by default): after a checkout, pull, merge, rebase, reset, cherry-pick, revert, undo or redo, clean submodules move to the commit the repository now records. Submodules with new commits, uncommitted changes or a checked-out branch are left alone and named in a toast; a submodule that is not initialized is never cloned.
- Copy as Patch next to Save as Patch… in a commit's menu, and patches of several selected commits (adjacent or not, exported oldest first; also from the selected commits card's Patch menu), of the WIP row's Unstaged, Staged or All Changes (untracked files included), and of a single file in the WIP lists or a commit's files. Binary changes are included.
- Apply Patch… (a .patch or .diff file) and Apply Patch from Clipboard, in the repository menu, the File menu and the command palette: a preview lists the files with their +/− counts and says whether the patch applies cleanly, needs a 3-way merge or does not apply. Apply to Working Tree leaves the changes unstaged (staged after a 3-way merge, conflicts in the Conflicted card); Apply as Commits creates the commits of a patch made from commits, with their author and message, can be undone, and on a conflict shows a banner with Skip, Abort and Continue.
- Tab groups: Add Tab to New Group in a tab's menu (or Add Tabs to New Group after ⇧-clicking a range or ⌘-clicking several tabs) puts tabs in a group with a color and an optional name, shown as a chip before its tabs with a line under them. Click the chip to collapse or expand the group; Add Tab to Group and Remove from Group move tabs in and out. Groups are kept per window across launches.
- Right-click (or Control-click) a group's chip to rename it, pick one of 9 colors, open a New Tab in Group, Move Group to New Window, Close Group (⇧⌘T brings the whole group back) or Ungroup.
- Drag a tab into or out of a tab group, and drag a group by its chip to move all its tabs at once. A worktree tab moves inside its box until you drag it out, then the whole box moves.

### Changed
- The status bar under the window shows every operation while it runs, from the click on: toolbar actions, staging, commits, Edit Message, conflict saves, patch exports and GitHub pull request and issue actions, not only those started from a menu.
- Clicks react at once: a checkout shows its target branch and a "Checkout X" status in about 3 ms (was 150-200 ms); the commit box clears as soon as you click Commit (was about 200-250 ms) and gets the message back if the commit fails; a pull request opens in about 360 ms instead of 720-1000 ms, with checks and files filling in as they arrive, and opens again in about 45 ms instead of about 720 ms; merging a pull request shows it as merged at once; a pending mergeable state is asked again after about 1 s instead of 3 s; switching back to a tab no longer rereads its repository.
- Reads no longer list the repository's filter and diff drivers on every click: the list is kept while none of the config files it came from changed (40 far-apart commit clicks run 1 `git config` instead of about 240; a file click runs none instead of 2).
- Fewer git processes per action: a commit or checkout runs 32-36 git processes instead of 53-57, with one refresh instead of two, and the graph redraws sooner after a stash, rebase, fetch, pull or push (about 90-115 ms instead of 110-150 ms); clicking the WIP row again no longer reloads the open diff (12 git processes instead of 19); a hidden tab waits until it is shown to read changes made outside the app (one `git check-ignore` while it stays hidden, was 13 git processes); a tab shown again after such a change shows its WIP placeholder until the change is read, and only when a file that git does not ignore changed (build output and other ignored files leave its WIP as it was).
- Switching back to a recently shown tab (the last 4 in each window) shows it as it was, without building it again: it shows in about 30 ms instead of 45 ms, its longest frame is about 50-55 ms instead of 80 ms, and it costs about 25 MB more memory with 3 tabs. The keyboard goes to the shown tab: its open graph search, else its open diff or blame, else its graph.
- The tabs of one repository's worktrees sit together in a box, with no name and no collapse, instead of a named group.

### Fixed
- Discard on a submodule now puts it back on the recorded commit (it did nothing before).

## [0.2.0] - 2026-11-18

### Added
- Settings › Appearance › Commit list › Commit order: By date (the new default) lists the graph's commits newest first across branches, each still above its parents; By branch keeps each branch's commits together, as before.
- Branch and commit context menus gain Pull entries, Create and Copy submenus, "Interactive Rebase onto" a branch, Copy Link and Save as Patch.
- The footer shows the repo path next to the sidebar toggle.
- Copy Path in a tab's right-click menu.

### Changed
- Squash and interactive rebase work with uncommitted changes: they are stashed first and put back afterwards (a squash keeps staged changes staged).
- Staging and unstaging feel instant: the file moves to the other card as soon as you click, and each stage runs fewer git commands.
- The footer's repo path and version text are brighter, and ref badges use pure white text and icons with smaller names.

### Fixed
- The WIP panel shows at once from the last known status instead of waiting for a fresh read.

## [0.1.1] - 2026-11-18

### Added
- A footer under the window with toggles for the side panels, the app version and the running status of operations.
- Settings › AI checks an API key with its provider before saving it, and shows a toast saying whether the key was accepted.

## [0.1.0] - 2026-11-18

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
- Hide and Show a branch or tag from its menu: a hidden one leaves the graph and the sidebar list; the eye button in the Local, Remote or Tags card header lists the hidden rows dimmed, and a row's own eye shows it again.
- Solo one or more branches, so the graph shows only them and the current branch.
- Pin to Left: a pinned branch keeps the graph's leftmost lane.
- Hide Stale Branches (no commit for 90 days), from the Local and Remote cards' menus or the command palette.
- An "N hidden · Show All" chip over the graph while branches or tags are hidden or branches are soloed.
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
- Columns layout (View menu, command palette or Settings › Appearance): a file diff opens in a 4th column beside the detail panel, so the graph and the commit details stay visible.
- Customize Toolbar (right-click the toolbar or View › Customize Toolbar…): remove, move or add back the toolbar's groups and spaces; every window follows.
- View › Reset Layout restores the default panel widths and the Stacked split; the layout stays.
- Settings › Appearance can put the commit box on top, Staged above Unstaged, hide or reorder sidebar sections, and pick the default diff view (Diff, Split or Full file); ignore whitespace is also a setting.
- Text size (Settings › Appearance): Small, Regular or Large for the commit graph, the sidebar and the file lists, separate from row height.
- Code font size (Settings › Appearance › Diff): 11 to 16 pt for the diff, Blame, the conflict editor and the pull request diff; wrap long lines is also a setting.
- Optimize Repository, from the toolbar's repository menu or the command palette: writes a commit-graph so history and the graph load faster in big repositories.
- Show Reflog: where HEAD has been, with Checkout, Create Branch Here and Copy SHA on each entry, and the commit's details even when it is no longer in the graph.
- Ignore an untracked file, all files with its extension or its folder from the WIP file and folder menus, in `.gitignore` or, with Exclude Locally, in `.git/info/exclude` (this clone only).
- AI commit messages follow the branch name and the style of up to 5 recent commit subjects.
- AI requests keep only the header of lock and generated files (lockfiles, minified files, source maps, generated code).
- A `.aiignore` file at the repository root (gitignore-style patterns: `#` comments, `*`, `?`, `**`, `[...]`, `\` escapes, a leading or trailing `/`; case-insensitive; no `!` lines) keeps matching files out of every AI request.
- Generate Message works with Amend on: it covers the whole amended commit and improves the current message.
- Settings › AI › Explanations and Conflict resolution: Custom instructions, as for commit messages, and Reset to Default in each instructions box to clear it.
- Settings › AI › Show AI features: off hides every AI button.
- Regenerate in the AI card asks the provider again for a new answer.
- Conflict editor: Suggest Resolution sends the intent of the change (the message of the commit being replayed or cherry-picked, or the names of the branches being merged) and shows a short reason above the suggestion.
- Conflict editor: Suggest All suggests every unresolved conflict of a file, one request per conflict, each kept or skipped with its Use switch before Apply.
- Conflict editor: Undo AI puts the conflict editor back as it was before Apply from Suggest Resolution or Suggest All, in one step.
- Suggest Resolution and Suggest All are unavailable, with the reason, for a file matched by `.aiignore` or when `.aiignore` can't be read.
- Interactive rebase: Improve next to a reworded commit's message asks AI for a better message from the commit's diff and its current message; Apply puts it in the row.
- Create Pull Request: Generate next to Description writes the title and description with AI from the branch's commit messages, its diff against the base and the repository's pull request template; Apply fills the form.
- Settings › AI › Pull requests: Custom instructions, as for commit messages, with Reset to Default.
- Write a reply and Resolve or Unresolve conversation under each review thread of a pull request; threads collapse and expand with their chevron, and resolved ones start collapsed.
- Resolve with AI and Resolve manually in the merge box of a pull request with conflicts: Histq checks out its branch, merges the base branch into it and opens the conflict editor (Resolve with AI also starts Suggest All); commit and push to update the pull request.
