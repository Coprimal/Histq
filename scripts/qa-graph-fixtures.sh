# Fixture builders for scripts/qa-graph.sh (sourced, not run on its own).
#
# qa_fixture_table prints one line per fixture: "<name><TAB><description>". The builder of fixture <name> is the
# function qa_build_<name with - replaced by _>. qa-graph.sh calls it once per side, in a subshell with the
# isolation env, the dates counter at 0 and the working folder <root>/<fixture>/<side> (also passed as $1, an
# absolute physical path). A builder creates repo/ (and origin.git, teammate, ... as needed) there, writes the
# repo-local config with qa_local_config, makes commits with qa_commit / qa_tick, and ends with asserts (die).
#
# Determinism: every command that writes a commit or tag object (commit, merge, tag -a, stash push, amend,
# rebase) runs right after qa_tick, in the builder's own shell (never in a subshell, where the tick is lost), so
# both sides and every root get the same SHAs. Builders share the `core` history (qa_core) and add layers on it.

qa_fixture_table() {
  printf '%s\t%s\n' \
    core "Lịch sử gốc: main, develop, feature/login, hotfix, topic/series; sạch, origin đồng bộ" \
    core-wip "core + WIP bẩn trên main (staged, unstaged, xóa, untracked)" \
    stashes "core + 4 stash (index only, có untracked, xung đột, sạch)" \
    remote "core + lệch với origin (ahead/behind, rewrite, gone) + teammate" \
    conflicts "core + nhánh conflict/a xung đột với main (chưa dừng)" \
    stop-merge "conflicts + merge conflict/a đang dừng (4 file xung đột)" \
    stop-rebase "conflicts + rebase conflict/a lên main đang dừng ở k1" \
    stop-edit "core + rebase tương tác đang dừng ở bước edit (s3)" \
    rebase-lab "core + stack chồng nhau, nhánh có merge, orphan, 12 commit" \
    worktree "core + 2 worktree liên kết (wt-login có WIP, wt-detached)" \
    submodule "superproject với submodule libs/sub đã khởi tạo" \
    detached "core + HEAD tách rời với commit mồ côi x1" \
    marathon "remote + stash + WIP nhỏ + stack (kịch bản dài)"
}

# ---- Helpers ----
# qa_ctx <side dir>: names the fixture and side for assert messages.
qa_ctx() { QA_FX="$(basename "$(dirname "$1")")"; QA_SIDE="$(basename "$1")"; }

# qa_expect <what> <actual> <expected>: dies naming fixture, side and assert when they differ.
qa_expect() {
  [ "$2" = "$3" ] || die "$QA_FX/$QA_SIDE: assert failed: $1 (got '$2', want '$3')"
}

# qa_lines <file> <prefix> <count>: writes "<prefix> 1" .. "<prefix> <count>", one per line.
qa_lines() {
  mkdir -p "$(dirname "$1")"
  awk -v p="$2" -v n="$3" 'BEGIN { for (i = 1; i <= n; i++) print p " " i }' > "$1"
}

# qa_line <file> <n> <text>: replaces line n of the file.
qa_line() {
  awk -v n="$2" -v t="$3" 'NR == n { print t; next } { print }' "$1" > "$1.qa-tmp"
  mv "$1.qa-tmp" "$1"
}

# qa_save <subject>: stages everything (deletions too) and commits with the next fixed date.
qa_save() { git add -A; qa_commit "$1"; }

# qa_count <n>: strips the padding macOS wc -l puts around its number.
qa_count() { echo $(($1)); }

# qa_track <branch>: "<branch> <upstream:track>", e.g. "main [ahead 1, behind 1]" (in sync: "main ").
qa_track() { git for-each-ref --format='%(refname:short) %(upstream:track)' "refs/heads/$1"; }

# qa_subject <rev>: subject of a commit.
qa_subject() { git log -1 --format=%s "$1"; }

# qa_tm_git <args...>: git in <side>/teammate as "QA Teammate" (the env identity beats the local config).
qa_tm_git() {
  GIT_AUTHOR_NAME="QA Teammate" GIT_AUTHOR_EMAIL="teammate@histq.invalid" \
    GIT_COMMITTER_NAME="QA Teammate" GIT_COMMITTER_EMAIL="teammate@histq.invalid" \
    git -C "$QA_DIR/teammate" "$@"
}

# qa_seq_editor: path of a sequence editor that applies the sed script in $QA_SEQ_SED to the rebase todo.
qa_seq_editor() {
  local f="$HOME/qa-seq-editor.sh"
  if [ ! -f "$f" ]; then
    printf '%s\n' '#!/bin/sh' 'sed -e "$QA_SEQ_SED" "$1" > "$1.qa-tmp" && mv "$1.qa-tmp" "$1"' > "$f"
    chmod +x "$f"
  fi
  echo "$f"
}

# qa_origin <side dir>: bare origin.git and repo/ (origin = absolute path), with repo-local config; cd repo.
qa_origin() {
  git init -q --bare "$1/origin.git"
  git init -q "$1/repo"
  cd "$1/repo"
  qa_local_config .
  git remote add origin "$1/origin.git"
}

