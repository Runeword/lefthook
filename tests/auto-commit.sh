#!/usr/bin/env bash
# Behavioural checks for scripts/auto-commit.sh (flake check
# `behaviour-auto-commit`). See tests/lib.sh for the result format.
#
# "Another terminal acting mid-split" is injected with lib.sh's `instrument`:
# the split builds every commit with `git commit-tree` before publishing any,
# so an injection after the Nth commit-tree lands between building and
# publishing, deterministically.
#
# Assertions are single-quoted strings that `res` evaluates later, so
# the linter sees neither their expansions nor the variables they read; and
# the repository's lint-shell hook runs it without -x.
# shellcheck disable=SC1091,SC2016,SC2034
set -u
# shellcheck source=tests/lib.sh
. "$TEST_LIB"

leftovers() { find .git -maxdepth 1 \( -name 'lefthook-split.*' -o -name lefthook-ac-predirty \) | wc -l; }
nsplit() { find .git -maxdepth 1 -name 'lefthook-split.*' | wc -l; }
staged() { git diff --cached --name-only | sort | tr '\n' ' '; }

# End-to-end config: prepare, a stage_fixed formatter that strips trailing
# blanks from *.txt (a stand-in for the shipped formatters), auto-commit.
cfg() {
  {
    printf 'no_auto_install: true\nmin_version: 1.13.0\npre-commit:\n  piped: true\n  jobs:\n'
    printf '    - name: auto-commit-prepare\n      run: %s --prepare\n' "$AUTO_COMMIT"
    printf '    - name: fmt\n      glob: "*.txt"\n      stage_fixed: true\n      run: sed -i -e "s/[[:space:]]*$//" {staged_files}\n'
    printf '    - name: auto-commit\n      run: %s\n' "$AUTO_COMMIT"
  } >lefthook.yml
  printf 'lefthook.yml\n' >>.git/info/exclude
  lefthook install >/dev/null 2>&1
}

# The fold regime without lefthook, as lefthook >= 2.1.7 leaves it to the
# finalize job (index = pre-format blob, worktree = formatted): prepare,
# format, split. $1 is the wrapper to split with (default: the real one). The
# prepare pass always runs the real one, so that an instrumented `git ls-files`
# (the index) or `git ls-tree` (HEAD) counts only the split's calls, which are
# reconcile's reads: 1 is its first look, without the lock, and 2 its read
# under the lock.
fold_split() {
  "$AUTO_COMMIT" --prepare
  find . -path ./.git -prune -o -name '*.txt' -type f -exec sed -i 's/[[:space:]]*$//' {} +
  "${1:-$AUTO_COMMIT}" >"$R.out" 2>&1
  echo $? >"$R.rc"
}

# A commit that only moves HEAD, made the way another terminal would.
foreign_commit() {
  git update-ref HEAD "$(git commit-tree "HEAD^{tree}" -p HEAD -m foreign)"
}

