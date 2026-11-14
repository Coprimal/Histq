<div align="center">

<img src="assets/logo_512.png" width="128" alt="Histq icon">

# Histq

**A native macOS git client that drives the git you already have.**

[![Latest release](https://img.shields.io/github/v/release/dinhanhthi/Histq)](https://github.com/dinhanhthi/Histq/releases/latest)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue)](LICENSE)
![macOS 15+](https://img.shields.io/badge/macOS-15%2B-blue)

[Download](https://github.com/dinhanhthi/Histq/releases/latest) · [Changelog](CHANGELOG.md)

</div>

Histq is written in SwiftUI and AppKit. It runs the `git` command line tool on your Mac, so it works with your
existing repositories, config, SSH keys and hooks.

## Features

- **Commit graph**: a fast graph of the whole history (tens of thousands of commits), with branches, tags, stashes and
  remotes. A selected commit with no branch label shows a faded label of the branch it is on. When the graph column
  narrows, lanes fold into each other, and branch and tag labels shrink to "…", then to an icon. Settings, Appearance,
  Graph columns hides the message, author or date column.
- **Commit search** (Cmd-F): find commits by subject or hash prefix from a bar at the top of the graph; Enter and
  Shift-Enter move between matches and the other rows are dimmed.
- **Commit details**: a click shows the commit's message and author at once, then its changed files.
- **Staging and diffs**: stage files, hunks or single lines; unified and full-file diffs with syntax colors.
- **Conflict editor**: tick single lines (or a whole side) from side A and side B into the Output, or edit the Output
  by hand. With conflicts left, Save asks whether to save the Output as it is (and stage it) or to write git's conflict
  markers for the rest, leaving the file conflicted. Reset clears your choices, and leaving the editor with unsaved
  choices asks first.
- **Interactive rebase and squash**: reorder commits and pick, reword, edit, squash, fixup or drop them from a sheet,
  with no editor.
- **Undo and redo** for local operations: commit, amend, checkout, reset, merge, rebase, cherry-pick, revert, branch
  create, delete and rename, and discard. Operations that changed a remote (push, pull, remote branch and tag changes)
  cannot be undone.
- **Worktrees**: add, open, remove and prune linked worktrees.
- **Profiles and SSH**: per-tab identity, commit signing (GPG or SSH), SSH key and GitHub account. A profile is
  applied per git process; your `.git/config` is never edited. Histq can generate ed25519 keys and asks before it
  trusts a new SSH host key.
- **Tabs**: native macOS tabs or a vertical tab list, and session restore at launch.
- **Command palette** (Cmd-K): check out a branch, switch tabs, open settings or run any repository action from one
  search field.
- **GitHub pull requests and issues**: lists, details, reviews, merge, comments, and a Create Pull Request form.
- **AI assistance**: commit messages, commit and change explanations, and conflict resolution suggestions from a cloud
  provider you choose. Load models lists the provider's models to pick from, and explanations and commit messages each
  have their own response language.
- **Terminal**: a terminal drawer per tab (Ctrl-`), started in the repository folder with the tab's profile.

## Install

Download the `.dmg` from [Releases](https://github.com/dinhanhthi/Histq/releases/latest), drag Histq to
`/Applications` and launch it. Histq updates itself through [Sparkle](https://sparkle-project.org) (see Updates
below).

## Requirements

- macOS 15 or later, on Apple silicon.
- git 2.36 or later. The git from the Command Line Tools works (`xcode-select --install`); so does a git from
  Homebrew. You can pick the git binary in Settings.

## Privacy

Histq has no account, no analytics and no telemetry. It only talks to the network in the cases below.

### Git

Fetch, pull, push and clone contact your repository's remotes, as the `git` command would. Automatic fetch is off by
default; you can turn it on in Settings. When SSH meets an unknown host key, the "Trust host" banner reads that host's
keys with `ssh-keyscan` so you can compare the fingerprint; the key is added to `known_hosts` only when you confirm.

### GitHub (only with a connected account)

Histq makes no GitHub API request until you connect a GitHub account to a profile in Settings, Integrations.
(Git operations on a github.com remote and real avatars, below, are separate.)

- **Connecting** contacts the account's host: the OAuth device flow (`https://<host>/login/device/code` and
  `/login/oauth/access_token`, then the browser for the code), or one call to the API to check a pasted or imported
  token.
- **The token** is stored in the macOS Keychain. It is sent only to the profile's host (`api.github.com` for
  github.com, `https://<host>/api/v3` for GitHub Enterprise), and to git over HTTPS for that same host. Histq never
  attaches it to a request for another host, and git commands get it only when every URL they contact is
  `https://<profile host>/...` and the repository sets no network config of its own.
- **What the pull request features fetch**, for a repository tab whose remote is on the account's host: the lists of
  your open pull requests, pull requests waiting for your review, all open pull requests and issues assigned to you,
  and the check runs of the listed pull requests' head commits; for the pull request or issue you open, its details,
  comments, reviews, commits, changed files and check runs; for the Create Pull Request form, the repository's
  details, labels, assignable users and collaborators, and your own user. Lists load when the tab opens (for the branch
  badges in the graph), again when the window comes back after 30 seconds or more, and every 2 minutes while the Pull
  Requests tab is visible.
- **Writes** (create a pull request, comment, review, merge, close, reopen) happen only when you click the button.
- Pull request and issue bodies are shown with JavaScript off and with no remote content (no images or scripts are
  loaded). Links open in your browser.

### AI providers (only on a click)

Histq never calls an AI provider on its own. A request is sent only when you click an AI button (or Test Connection
or Load models in Settings), to the provider you chose:

| Action | What is sent |
| --- | --- |
| Generate commit message | the staged diff |
| Explain commit | the commit's message and diff |
| Explain changes | the uncommitted diff |
| Suggest resolution | the file path and one conflict region: side A, side B and their common base |
| Load models (Settings) | no repository content; only the API key, to list the provider's models |

Diffs are cut to about 24 KB per request. The request goes to the provider's own host: `api.openai.com`,
`api.anthropic.com`, `generativelanguage.googleapis.com` or `api.x.ai`, or the URL you enter for a custom
OpenAI-compatible provider (HTTPS, or plain HTTP only for this Mac). API keys are stored in the macOS Keychain and
are sent only to that provider. The answer is a preview: nothing is saved, staged or committed until you apply it.

### Avatars

By default, avatars in the graph are generated on your Mac from a hash of the author's email, with no network
request. Real avatars are opt-in (Settings, Appearance). When they are on, Histq sends the SHA-256 hash of each
author's email to `gravatar.com`, and for GitHub noreply addresses and pull request authors on github.com, the GitHub
user id or login to `avatars.githubusercontent.com`. These requests carry no token and no cookies.

### Updates

Histq checks for new versions with [Sparkle](https://sparkle-project.org). At most once a day, and when you choose
"Check for Updates…" in the Histq menu, it downloads the update feed
`https://raw.githubusercontent.com/dinhanhthi/Histq/main/appcast.xml` from GitHub. The request carries no token and
no system profile; its User-Agent names Histq's and Sparkle's versions. When you install an offered update, its
archive is downloaded from the project's GitHub releases. A build without Histq's update signing key
(`SUPublicEDKey` in `App/Info.plist`) never checks: "Check for Updates…" is then disabled.

### Nothing else

Apart from the cases above, nothing leaves your Mac. The terminal drawer runs your own shell locally; what you run in
it is up to you.

## Development

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Histq.xcodeproj -scheme Histq -configuration Debug -skipPackagePluginValidation build
```

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

© 2026 Anh-Thi Dinh. Licensed under the GNU General Public License v3.0 (GPL-3.0), see [LICENSE](LICENSE).