# ---- Shared layers ----
# qa_core <side dir>: the `core` history, pushed (topic/series local only), HEAD main, clean; asserts it.
# Sets C01..C06, D1, D2, F1..F3, H1, S1..S6. Leaves the cwd in repo/.
qa_core() {
  QA_DIR="$1"
  qa_ctx "$1"
  qa_origin "$1"
  printf '%s\n' '# QA repo' '' 'intro line' '' 'end' > README.md
  qa_lines src/app.txt "app line" 30
  qa_lines src/util.txt "util line" 10
  printf '%s\n' name=qa timeout=30 mode=fast retry=3 color=blue end=1 > config.ini
  qa_save "Initial commit"; C01="$(git rev-parse HEAD)"
  mkdir -p docs
  printf '%s\n' '# Notes' 'notes line 2' 'notes line 3' 'notes line 4' > docs/notes.md
  qa_save "Add notes"; C02="$(git rev-parse HEAD)"
  git tag v0.1
  qa_line config.ini 2 timeout=60
  qa_save "Tune config timeout"; C03="$(git rev-parse HEAD)"

  git checkout -q -b develop "$C03"
  qa_lines src/log.txt "log line" 3
  qa_save "Add logger"; D1="$(git rev-parse HEAD)"
  qa_line src/app.txt 5 "app line 5 (logged)"
  qa_save "Use logger in app"; D2="$(git rev-parse HEAD)"

  git checkout -q -b feature/login "$C03"
  qa_lines src/login.txt "login line" 6
  qa_save "Add login form"; F1="$(git rev-parse HEAD)"
  qa_line src/login.txt 3 "login line 3 (validated)"
  qa_save "Validate login input"; F2="$(git rev-parse HEAD)"
  qa_lines tests/login.txt "login test" 3
  qa_save "Add login tests"; F3="$(git rev-parse HEAD)"

  git checkout -q main
  qa_tick
  git merge -q --no-ff -m "Merge branch 'develop'" develop
  C04="$(git rev-parse HEAD)"
  qa_tick
  git tag -a v1.0 -m "Release 1.0" "$C04"

  git checkout -q -b hotfix "$C04"
  qa_line src/util.txt 7 "util line 7 (no crash on empty input)"
  qa_save "Fix crash on empty input"; H1="$(git rev-parse HEAD)"

  git checkout -q main
  qa_line README.md 3 "intro line (v1.1)"
  qa_save "Update README intro"; C05="$(git rev-parse HEAD)"

  git checkout -q -b topic/series "$C05"
  qa_lines docs/step-1.md "step 1 line" 3
  qa_save "Series: add step 1"; S1="$(git rev-parse HEAD)"
  qa_lines docs/step-2.md "step 2 line" 3
  qa_save "Series: add step 2"; S2="$(git rev-parse HEAD)"
  qa_lines docs/step-3.md "step 3 line" 3
  qa_save "Series: add step 3"; S3="$(git rev-parse HEAD)"
  qa_line docs/step-2.md 2 "step 2 line 2 (fixed)"
  qa_save "fixup! Series: add step 2"; S4="$(git rev-parse HEAD)"
  qa_line docs/step-1.md 1 "step 1 line 1 (typo fixed)"
  qa_save "Series: fix typo in step 1"; S5="$(git rev-parse HEAD)"
  qa_line docs/step-3.md 3 "step 3 line 3 (extended)"
  qa_save "Series: extend step 3"; S6="$(git rev-parse HEAD)"

  git checkout -q main
  qa_line config.ini 4 retry=5
  qa_save "Raise retry count"; C06="$(git rev-parse HEAD)"

  git push -q -u origin main develop feature/login hotfix
  git push -q origin v0.1 v1.0

  qa_expect "core: main first-parent count" "$(git rev-list --first-parent --count main)" 6
  qa_expect "core: merge parents" "$(git rev-list --parents -n 1 "$C04" | wc -w | tr -d ' ')" 3
  qa_expect "core: series count" "$(git rev-list --count "$C05..topic/series")" 6
  qa_expect "core: main vs origin/main" "$(git rev-list --left-right --count main...origin/main)" "0	0"
  qa_expect "core: main tip" "$(qa_subject main)" "Raise retry count"
  qa_expect "core: develop tip" "$(qa_subject develop)" "Use logger in app"
  qa_expect "core: feature/login tip" "$(qa_subject feature/login)" "Add login tests"
  qa_expect "core: hotfix tip" "$(qa_subject hotfix)" "Fix crash on empty input"
  qa_expect "core: topic/series tip" "$(qa_subject topic/series)" "Series: extend step 3"
  qa_expect "core: develop merged" "$(git merge-base --is-ancestor develop main && echo yes)" yes
  qa_expect "core: topic/series upstream" "$(git for-each-ref --format='%(upstream)' refs/heads/topic/series)" ""
  qa_expect "core: clean" "$(git status --porcelain -uall)" ""
}