echo "## A. semantics (git commit end to end, lefthook $(lefthook version), $(git version))"
(
  newrepo a1 && cfg
  printf 'one\n' >a.txt
  mkdir -p d/e
  printf 'two\n' >d/e/b.txt
  printf 'x\n' >'with space.txt'
  printf 'u\n' >'ünïcode.txt'
  printf 'g\n' >'glob[1]*.txt'
  ln -s a.txt link
  printf '#!/bin/sh\n' >run.sh
  chmod +x run.sh
  git add -A && idx >"$R.staged"
  git commit -qm umbrella >"$R.out" 2>&1
  rc=$?
  res "A1 first commit: git commit exits 1 on success" PASS eq "$rc" 1
  res "A1 first commit: HEAD tree == staged snapshot" PASS cmp -s "$R.staged" <(headtree)
  res "A1 first commit: one commit per file (7)" PASS eq "$(commits)" 7
  res "A1 first commit: real index == HEAD, no leftovers" PASS eval '[ "$(idx)" = "$(headtree)" ] && [ "$(leftovers)" = 0 ]'
  res "A1 first commit: the summary line says it on purpose" PASS grep -q 'commits made. The original commit is cancelled on purpose' "$R.out"
)
(
  newrepo a2 && cfg
  printf 'l1\n' >m.txt
  printf 'old\n' >old.txt
  mkdir -p a
  printf 'ab\n' >a/b
  printf 'gone\n' >gone.txt
  git add -A && LEFTHOOK=0 git commit -qm base
  printf 'l2\n' >>m.txt
  rm gone.txt
  git mv old.txt new.txt
  rm -r a
  printf 'file now\n' >a
  mkdir n && printf 'x  \n' >n/x.txt
  git add -A && git commit -qm umbrella >"$R.out" 2>&1
  order=$(git log --format=%s | tac | tr '\n' ';')
  res "A2 mixed A/M/D + D/F + rename: HEAD == staged (+ formatter fix)" PASS eval '[ "$(git show HEAD:n/x.txt)" = x ] && [ -z "$(git status --porcelain)" ]'
  res "A2 D a/b committed before A a" PASS eval '[[ $order == *"Delete a/b;"*"Add a;"* ]]'
  res "A2 rename keeps A new before D old" PASS eval '[[ $order == *"Add new.txt;"*"Delete old.txt;"* ]]'
)
(
  # Partial staging end to end: lefthook sets the unstaged hunk aside, the
  # formatter fixes the staged part, lefthook restores the hunk.
  newrepo a3 && cfg
  printf 'p1\n' >p.txt && git add -A && LEFTHOOK=0 git commit -qm base
  printf 'p1\np2  \n' >p.txt && git add p.txt && printf 'p1\np2  \np3-UNSTAGED\n' >p.txt
  git commit -qm umbrella >"$R.out" 2>&1
  res "A3 partial stage: commit = staged + formatter fix" PASS eq "$(git show HEAD:p.txt)" "$(printf 'p1\np2')"
  res "A3 partial stage: unstaged hunk kept in worktree only" PASS eval 'grep -q p3-UNSTAGED p.txt && ! git show HEAD:p.txt | grep -q p3'
)
(
  newrepo a4 && cfg
  printf 'b\n' >b.txt && git add -A && LEFTHOOK=0 git commit -qm base
  git checkout -qb side && printf 's\n' >s.txt && git add s.txt && LEFTHOOK=0 git commit -qm side
  git checkout -q main && printf 'm\n' >m.txt && git add m.txt && LEFTHOOK=0 git commit -qm main
  git merge -q --no-commit side >/dev/null 2>&1
  git commit -qm merge >"$R.out" 2>&1
  rc=$?
  res "A4 merge conclusion passes through as one 2-parent commit" PASS eval '[ "$rc" = 0 ] && [ "$(git rev-list --parents -1 HEAD | wc -w)" = 3 ]'
  printf 'b2\n' >>b.txt && printf 'n\n' >n.txt && git add n.txt
  git commit -qam all >"$R.out" 2>&1
  rc=$?
  res "A4 commit -a passes through as one commit" PASS eval '[ "$rc" = 0 ] && [ "$(git log -1 --format=%s)" = all ]'
  printf 't\n' >"tab$(printf '\t')name.txt" && git add -A
  git commit -qm tab >"$R.out" 2>&1
  rc=$?
  res "A4 tab in filename passes through as one commit" PASS eval '[ "$rc" = 0 ] && [ "$(git log -1 --format=%s)" = tab ]'
)
(
  # Round 10's N1: index.lock held by someone else for the whole split.
  newrepo a5
  for i in 1 2 3; do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A && git commit -qm base
  for i in 1 2 3; do printf 'w%s\n' "$i" >>"f$i.txt"; done
  printf 'n\n' >new.txt && rm f3.txt && git add -A && idx >"$R.staged"
  : >.git/index.lock
  "$AUTO_COMMIT" >"$R.out" 2>&1
  rm -f .git/index.lock
  res "A5 index.lock held throughout: all 4 commits land, staging intact" PASS eval '[ "$(commits)" = 5 ] && [ "$(idx)" = "$(headtree)" ] && cmp -s "$R.staged" <(headtree)'
)
(
  # Round 10's N1 by timing: git status in a tight loop during a 300-path split.
  newrepo a6
  for i in $(seq 1 300); do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A && git commit -qm base
  for i in $(seq 1 300); do printf 'w\n' >>"f$i.txt"; done
  git add -A
  (while [ ! -e "$R.done" ]; do git status >/dev/null 2>&1; done) &
  p=$!
  "$AUTO_COMMIT" >"$R.out" 2>&1
  touch "$R.done"
  wait "$p"
  res "A6 concurrent git status loop: 300 commits land, staging intact" PASS eval '[ "$(commits)" = 301 ] && [ "$(idx)" = "$(headtree)" ]'
)