# qa_teammate_clone: <side>/teammate, a clone of origin.git with the teammate identity in its local config.
qa_teammate_clone() {
  git clone -q "$QA_DIR/origin.git" "$QA_DIR/teammate"
  qa_local_config "$QA_DIR/teammate"
  git -C "$QA_DIR/teammate" config user.name "QA Teammate"
  git -C "$QA_DIR/teammate" config user.email "teammate@histq.invalid"
}

# qa_remote_layer: F04's divergences with origin (teammate commits pushed, local commits unpushed, rewritten
# series, gone upstream, unpushed tag v1.1). Runs in repo/ after qa_core; ends on main. Sets T1, F4, L1, D3, E1.
qa_remote_layer() {
  qa_teammate_clone
  printf '%s\n' '# Contributing' '' 'Open a pull request.' > "$QA_DIR/teammate/CONTRIBUTING.md"
  qa_tm_git add -A
  qa_tick
  qa_tm_git commit -q -m "Teammate: add contributing guide"
  T1="$(qa_tm_git rev-parse HEAD)"
  qa_tm_git checkout -q -b feature/login origin/feature/login
  qa_line "$QA_DIR/teammate/src/login.txt" 5 "login line 5 (polished copy)"
  qa_tm_git add -A
  qa_tick
  qa_tm_git commit -q -m "Teammate: polish login copy"
  F4="$(qa_tm_git rev-parse HEAD)"
  qa_tm_git checkout -q main
  qa_tm_git push -q origin main feature/login

  qa_line docs/notes.md 2 "notes line 2 (local tweak)"
  qa_save "Local: tweak notes"; L1="$(git rev-parse HEAD)"

  git checkout -q develop
  qa_line src/log.txt 2 "log line 2 (levels)"
  qa_save "Local: logger levels"; D3="$(git rev-parse HEAD)"

  git checkout -q topic/series
  git push -q -u origin topic/series
  qa_tick
  git commit -q --amend -m "Series: extend step 3 (reworded)"

  git checkout -q -b old/experiment "$C06"
  qa_lines src/theme.txt "theme line" 3
  qa_save "Experiment: try dark mode"; E1="$(git rev-parse HEAD)"
  git push -q -u origin old/experiment
  qa_tm_git push -q origin --delete old/experiment

  git checkout -q main
  git tag v1.1 "$C06"
  git fetch -q --prune origin
  qa_tm_git fetch -q --prune origin
}

# qa_remote_asserts <main track>: F04's asserts (main's track differs in marathon).
qa_remote_asserts() {
  qa_expect "remote: main track" "$(qa_track main)" "main $1"
  qa_expect "remote: develop track" "$(qa_track develop)" "develop [ahead 1]"
  qa_expect "remote: feature/login track" "$(qa_track feature/login)" "feature/login [behind 1]"
  qa_expect "remote: topic/series track" "$(qa_track topic/series)" "topic/series [ahead 1, behind 1]"
  qa_expect "remote: old/experiment track" "$(qa_track old/experiment)" "old/experiment [gone]"
  qa_expect "remote: hotfix track" "$(qa_track hotfix)" "hotfix "
  qa_expect "remote: origin/main tip" "$(qa_subject origin/main)" "Teammate: add contributing guide"
  qa_expect "remote: origin/feature/login tip" "$(qa_subject origin/feature/login)" "Teammate: polish login copy"
  qa_expect "remote: topic/series tip" "$(qa_subject topic/series)" "Series: extend step 3 (reworded)"
  qa_expect "remote: v1.1 not on origin" "$(git ls-remote --tags origin v1.1)" ""
  qa_expect "remote: teammate main = origin main" "$(qa_tm_git rev-parse main)" \
    "$(git --git-dir="$QA_DIR/origin.git" rev-parse main)"
  qa_expect "remote: HEAD" "$(git symbolic-ref HEAD)" refs/heads/main
}

# qa_conflict_layer: F05's conflict/a (from c06) and main's c07, main pushed (origin in sync). Ends on main.
# Sets K1..K3, C07.
qa_conflict_layer() {
  git checkout -q -b conflict/a "$C06"
  qa_line src/app.txt 12 "app line 12 (branch a)"
  printf '%s\n' "branch version" > src/new.txt
  rm docs/notes.md
  qa_save "Conflict A: app line 12, new file, drop notes"; K1="$(git rev-parse HEAD)"
  qa_line config.ini 2 timeout=90
  qa_save "Conflict A: timeout 90"; K2="$(git rev-parse HEAD)"
  qa_line src/util.txt 9 "util line 9 (branch a)"
  qa_save "Conflict A: util tweak"; K3="$(git rev-parse HEAD)"

  git checkout -q main
  qa_line src/app.txt 12 "app line 12 (main)"
  qa_line config.ini 2 timeout=45
  qa_line docs/notes.md 1 "# Notes (main)"
  printf '%s\n' "main version" > src/new.txt
  qa_save "Main: rework app line 12 and timeout"; C07="$(git rev-parse HEAD)"
  git push -q origin main
}

# qa_stack_layer: F09's stacked branches stack/one..three from c06. Ends on main. Sets B1..B6.
qa_stack_layer() {
  git checkout -q -b stack/one "$C06"
  qa_lines src/model.txt "model line" 3
  qa_save "Stack: base model"; B1="$(git rev-parse HEAD)"
  qa_line src/model.txt 2 "model line 2 (fields)"
  qa_save "Stack: model fields"; B2="$(git rev-parse HEAD)"
  git checkout -q -b stack/two
  qa_lines src/service.txt "service line" 3
  qa_save "Stack: service"; B3="$(git rev-parse HEAD)"
  qa_lines tests/service.txt "service test" 3
  qa_save "Stack: service tests"; B4="$(git rev-parse HEAD)"
  git checkout -q -b stack/three
  qa_lines src/ui.txt "ui line" 3
  qa_save "Stack: UI"; B5="$(git rev-parse HEAD)"
  qa_line src/ui.txt 3 "ui line 3 (polished)"
  qa_save "Stack: UI polish"; B6="$(git rev-parse HEAD)"
  git checkout -q main
}

qa_stack_asserts() {
  qa_expect "stacks: stack/one in stack/three" \
    "$(git merge-base --is-ancestor stack/one stack/three && echo yes)" yes
  qa_expect "stacks: stack/two in stack/three" \
    "$(git merge-base --is-ancestor stack/two stack/three && echo yes)" yes
  qa_expect "stacks: stack/three count" "$(git rev-list --count "$C06..stack/three")" 6
}

# qa_stash_untracked: F03's "with untracked" stash (src/app.txt line 25 + untracked tmp/cache.txt).
qa_stash_untracked() {
  qa_line src/app.txt 25 "app line 25 (stashed)"
  mkdir -p tmp
  printf '%s\n' "cache" > tmp/cache.txt
  qa_tick
  git stash push -q -u -m "with untracked"
}

# ---- Fixtures ----
qa_build_core() {
  qa_core "$1"
}

qa_build_core_wip() {
  qa_core "$1"
  qa_line src/app.txt 10 "app line 10 (staged)"
  git add src/app.txt
  qa_line src/app.txt 20 "app line 20 (unstaged)"
  printf '%s\n' "new module" > src/new-module.txt
  git add src/new-module.txt
  rm docs/notes.md
  mkdir -p scratch
  printf '%s\n' "todo" > scratch/todo.txt
  printf '%s\n' "notes copy" > "notes copy.txt"
  qa_expect "core-wip: status" "$(git status --porcelain -uall)" \
    "$(printf '%s\n' ' D docs/notes.md' 'MM src/app.txt' 'A  src/new-module.txt' '?? "notes copy.txt"' \
      '?? scratch/todo.txt')"
}

qa_build_stashes() {
  qa_core "$1"
  qa_line docs/notes.md 2 "notes line 2 (stashed edit)"
  qa_tick
  git stash push -q -m "notes edit"

  git checkout -q --detach "$C05"
  qa_line config.ini 4 retry=4
  qa_tick
  git stash push -q -m "retry tweak"
  git checkout -q main

  qa_stash_untracked

  qa_line src/util.txt 2 "util line 2 (index only)"
  git add src/util.txt
  qa_tick
  git stash push -q -m "index only"

  qa_expect "stashes: count" "$(qa_count "$(git stash list | wc -l)")" 4
  qa_expect "stashes: stash@{1}^3" "$(git rev-parse -q --verify 'stash@{1}^3' > /dev/null && echo yes)" yes
  qa_expect "stashes: stash@{2}^1" "$(git rev-parse 'stash@{2}^1')" "$C05"
  qa_expect "stashes: messages" "$(git stash list --format=%gs)" "$(printf '%s\n' 'On main: index only' \
    'On main: with untracked' 'On (no branch): retry tweak' 'On main: notes edit')"
  qa_expect "stashes: HEAD" "$(git symbolic-ref HEAD)" refs/heads/main
  qa_expect "stashes: clean" "$(git status --porcelain -uall)" ""
}

qa_build_remote() {
  qa_core "$1"
  qa_remote_layer
  qa_remote_asserts "[ahead 1, behind 1]"
  qa_expect "remote: clean" "$(git status --porcelain -uall)" ""
}

qa_build_conflicts() {
  qa_core "$1"
  qa_conflict_layer
  qa_expect "conflicts: merge-tree conflicted paths" \
    "$(qa_count "$( (git merge-tree --write-tree --name-only --no-messages main conflict/a || true) \
      | sed 1d | sort -u | grep -c . || true)")" 4
  qa_expect "conflicts: main tip" "$(qa_subject main)" "Main: rework app line 12 and timeout"
  qa_expect "conflicts: conflict/a tip" "$(qa_subject conflict/a)" "Conflict A: util tweak"
  qa_expect "conflicts: clean" "$(git status --porcelain -uall)" ""
}

qa_build_stop_merge() {
  qa_core "$1"
  qa_conflict_layer
  qa_tick
  git merge -q -m "Merge branch 'conflict/a'" conflict/a > /dev/null 2>&1 || true
  qa_expect "stop-merge: MERGE_HEAD" "$(git rev-parse -q --verify MERGE_HEAD || true)" "$K3"
  qa_expect "stop-merge: unmerged count" "$(qa_count "$(git diff --name-only --diff-filter=U | wc -l)")" 4
  qa_expect "stop-merge: status" "$(git status --porcelain -uall)" \
    "$(printf '%s\n' 'UU config.ini' 'UD docs/notes.md' 'UU src/app.txt' 'AA src/new.txt' 'M  src/util.txt')"
}