echo "## B. the documented design"
(
  newrepo b1
  printf 'a\n' >a && git add a && : >.git/index.lock
  res "B1 write-tree takes the lock (why the split copies the index first)" PASS eval '! git write-tree >/dev/null 2>&1'
  rm -f .git/index.lock
)
(
  newrepo b2
  for f in au sw keep fold; do printf '%s\n' "$f" >"$f.txt"; done
  git add -A && git commit -qm base
  git update-index --assume-unchanged au.txt
  git update-index --skip-worktree sw.txt
  sleep 1.1
  git status >/dev/null # settle the stat cache
  git ls-files --debug keep.txt >"$R.keep.before"
  printf 'fold2  \n' >fold.txt && printf 'new\n' >new.txt && git add fold.txt new.txt
  fold_split
  res "B2 split ran (2 commits)" PASS eq "$(commits)" 3
  res "B2 assume-unchanged bit survives on an untouched path" PASS eval 'git ls-files -v au.txt | grep -q "^h "'
  res "B2 skip-worktree bit survives on an untouched path" PASS eval 'git ls-files -v sw.txt | grep -q "^S "'
  res "B2 stat data survives for an untouched entry" PASS eval 'git ls-files --debug keep.txt | cmp -s - "$R.keep.before"'
  # Documented: reconcile rewrites a folded entry, so git re-reads that one
  # file at the next status.
  res "B2 stat data survives for a FOLDED entry (documented: it does not)" FAIL eval '! git ls-files --debug fold.txt | grep -q "mtime: 0:0"'
)
(
  # A staged path git does not compare with its working-tree file may hold a
  # local-only edit there that nobody staged, and that gitleaks never saw: it
  # keeps its staged blob, and so its flag. (Round-11 review: these folded the
  # working-tree file, edit included.) Under core.ignoreStat, staging the file
  # is what sets its assume-unchanged bit.
  for mode in assume-unchanged skip-worktree ignoreStat; do
    newrepo b2e-$mode
    printf 'p\n' >p.txt && printf 'q\n' >q.txt && git add -A && git commit -qm base
    if [ "$mode" = ignoreStat ]; then git config core.ignoreStat true; fi
    printf 'p2\n' >p.txt && git add p.txt
    if [ "$mode" != ignoreStat ]; then git update-index --"$mode" p.txt; fi
    flag=$(git ls-files -v p.txt | cut -c1)
    printf 'p2\nLOCAL-ONLY\n' >p.txt
    fold_split
    res "B2e $mode ($flag): the staged blob is committed, not the local edit" PASS eq "$(git show HEAD:p.txt)" p2
    res "B2e $mode ($flag): the flag survives" PASS eq "$(git ls-files -v p.txt | cut -c1)" "$flag"
  done
)
(
  # A path below a directory that became a symlink names whatever file the
  # link leads to, inside the repository or not.
  newrepo b2s
  mkdir -p d "$T/b2s-outside" && printf 'f\n' >d/f.txt && printf 'OUTSIDE\n' >"$T/b2s-outside/f.txt"
  git add -A && git commit -qm base
  printf 'f2\n' >d/f.txt && git add d/f.txt
  "$AUTO_COMMIT" --prepare
  rm -r d && ln -s "$T/b2s-outside" d
  "$AUTO_COMMIT" >"$R.out" 2>&1
  res "B2s a path below a symlinked directory keeps its staged blob" PASS eq "$(git show HEAD:d/f.txt)" f2
)
(
  # Process budget: three git processes per path (update-index, write-tree,
  # commit-tree) plus a constant, top-level processes only.
  count() { grep '"event":"start"' "$1" | sed 's/.*"sid":"\([^"]*\)".*/\1/' | grep -vc /; }
  for mode in nofold fold; do
    newrepo b3-$mode
    printf 'k\n' >keep && git add -A && git commit -qm base
    for i in $(seq 1 20); do printf 'v %s  \n' "$i" >"f$i.txt"; done
    git add -A
    if [ "$mode" = fold ]; then
      "$AUTO_COMMIT" --prepare
      sed -i 's/[[:space:]]*$//' -- *.txt
    fi
    GIT_TRACE2_EVENT=$R.trace "$AUTO_COMMIT" >"$R.out" 2>&1
    n=$(count "$R.trace")
    echo "   b3 $mode: $n top-level git processes for $(($(commits) - 1)) commits"
    res "B3 at most 3 git processes per path + 25 ($mode, 20 paths)" PASS eval '[ "$n" -le 85 ]'
  done
)
(
  # Killed outright mid-build (lefthook SIGKILLs a job on ^C): nothing is
  # published, so exactly the files staged before are still staged.
  for mode in nofold fold; do
    newrepo b4-$mode
    printf 'k\n' >keep && git add -A && git commit -qm base
    for i in $(seq 10 19); do printf 'v %s  \n' "$i" >"f$i.txt"; done
    git add -A && idx >"$R.staged"
    w=$(instrument "$AUTO_COMMIT" commit-tree 3 "kill -KILL \"\$(pgrep -o -f '${T}/shim.*/wrapper\$')\"")
    if [ "$mode" = fold ]; then fold_split "$w"; else "$w" >"$R.out" 2>&1; fi
    echo "   b4 $mode: commits=$(($(commits) - 1)) staged=$(git diff --cached --name-only | wc -l) split-dirs-left=$(nsplit)"
    res "B4 SIGKILL mid-split ($mode): nothing committed" PASS eq "$(commits)" 1
    res "B4 SIGKILL mid-split ($mode): the staging is exactly as before" PASS eval 'cmp -s "$R.staged" <(idx)'
  done
)
(
  # Every run sweeps split dirs left idle for an hour.
  newrepo b5
  printf 'a\n' >a.txt && git add -A && git commit -qm base
  stale() { mkdir -p .git/lefthook-split.STALE && touch -d '-2 hours' .git/lefthook-split.STALE; }
  stale
  "$AUTO_COMMIT" >/dev/null 2>&1
  res "B5 sweep on a run with nothing staged" PASS eval '[ ! -e .git/lefthook-split.STALE ]'
  stale
  printf 'b\n' >>a.txt
  cp .git/index .git/index.lock
  GIT_INDEX_FILE=$PWD/.git/index.lock "$AUTO_COMMIT" >/dev/null 2>&1
  rm -f .git/index.lock
  res "B5 sweep on a commit -a / pathspec run" PASS eval '[ ! -e .git/lefthook-split.STALE ]'
  stale
  "$AUTO_COMMIT" --prepare
  res "B5 sweep on the --prepare run" PASS eval '[ ! -e .git/lefthook-split.STALE ]'
  stale
  git add a.txt
  "$AUTO_COMMIT" >/dev/null 2>&1
  res "B5 sweep on a real split" PASS eval '[ ! -e .git/lefthook-split.STALE ]'
  mkdir .git/lefthook-split.FRESH
  "$AUTO_COMMIT" --prepare
  res "B5 a split dir idle for less than an hour is left alone" PASS eval '[ -e .git/lefthook-split.FRESH ]'
)