qa_build_stop_rebase() {
  qa_core "$1"
  qa_conflict_layer
  git checkout -q conflict/a
  qa_tick
  git rebase main > /dev/null 2>&1 || true
  qa_expect "stop-rebase: rebase-merge" "$([ -d .git/rebase-merge ] && echo yes)" yes
  qa_expect "stop-rebase: msgnum" "$(cat .git/rebase-merge/msgnum)" 1
  qa_expect "stop-rebase: end" "$(cat .git/rebase-merge/end)" 3
  qa_expect "stop-rebase: unmerged" "$(git diff --name-only --diff-filter=U)" \
    "$(printf '%s\n' docs/notes.md src/app.txt src/new.txt)"
  qa_expect "stop-rebase: stopped at" "$(git rev-parse -q --verify REBASE_HEAD || true)" "$K1"
}

qa_build_stop_edit() {
  qa_core "$1"
  git checkout -q topic/series
  qa_tick
  QA_SEQ_SED='/ Series: add step 3$/s/^pick/edit/' GIT_SEQUENCE_EDITOR="$(qa_seq_editor)" \
    git rebase -q -i --no-autosquash "$C05" > /dev/null 2>&1 || true
  qa_expect "stop-edit: rebase-merge" "$([ -d .git/rebase-merge ] && echo yes)" yes
  qa_expect "stop-edit: last done" "$(tail -n 1 .git/rebase-merge/done | cut -d' ' -f1)" edit
  qa_expect "stop-edit: HEAD" "$(git rev-parse HEAD)" "$S3"
  qa_expect "stop-edit: unmerged" "$(git diff --name-only --diff-filter=U)" ""
  qa_expect "stop-edit: clean" "$(git status --porcelain -uall)" ""
  qa_expect "stop-edit: todo" "$(grep -c '^pick' .git/rebase-merge/git-rebase-todo)" 3
}

qa_build_rebase_lab() {
  local n
  qa_core "$1"
  mkdir -p docs
  printf '%s\n' '# Main news' 'main moved on' > docs/main-news.md
  qa_save "Main moves on"
  git push -q origin main
  qa_stack_layer

  git checkout -q -b with-merge "$C05"
  printf '%s\n' '# Merge test' 'base' > docs/merge-test.md
  qa_save "Merge test: base"
  qa_tick
  git merge -q --no-ff -m "Merge branch 'hotfix' into with-merge" hotfix
  printf '%s\n' '# Merge test' 'base' 'after merge' > docs/merge-test.md
  qa_save "Merge test: after merge"

  git checkout -q --orphan orphan-docs
  git rm -q -rf .
  printf '%s\n' '# Docs root' 'start' > docs-root.md
  qa_save "Docs root: start"
  printf '%s\n' '# Docs root' 'start' 'middle' > docs-root.md
  qa_save "Docs root: middle"
  printf '%s\n' '# Docs root' 'start' 'middle' 'end' > docs-root.md
  qa_save "Docs root: end"

  git checkout -q -b long/twelve "$C06"
  mkdir -p long
  n=1
  while [ "$n" -le 12 ]; do
    printf '%s\n' "long file $n" > "long/f$n.txt"
    qa_save "Long: change file $n"
    n=$((n + 1))
  done
  git checkout -q main

  qa_stack_asserts
  qa_expect "rebase-lab: main tip" "$(qa_subject main)" "Main moves on"
  qa_expect "rebase-lab: with-merge merges" "$(git rev-list --merges --count "$C05..with-merge")" 1
  qa_expect "rebase-lab: with-merge count" "$(git rev-list --count "$C05..with-merge")" 4
  qa_expect "rebase-lab: orphan root" "$(git rev-list --max-parents=0 orphan-docs)" \
    "$(git rev-list --reverse orphan-docs | head -n 1)"
  qa_expect "rebase-lab: orphan root subject" "$(qa_subject "$(git rev-list --max-parents=0 orphan-docs)")" \
    "Docs root: start"
  qa_expect "rebase-lab: orphan count" "$(git rev-list --count orphan-docs)" 3
  qa_expect "rebase-lab: long count" "$(git rev-list --count "$C06..long/twelve")" 12
  qa_expect "rebase-lab: clean" "$(git status --porcelain -uall)" ""
}

qa_build_worktree() {
  qa_core "$1"
  git worktree add -q "$1/wt-login" feature/login
  qa_line "$1/wt-login/src/login.txt" 4 "login line 4 (worktree edit)"
  printf '%s\n' "worktree note" > "$1/wt-login/wt-note.txt"
  git worktree add -q --detach "$1/wt-detached" v1.0
  qa_expect "worktree: count" "$(git worktree list --porcelain | grep -c '^worktree ')" 3
  qa_expect "worktree: wt-login status" "$(git -C "$1/wt-login" status --porcelain -uall)" \
    "$(printf '%s\n' ' M src/login.txt' '?? wt-note.txt')"
  qa_expect "worktree: wt-detached HEAD" "$(git -C "$1/wt-detached" rev-parse HEAD)" "$C04"
  qa_expect "worktree: wt-detached clean" "$(git -C "$1/wt-detached" status --porcelain -uall)" ""
  qa_expect "worktree: main clean" "$(git status --porcelain -uall)" ""
}

qa_build_submodule() {
  local u1 u2 u3 p2
  QA_DIR="$1"
  qa_ctx "$1"
  git init -q "$1/sub-src"
  cd "$1/sub-src"
  printf '%s\n' '# Sub' > README.md
  qa_save "Sub: init"; u1="$(git rev-parse HEAD)"
  printf '%s\n' 'api v1' > api.txt
  qa_save "Sub: add api"; u2="$(git rev-parse HEAD)"
  printf '%s\n' 'api v1 (fixed)' > api.txt
  qa_save "Sub: fix api"; u3="$(git rev-parse HEAD)"
  git init -q --bare "$1/sub-origin.git"
  git remote add origin "$1/sub-origin.git"
  git push -q -u origin main

  qa_origin "$1"
  printf '%s\n' '# Superproject' > README.md
  qa_save "Initial superproject"
  git -c protocol.file.allow=always submodule add -q ../sub-origin.git libs/sub
  git -C libs/sub checkout -q "$u1"
  qa_save "Add submodule libs/sub"; p2="$(git rev-parse HEAD)"
  git -C libs/sub checkout -q "$u2"
  qa_save "Bump libs/sub to api"
  git branch sub-old "$p2"
  git checkout -q -b sub-new
  git update-index --cacheinfo "160000,$u3,libs/sub"
  qa_commit "Bump libs/sub to api fix"
  git checkout -q main
  git -c protocol.file.allow=always submodule update -q
  qa_local_config libs/sub
  git -C libs/sub config protocol.file.allow always
  git push -q -u origin main sub-old sub-new

  qa_expect "submodule: status" "$(git submodule status | cut -c1-$((${#u2} + 10)))" " $u2 libs/sub"
  qa_expect "submodule: .gitmodules url" "$(git config -f .gitmodules submodule.libs/sub.url)" ../sub-origin.git
  qa_expect "submodule: sub allow" "$(git -C libs/sub config protocol.file.allow)" always
  qa_expect "submodule: sub-new gitlink" "$(git rev-parse sub-new:libs/sub)" "$u3"
  qa_expect "submodule: sub-old gitlink" "$(git rev-parse sub-old:libs/sub)" "$u1"
  qa_expect "submodule: main tip" "$(qa_subject main)" "Bump libs/sub to api"
  qa_expect "submodule: clean" "$(git status --porcelain -uall)" ""
}

qa_build_detached() {
  qa_core "$1"
  git checkout -q --detach v1.0
  qa_line src/util.txt 3 "util line 3 (detached experiment)"
  qa_save "Detached experiment"
  qa_expect "detached: symbolic-ref" "$(git symbolic-ref -q HEAD || echo detached)" detached
  qa_expect "detached: branches containing HEAD" "$(git for-each-ref --contains HEAD refs/heads)" ""
  qa_expect "detached: parent" "$(git rev-parse HEAD^)" "$C04"
  qa_expect "detached: clean" "$(git status --porcelain -uall)" ""
}

qa_build_marathon() {
  qa_core "$1"
  qa_remote_layer
  qa_line docs/notes.md 4 "notes line 4 (footer)"
  qa_save "Local: notes footer"
  qa_stack_layer
  qa_line README.md 5 "end (stashed readme edit)"
  qa_tick
  git stash push -q -m "readme edit"
  qa_stash_untracked
  qa_line src/app.txt 20 "app line 20 (wip)"

  qa_remote_asserts "[ahead 2, behind 1]"
  qa_stack_asserts
  qa_expect "marathon: stash count" "$(qa_count "$(git stash list | wc -l)")" 2
  qa_expect "marathon: stash messages" "$(git stash list --format=%gs)" \
    "$(printf '%s\n' 'On main: with untracked' 'On main: readme edit')"
  qa_expect "marathon: status" "$(git status --porcelain)" " M src/app.txt"
}

# ---- Teammate actions (fixtures with a <side>/teammate clone) ----
# qa-graph.sh runs one action per side in a subshell with the isolation env (temp HOME) and QA_DIR = the side
# folder. The teammate first syncs to what origin.git holds now (the apps may have pushed), then commits with
# fixed dates T0 + (5000 + 100 * slot + n) h + k min: slot = the action's line in qa_teammate_table, n = how
# often this side already ran the action (<side>/teammate/.qa-count), k = the object's rank in the action. Two
# sides that ran the same sequence on the same origin get the same SHAs. Contents carry " #<n+1>" from the
# second run on, so a repeated action never makes an empty commit.

qa_teammate_fixtures() { echo remote marathon; }