echo "## C. other terminals acting mid-split (2026-10-11 candidates, round-11 findings)"
(
  # G1: another commit lands between building and publishing.
  newrepo g1
  printf 'k\n' >keep && git add -A && git commit -qm base
  for i in 1 2 3 4 5; do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A && idx >"$R.staged"
  w=$(instrument "$AUTO_COMMIT" commit-tree 2 "$(declare -f foreign_commit); foreign_commit")
  "$w" >"$R.out" 2>&1
  rc=$?
  res "G1 HEAD moved mid-split: exit 3, not success (1)" PASS eq "$rc" 3
  res "G1 HEAD moved mid-split: nothing published on top of the foreign commit" PASS eval '[ "$(git log -1 --format=%s)" = foreign ] && [ "$(commits)" = 2 ]'
  res "G1 HEAD moved mid-split: the staging is exactly as before" PASS eval 'cmp -s "$R.staged" <(idx)'
  res "G1 HEAD moved mid-split: it says nothing was committed" PASS grep -q 'nothing was committed and everything is still staged' "$R.out"
)
(
  # G7: an unborn branch that another terminal gives a first commit meanwhile.
  newrepo g7
  for i in 1 2 3; do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A
  w=$(instrument "$AUTO_COMMIT" commit-tree 1 'git update-ref refs/heads/main "$(git commit-tree "$(git hash-object -t tree /dev/null)" -m root)"')
  "$w" >"$R.out" 2>&1
  rc=$?
  res "G7 unborn branch born mid-split: exit 3, the foreign root commit stays alone" PASS eval '[ "$rc" = 3 ] && [ "$(commits)" = 1 ] && [ "$(git log -1 --format=%s)" = root ]'
)
(
  # G2: a formatter returns a staged change to HEAD's content.
  newrepo g2
  printf 'a\n' >a.txt && printf 'b\n' >b.txt && printf 'c\n' >c.txt && git add -A && git commit -qm base
  printf 'a2\n' >a.txt && printf 'b  \n' >b.txt && printf 'c2\n' >c.txt && git add -A
  fold_split
  res "G2 formatter reverts a staged change: the other files are still committed" PASS eval '[ "$(git show HEAD:c.txt)" = c2 ] && [ "$(git show HEAD:a.txt)" = a2 ] && [ "$(commits)" = 3 ]'
  res "G2 formatter reverts a staged change: no empty commit, status clean" PASS eval '[ -z "$(git status --porcelain)" ] && grep -q "b.txt (left out" "$R.out"'
)
(
  # G2, every staged change undone by the formatter: nothing to commit.
  newrepo g2all
  printf 'b\n' >b.txt && git add -A && git commit -qm base
  printf 'b  \n' >b.txt && git add -A
  fold_split
  res "G2 nothing left after formatting: no commit, exit 1, status clean" PASS eval '[ "$(commits)" = 1 ] && [ "$(cat "$R.rc")" = 1 ] && [ -z "$(git status --porcelain)" ]'
)
(
  # G8: a branch switch mid-split.
  newrepo g8
  printf 'k\n' >keep && git add -A && git commit -qm base
  for i in 1 2 3 4; do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A
  w=$(instrument "$AUTO_COMMIT" commit-tree 1 'git switch -q -c side')
  "$w" >"$R.out" 2>&1
  rc=$?
  res "G8 branch switched mid-split: exit 3, no split commit on either branch" PASS eval '[ "$rc" = 3 ] && [ "$(git rev-list --count main)" = 1 ] && [ "$(git rev-list --count side)" = 1 ]'
)
(
  # Round 11 A1: another terminal unstages everything (git reset) mid-split.
  for mode in nofold fold; do
    newrepo reset-$mode
    for f in m1.txt m2.txt m3.txt m4.md; do printf '%s\n' "$f" >"$f"; done
    git add -A && git commit -qm base
    for f in m1.txt m2.txt m3.txt m4.md; do printf 'new  \n' >>"$f"; done
    printf 'n5\n' >n5.md && git add -A
    w=$(instrument "$AUTO_COMMIT" commit-tree 2 'git reset -q')
    if [ "$mode" = fold ]; then fold_split "$w"; else "$w" >"$R.out" 2>&1; fi
    res "A1 git reset mid-split ($mode): all 5 commits land" PASS eval 'fired "$w" && [ "$(commits)" = 6 ]'
    res "A1 git reset mid-split ($mode): index == HEAD, the next commit reverts nothing" PASS eval 'fired "$w" && [ "$(idx)" = "$(headtree)" ] && git diff --cached --quiet'
  done
)
(
  newrepo restore
  for f in a.txt b.txt c.txt; do printf '%s\n' "$f" >"$f"; done
  git add -A && git commit -qm base
  for f in a.txt b.txt c.txt; do printf 'more\n' >>"$f"; done
  git add -A
  w=$(instrument "$AUTO_COMMIT" commit-tree 1 'git restore --staged b.txt')
  "$w" >"$R.out" 2>&1
  res "A1 git restore --staged of one path mid-split: index == HEAD afterwards" PASS eval 'fired "$w" && [ "$(commits)" = 4 ] && [ "$(idx)" = "$(headtree)" ]'
)
(
  # G11: a newer version of a folded path staged mid-split stays staged.
  newrepo g11
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'a  \n' >a.txt && printf 'b\n' >b.txt && git add -A
  w=$(instrument "$AUTO_COMMIT" commit-tree 1 'printf "a-newer\n" >a.txt && git add a.txt')
  fold_split "$w"
  res "G11 newer staging of a folded path made mid-split survives" PASS eval 'fired "$w" && [ "$(git ls-files -s a.txt | cut -d" " -f2)" = "$(git hash-object a.txt)" ] && [ "$(git show HEAD:a.txt)" = a ]'
)
(
  # G6b: a MODIFIED path the user unstages mid-split (git rm --cached) stays
  # out of the index.
  newrepo g6b
  printf 'a\n' >a.txt && printf 'b\n' >b.txt && git add -A && git commit -qm base
  printf 'a2  \n' >a.txt && printf 'b2  \n' >b.txt && git add -A
  w=$(instrument "$AUTO_COMMIT" commit-tree 1 'git rm -qf --cached a.txt')
  fold_split "$w"
  res "G6b git rm --cached of a modified path mid-split is kept" PASS eval '[ -z "$(git ls-files a.txt)" ] && [ "$(git ls-files -s b.txt | cut -d" " -f2)" = "$(git rev-parse HEAD:b.txt)" ]'
)
(
  # Round-11 review: reconcile read the index without index.lock and wrote it
  # later, so a git add or a commit landing in between was overwritten: the add
  # undone, the commit reverted by the next one. Injected after each of its
  # reads (see fold_split), the other terminal's work must survive, or be
  # refused (the lock is held) so that it can retry, but never be overwritten.
  for at in 1 2; do
    newrepo lock-add-$at
    printf 'k\n' >keep && git add -A && git commit -qm base
    printf 'a  \n' >a.txt && printf 'b\n' >b.txt && git add -A
    w=$(instrument "$AUTO_COMMIT" ls-files "$at" 'printf "a-newer\n" >a.txt; git add a.txt; echo $? >.git/other-rc')
    fold_split "$w"
    echo "   lock-add-$at: other git add exited $(cat .git/other-rc 2>/dev/null || echo -)"
    res "L$at git add as reconcile reads the index: refused or kept, never overwritten" PASS eval 'fired "$w" && { [ "$(cat .git/other-rc)" != 0 ] || [ "$(git ls-files -s a.txt | cut -d" " -f2)" = "$(git hash-object a.txt)" ]; }'
    res "L$at git add as reconcile reads the index: index.lock released" PASS eval '[ ! -e .git/index.lock ]'

    newrepo lock-commit-$at
    printf 'k\n' >keep && git add -A && git commit -qm base
    printf 'a  \n' >a.txt && printf 'b\n' >b.txt && git add -A
    w=$(instrument "$AUTO_COMMIT" ls-tree "$at" 'printf "a-newer\n" >a.txt && git add a.txt && git commit -qm other')
    fold_split "$w"
    res "L$at commit as reconcile reads the index: the next commit reverts nothing" PASS eval 'fired "$w" && git diff --cached --quiet'
  done
)
(
  # index.lock held for a moment as reconcile starts: it waits its turn.
  newrepo lock-wait
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'a  \n' >a.txt && git add -A
  w=$(instrument "$AUTO_COMMIT" ls-files 1 ': >.git/index.lock; (sleep 0.5; rm -f .git/index.lock) &')
  fold_split "$w"
  res "L3 index.lock held for 0.5 s: reconcile waits, then brings the index up to date" PASS eval 'fired "$w" && [ "$(idx)" = "$(headtree)" ] && [ ! -e .git/index.lock ]'
)
(
  # index.lock held throughout: the commits are public, so reconcile names
  # what to bring up to date, and leaves the other process's lock alone.
  newrepo lock-held
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'a  \n' >a.txt && git add -A
  w=$(instrument "$AUTO_COMMIT" ls-files 1 ': >.git/index.lock')
  fold_split "$w"
  held=$([ -e .git/index.lock ] && echo yes)
  rm -f .git/index.lock
  res "L4 index.lock held throughout: committed, a.txt named to bring up to date, the lock left alone" PASS eval '[ "$(git show HEAD:a.txt)" = a ] && grep -q "^  a.txt$" "$R.out" && [ "$held" = yes ]'
)
(
  # The index unreadable once the commits are public: reconcile has no plan, so
  # it names every path the split handled. The list it printed was empty.
  # (2026-10-24.)
  newrepo lock-unread
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'a  \n' >a.txt && printf 'b\n' >b.txt && git add -A
  w=$(instrument "$AUTO_COMMIT" update-ref 1 'cp .git/index .git/index.saved && printf garbage >.git/index')
  fold_split "$w"
  if [ -e .git/index.saved ]; then mv .git/index.saved .git/index; fi
  res "L5 index unreadable after publishing: committed, every path the split handled named, no lock left" PASS eval 'fired "$w" && [ "$(commits)" = 3 ] && grep -q "^  a.txt$" "$R.out" && grep -q "^  b.txt$" "$R.out" && [ ! -e .git/index.lock ]'
)
(
  # Documented ambiguity: unstaging a NEW path mid-split stages exactly its
  # base state (absent), which is what a reset looks like; the split re-stages
  # what it committed so the index matches HEAD.
  newrepo g6new
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'a  \n' >a.txt && printf 'b  \n' >b.txt && git add -A
  w=$(instrument "$AUTO_COMMIT" commit-tree 1 'git rm -qf --cached a.txt')
  fold_split "$w"
  res "G6 unstaging a new path mid-split: re-staged to match HEAD (documented)" PASS eval 'fired "$w" && [ "$(git ls-files -s a.txt | cut -d" " -f2)" = "$(git rev-parse HEAD:a.txt)" ]'
)