# qa_teammate_table: "<action><TAB><description>", one line per action, in slot order.
qa_teammate_table() {
  printf '%s\t%s\n' \
    push-main "T2 \"Teammate: update notes\" (docs/notes.md dòng 2) lên origin/main; xung đột với L1 khi pull --rebase" \
    push-main-clean "T2c \"Teammate: add changelog\" (CHANGELOG.md mới) lên origin/main, không xung đột" \
    rewrite-main "force-push origin/main về c06 + T1r \"Teammate: add contributing guide (v2)\" (bỏ T1)" \
    force-push-feature "viết lại origin/feature/login: bỏ f4, f3 thành \"Add login tests (teammate)\"; force-push" \
    push-feature "thêm f5 \"Teammate: login error text\" lên origin/feature/login (để lease thất bại)" \
    push-branch "nhánh mới teammate/idea trên origin/main: i1 \"Idea: sketch\", i2 \"Idea: refine\"" \
    "delete-branch <name>" "xóa nhánh <name> trên origin (develop hoặc hotfix)" \
    push-tag "tag v1.2 (annotated \"Teammate release\") trên origin/main" \
    move-tag "force-move tag v1.0 trên origin sang c05 \"Update README intro\" (thử ghi đè tag)"
}

# qa_tm_slot <action>: the action's slot (0-based line in qa_teammate_table), or nothing when unknown.
qa_tm_slot() {
  qa_teammate_table | QA_A="$1" awk -F'\t' '{ split($1, w, " ") } w[1] == ENVIRON["QA_A"] { print NR - 1 }'
}

# qa_tm_date <k>: the dates of the action's k-th object (QA_TM_SLOT, QA_TM_N set by qa_tm_run).
qa_tm_date() {
  local t=$((T0 + (5000 + QA_TM_SLOT * 100 + QA_TM_N) * 3600 + $1 * 60))
  export GIT_AUTHOR_DATE="$t +0000" GIT_COMMITTER_DATE="$t +0000"
}

# qa_tm_save <k> <subject>: stages everything in the teammate clone and commits with the k-th date.
qa_tm_save() {
  qa_tm_git add -A
  qa_tm_date "$1"
  qa_tm_git commit -q -m "$2"
}

# qa_tm_find <rev> <subject>: the first commit with this exact subject on <rev>'s first-parent line, or nothing.
qa_tm_find() {
  qa_tm_git log --first-parent --format='%H%x09%s' "$1" |
    QA_S="$2" awk -F'\t' '!f && $2 == ENVIRON["QA_S"] { print $1; f = 1 }'
}

# qa_tm_on <branch> <start>: checks out <branch> reset to <start> (an origin ref or a SHA).
qa_tm_on() {
  qa_tm_git rev-parse -q --verify "$2^{commit}" > /dev/null || die "origin has no ${2#origin/}"
  qa_tm_git checkout -q -f -B "$1" "$2"
}

# qa_tm_sync: the teammate clone = origin now: fetch (pruned, tags forced), every local branch reset to its
# origin branch (local-only branches deleted), main checked out, clean tree (.qa-count kept: excluded).
qa_tm_sync() {
  local r
  qa_tm_git reset -q --hard
  qa_tm_git clean -q -fd
  qa_tm_git checkout -q --detach
  qa_tm_git fetch -q --prune --prune-tags --tags --force origin
  qa_tm_git for-each-ref --format='%(refname)' refs/heads | while IFS= read -r r; do
    qa_tm_git update-ref -d "$r"
  done
  qa_tm_git for-each-ref --format='%(refname:strip=3)' refs/remotes/origin | while IFS= read -r r; do
    [ "$r" = HEAD ] || qa_tm_git update-ref "refs/heads/$r" "refs/remotes/origin/$r"
  done
  if qa_tm_git rev-parse -q --verify refs/heads/main > /dev/null; then qa_tm_git checkout -q -f main; fi
}

# qa_tm_action <action> [name]: runs one action in the synced teammate clone and pushes; prints what it did.
qa_tm_action() {
  local t="$QA_DIR/teammate" sfx="" base
  [ "$QA_TM_N" -eq 0 ] || sfx=" #$((QA_TM_N + 1))"
  case "$1" in
    push-main)
      qa_tm_on main origin/main
      [ -f "$t/docs/notes.md" ] || die "origin/main has no docs/notes.md"
      qa_line "$t/docs/notes.md" 2 "notes line 2 (teammate)$sfx"
      qa_tm_save 0 "Teammate: update notes"
      qa_tm_git push -q origin main
      QA_TM_DID="pushed \"Teammate: update notes\" (docs/notes.md line 2) on main" ;;
    push-main-clean)
      qa_tm_on main origin/main
      printf '%s\n' '# Changelog' '' "- Teammate entry$sfx" > "$t/CHANGELOG.md"
      qa_tm_save 0 "Teammate: add changelog"
      qa_tm_git push -q origin main
      QA_TM_DID="pushed \"Teammate: add changelog\" (CHANGELOG.md) on main" ;;
    rewrite-main)
      base="$(qa_tm_find origin/main "Raise retry count")"
      [ -n "$base" ] || die "no \"Raise retry count\" (c06) on origin/main"
      qa_tm_on main "$base"
      printf '%s\n' '# Contributing' '' "Open a pull request (v2).$sfx" > "$t/CONTRIBUTING.md"
      qa_tm_save 0 "Teammate: add contributing guide (v2)"
      qa_tm_git push -q --force origin main
      QA_TM_DID="force-pushed main = c06 + \"Teammate: add contributing guide (v2)\"" ;;
    force-push-feature)
      base="$(qa_tm_find origin/feature/login "Validate login input")"
      [ -n "$base" ] || die "no \"Validate login input\" (f2) on origin/feature/login"
      qa_tm_on feature/login "$base"
      qa_lines "$t/tests/login.txt" "login test" 3
      qa_line "$t/tests/login.txt" 2 "login test 2 (teammate)$sfx"
      qa_tm_save 0 "Add login tests (teammate)"
      qa_tm_git push -q --force origin feature/login
      QA_TM_DID="force-pushed feature/login = f2 + \"Add login tests (teammate)\" (f3 rewritten, f4 dropped)" ;;
    push-feature)
      qa_tm_on feature/login origin/feature/login
      [ -f "$t/src/login.txt" ] || die "origin/feature/login has no src/login.txt"
      qa_line "$t/src/login.txt" 6 "login line 6 (error text)$sfx"
      qa_tm_save 0 "Teammate: login error text"
      qa_tm_git push -q origin feature/login
      QA_TM_DID="pushed \"Teammate: login error text\" on feature/login" ;;
    push-branch)
      qa_tm_on teammate/idea origin/main
      mkdir -p "$t/docs"
      printf '%s\n' '# Idea' "sketch$sfx" > "$t/docs/idea.md"
      qa_tm_save 0 "Idea: sketch"
      printf '%s\n' 'refined' >> "$t/docs/idea.md"
      qa_tm_save 1 "Idea: refine"
      qa_tm_git push -q --force origin teammate/idea
      QA_TM_DID="pushed teammate/idea: \"Idea: sketch\", \"Idea: refine\" (on origin/main)" ;;
    delete-branch)
      qa_tm_git rev-parse -q --verify "refs/remotes/origin/$2" > /dev/null || die "origin has no branch $2"
      qa_tm_git push -q origin --delete "$2"
      QA_TM_DID="deleted branch $2 on origin" ;;
    push-tag)
      qa_tm_git rev-parse -q --verify "origin/main^{commit}" > /dev/null || die "origin has no main"
      qa_tm_date 0
      qa_tm_git tag -f -a v1.2 -m "Teammate release" origin/main > /dev/null
      qa_tm_git push -q --force origin refs/tags/v1.2
      QA_TM_DID="pushed tag v1.2 (annotated \"Teammate release\") on main" ;;
    move-tag)
      base="$(qa_tm_find origin/main "Update README intro")"
      [ -n "$base" ] || die "no \"Update README intro\" (c05) on origin/main"
      qa_tm_date 0
      qa_tm_git tag -f -a v1.0 -m "Release 1.0" "$base" > /dev/null
      qa_tm_git push -q --force origin refs/tags/v1.0
      QA_TM_DID="force-moved tag v1.0 to c05 \"Update README intro\" on origin" ;;
    *) die "unknown teammate action: $1" ;;
  esac
}

# qa_tm_run <fixture> <side> <action> [name]: sync, action, counter bump, origin refs. Needs QA_DIR, isolation.
qa_tm_run() {
  local t="$QA_DIR/teammate" cf="$QA_DIR/teammate/.qa-count" ex
  ex="$t/.git/info/exclude"
  mkdir -p "$(dirname "$ex")"
  grep -qxF /.qa-count "$ex" 2>/dev/null || echo /.qa-count >> "$ex"
  [ -f "$cf" ] || : > "$cf"
  QA_TM_SLOT="$(qa_tm_slot "$3")"
  [ -n "$QA_TM_SLOT" ] || die "unknown teammate action: $3"
  QA_TM_N="$(QA_A="$3" awk '$1 == ENVIRON["QA_A"] { n = $2 } END { print n + 0 }' "$cf")"
  [ "$QA_TM_N" -lt 100 ] || die "$1/$2: $3 ran 100 times (dates would leave the fixture window): reset $1"
  qa_tm_sync
  QA_TM_DID=""
  qa_tm_action "$3" "${4:-}"
  # The counter moves as soon as the push is done (before any output that could fail).
  QA_A="$3" awk '$1 != ENVIRON["QA_A"]' "$cf" > "$cf.qa-tmp"
  echo "$3 $((QA_TM_N + 1))" >> "$cf.qa-tmp"
  mv "$cf.qa-tmp" "$cf"
  echo "teammate $1/$2: $3${4:+ $4} (run $((QA_TM_N + 1)))"
  echo "  $QA_TM_DID"
  echo "  origin refs now:"
  git -C "$QA_DIR/origin.git" for-each-ref \
    --format='    %(objectname) %(refname)%(if)%(*objectname)%(then) (tag of %(*objectname))%(end)'
}