echo "## D. publishing, signing, hooks, guards, scale"
(
  newrepo d1
  printf 'k\n' >keep && git add -A && git commit -qm base
  n0=$(git reflog | wc -l)
  for i in 1 2 3; do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A && "$AUTO_COMMIT" >"$R.out" 2>&1
  res "D1 one reflog entry for the whole split" PASS eval '[ "$(git reflog | wc -l)" = $((n0 + 1)) ] && git reflog -1 --format=%gs | grep -q "auto-commit: split into 3 commits"'
  res "D1 commit messages are Add <path>" PASS eq "$(git log --format=%s -3 | tac | tr '\n' ';')" "Add f1.txt;Add f2.txt;Add f3.txt;"
)
(
  newrepo d2
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'x\n' >'end ' && git add -A && "$AUTO_COMMIT" >"$R.out" 2>&1
  res "D2 a path ending in a space: message trimmed as git commit -m does" PASS eq "$(git cat-file commit HEAD | tail -n 1)" "Add end"
)
(
  # commit-tree runs no hooks: a post-commit hook (not a message check, so no
  # pass-through) sees none of the per-file commits.
  newrepo d2h
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf '#!/bin/sh\ntouch "%s"\n' "$R.post-commit-ran" >.git/hooks/post-commit
  chmod +x .git/hooks/post-commit
  printf 'a\n' >a.txt && git add -A && "$AUTO_COMMIT" >"$R.out" 2>&1
  res "D2h the per-file commits run no post-commit hook" PASS eval '[ "$(commits)" = 2 ] && [ ! -e "$R.post-commit-ran" ]'
)
(
  newrepo d3
  git commit -q --allow-empty -m base
  git checkout -q --detach
  for i in 1 2; do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A && "$AUTO_COMMIT" >"$R.out" 2>&1
  res "D3 detached HEAD: the split advances HEAD, no branch moves" PASS eval '[ "$(commits)" = 3 ] && [ "$(git rev-list --count main)" = 1 ] && ! git symbolic-ref -q HEAD'
)
(
  # Signing: commit-tree ignores commit.gpgSign, so the split passes -S.
  newrepo d4
  printf 'k\n' >keep && git add -A && git commit -qm base
  cat >"$T/gpg-ok" <<'EOF'
#!/bin/sh
cat >/dev/null
printf '\n[GNUPG:] SIG_CREATED D 1 8 00 1700000000 0123456789ABCDEF\n' >&2
printf -- '-----BEGIN PGP SIGNATURE-----\n\nZmFrZQ==\n-----END PGP SIGNATURE-----\n'
EOF
  printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$T/gpg-fail"
  chmod +x "$T/gpg-ok" "$T/gpg-fail"
  git config commit.gpgSign true
  git config gpg.program "$T/gpg-ok"
  for i in 1 2; do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A && "$AUTO_COMMIT" >"$R.out" 2>&1
  res "D4 commit.gpgSign: every split commit is signed" PASS eval '[ "$(commits)" = 3 ] && git cat-file commit HEAD | grep -q "^gpgsig " && git cat-file commit HEAD~1 | grep -q "^gpgsig "'
  git config gpg.program "$T/gpg-fail"
  printf 'v3\n' >f3.txt && printf 'v4\n' >f4.txt && git add -A && idx >"$R.staged"
  "$AUTO_COMMIT" >"$R.out" 2>&1
  rc=$?
  echo "   d4 signer fails: rc=$rc commits=$(commits) split-dirs=$(nsplit) staged-intact=$(cmp -s "$R.staged" <(idx) && echo yes || echo no)"
  res "D4 signer fails: nothing published, staging intact, not success" PASS eval '[ "$(commits)" = 3 ] && cmp -s "$R.staged" <(idx) && [ "$rc" != 0 ] && [ "$rc" != 1 ] && [ "$(nsplit)" = 0 ]'
  res "D4 signer fails: it says nothing was committed" PASS grep -q 'nothing was committed and everything is still staged' "$R.out"
)
(
  # A commit-msg hook (installed, or under core.hooksPath) keeps the commit
  # whole so the hook sees its message.
  newrepo d5 && cfg
  printf 'k\n' >keep && git add -A && LEFTHOOK=0 git commit -qm base
  printf '#!/bin/sh\ngrep -q "^TICKET-" "$1"\n' >.git/hooks/commit-msg
  chmod +x .git/hooks/commit-msg
  printf 'a\n' >a.txt && printf 'b\n' >b.txt && git add -A
  git commit -qm "TICKET-1 two files" >"$R.out" 2>&1
  rc=$?
  res "D5 commit-msg hook installed: one normal commit with the user's message" PASS eval '[ "$rc" = 0 ] && [ "$(commits)" = 2 ] && [ "$(git log -1 --format=%s)" = "TICKET-1 two files" ]'
  printf 'c\n' >c.txt && git add -A
  git commit -qm "no ticket" >"$R.out" 2>&1
  rc=$?
  res "D5 the hook still rejects a bad message" PASS eval '[ "$rc" != 0 ] && [ "$(commits)" = 2 ]'
  mkdir "$T/d5-hooks" && mv .git/hooks/commit-msg "$T/d5-hooks/" && git config core.hooksPath "$T/d5-hooks"
  "$AUTO_COMMIT" >"$R.out" 2>&1
  rc=$?
  res "D5 a commit-msg hook under core.hooksPath is found too" PASS eval '[ "$rc" = 0 ] && [ "$(commits)" = 2 ] && grep -q "commit-msg hook is installed" "$R.out"'
)
(
  # pathspec-guard (tests/pathspec-guard.sh) refuses staged names lefthook
  # would hand to git as patterns reaching other files. A config rendered
  # before that job existed, like cfg's, starts with auto-commit-prepare,
  # which calls it too. A current render passes --no-guard, which leaves it to
  # the guard job.
  newrepo d6 && cfg
  printf 'k\n' >keep && git add -A && LEFTHOOK=0 git commit -qm base
  printf 'c\n' >:colon.txt && printf 'n\n' >normal.txt && git add -A
  "$AUTO_COMMIT" --prepare >"$R.out" 2>&1
  rc=$?
  res "D6 --prepare refuses a staged path starting with ':' and names it" PASS eval '[ "$rc" = 1 ] && grep -q ":colon.txt" "$R.out"'
  git commit -qm umbrella >"$R.out" 2>&1
  res "D6 the commit is blocked before anything runs" PASS eval '[ "$(commits)" = 1 ] && [ "$(git diff --cached --name-only | wc -l)" = 2 ]'
  "$AUTO_COMMIT" --prepare --no-guard >"$R.out" 2>&1
  rc=$?
  res "D6 --prepare --no-guard leaves ':colon.txt' to the guard job" PASS eval '[ "$rc" = 0 ] && ! grep -q ":colon.txt" "$R.out"'
)
(
  # Glob characters. After the formatter, lefthook hands the staged names to
  # `git add --force`, which stages every file a name matches as a pattern,
  # ignored ones included, and the split commits them. A name that matches
  # nothing but itself goes through. (Round-11 review; 2026-10-21 panel.)
  newrepo d9 && cfg
  printf 'k\n' >keep && git add -A && LEFTHOOK=0 git commit -qm base
  mkdir -p 'app/[id]' && printf 'p  \n' >'app/[id]/page.txt' && git add -A
  git commit -qm umbrella >"$R.out" 2>&1
  res "D9 a route file like app/[id]/page.txt is split and formatted like any other" PASS eval '[ "$(git log -1 --format=%s)" = "Add app/[id]/page.txt" ] && [ "$(git show "HEAD:app/[id]/page.txt")" = p ]'
  n=$(commits)
  printf 'gsecret.txt\n' >>.git/info/exclude
  printf 'SECRET\n' >gsecret.txt
  printf 'g  \n' >'g*.txt' && git add -A
  git commit -qm umbrella >"$R.out" 2>&1
  res "D9 g*.txt staged next to an ignored gsecret.txt: blocked, naming it, and gsecret.txt neither staged nor committed" PASS eval '[ "$(commits)" = "$n" ] && grep -q "also matches .gsecret.txt." "$R.out" && [ -z "$(git ls-files gsecret.txt)" ]'
  # Without the prepare pass (a config committed before it existed), the
  # split itself still takes the name literally.
  "$AUTO_COMMIT" >"$R.out" 2>&1
  res "D9 the split alone commits g*.txt by its literal name" PASS eval '[ "$(commits)" = $((n + 1)) ] && [ "$(git log -1 --format=%s)" = "Add g*.txt" ] && [ -z "$(git ls-files gsecret.txt)" ]'
)
(
  # lefthook 1.13.0 to 2.0.15 install their prepare-commit-msg script on every
  # lefthook install, configured or not, to keep the hooks in sync (later ones
  # when the config has no hooks at all), and nothing removes it. It runs
  # nothing, yet it turned splitting off for good. (Round-11 review.)
  newrepo d8
  printf 'no_auto_install: true\n' >lefthook.yml # no hooks yet: lefthook installs its script
  printf 'lefthook-local.yml\n' >>.git/info/exclude
  lefthook install >/dev/null 2>&1
  cfg
  res "D8 (setup) lefthook left its prepare-commit-msg script installed" PASS eval '[ -x .git/hooks/prepare-commit-msg ] && grep -q "^call_lefthook run \"prepare-commit-msg\"" .git/hooks/prepare-commit-msg'
  printf 'k\n' >keep && git add -A && LEFTHOOK=0 git commit -qm base
  printf 'a\n' >a.txt && printf 'b\n' >b.txt && git add -A
  git commit -qm umbrella >"$R.out" 2>&1
  res "D8 lefthook's prepare-commit-msg script with nothing configured: the commit is split" PASS eval '[ "$(commits)" = 3 ] && ! grep -q "hook is installed" "$R.out"'
  # Jobs for it in the config, here in lefthook-local.yml, make it a message hook.
  printf 'prepare-commit-msg:\n  jobs:\n    - run: echo prepared\n' >lefthook-local.yml
  printf 'c\n' >c.txt && git add -A
  n=$(commits)
  git commit -qm "one commit" >"$R.out" 2>&1
  rc=$?
  rm lefthook-local.yml
  res "D8 the same script with prepare-commit-msg jobs configured: one commit" PASS eval '[ "$rc" = 0 ] && [ "$(commits)" = $((n + 1)) ] && [ "$(git log -1 --format=%s)" = "one commit" ]'
  # The script's last line before lefthook 1.5.
  sed -i 's/^call_lefthook run "prepare-commit-msg" "\$@"$/call_lefthook "run prepare-commit-msg $@"/' .git/hooks/prepare-commit-msg
  printf 'd\n' >d.txt && git add -A
  "$AUTO_COMMIT" >"$R.out" 2>&1
  res "D8 ... and in the form lefthook wrote before 1.5" PASS eq "$(git log -1 --format=%s)" "Add d.txt"
  # A config lefthook cannot read gives no answer: the commit stays whole.
  printf 'pre-commit: [\n' >lefthook.yml
  printf 'e\n' >e.txt && git add -A
  n=$(commits)
  "$AUTO_COMMIT" >"$R.out" 2>&1
  rc=$?
  res "D8 when lefthook dump fails, the script counts as a message hook" PASS eval '[ "$rc" = 0 ] && [ "$(commits)" = "$n" ] && grep -q "a prepare-commit-msg hook is installed" "$R.out"'
)
(
  newrepo d7
  printf 'k\n' >keep && git add -A && git commit -qm base
  for i in $(seq 1 1000); do printf 'v%s\n' "$i" >"f$i.txt"; done
  git add -A
  s=$(date +%s%N)
  "$AUTO_COMMIT" >"$R.out" 2>&1
  ms=$((($(date +%s%N) - s) / 1000000))
  echo "   d7 1000 adds: ${ms}ms"
  res "D7 1000 adds: 1000 commits, index == HEAD" PASS eval '[ "$(commits)" = 1001 ] && [ "$(idx)" = "$(headtree)" ]'
)

summary 88
