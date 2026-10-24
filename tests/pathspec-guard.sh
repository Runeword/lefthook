#!/usr/bin/env bash
# Behavioural checks for scripts/pathspec-guard.sh (flake check
# `behaviour-pathspec-guard`): the wrapper alone, then the job a formatter's
# render puts first. See tests/lib.sh for the result format.
#
# Assertions are single-quoted strings that `res` evaluates later, so the
# linter sees neither their expansions nor the variables they read.
# shellcheck disable=SC1091,SC2016,SC2034
set -u
# shellcheck source=tests/lib.sh
. "$TEST_LIB"

guard() { "$PATHSPEC_GUARD" >"$R.out" 2>&1; }
# shim NAME SCRIPT: a copy of the wrapper whose git runs SCRIPT (a case on
# " $* ") first, then the real git. Prints the copy's path.
shim() {
  mkdir -p "$T/$1"
  printf '#!%s\n%s\nexec %s "$@"\n' "$BASH" "$2" "$REAL_GIT" >"$T/$1/git"
  chmod +x "$T/$1/git"
  sed "s|^export PATH=\"|export PATH=\"$T/$1:|" "$PATHSPEC_GUARD" >"$T/$1/pathspec-guard"
  chmod +x "$T/$1/pathspec-guard"
  printf '%s\n' "$T/$1/pathspec-guard"
}

echo "## pathspec-guard (lefthook $(lefthook version), $(git version))"

echo "# names git reads as magic, and names lefthook rewrites"
(
  # lefthook would hand ":name" to git add/checkout, which reads it as magic.
  newrepo p1
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'c\n' >:colon.txt && printf 'n\n' >normal.txt && git add -A
  guard
  rc=$?
  res "P1 a staged name starting with ':' is refused and named" PASS eval '[ "$rc" = 1 ] && grep -q ":colon.txt" "$R.out"'
  # git quotes a name holding a tab, and the quoting hid the leading ':'.
  git reset -q && rm :colon.txt
  printf 't\n' >":tab$(printf '\t')name.txt" && git add -A
  guard
  rc=$?
  res "P1 ... also when the name holds a tab, which git quotes" PASS eval '[ "$rc" = 1 ] && grep -q ":tab.name.txt" "$R.out"'
)
(
  # lefthook trims blanks off the ends of each staged name and unquotes one
  # wrapped in backquotes or single quotes, then acts on the result.
  newrepo p2
  printf 'k\n' >keep && git add -A && git commit -qm base
  for odd in 't.txt ' ' t.txt' "t.txt$(printf '\302\240')" '`t.txt`' "'t'"; do
    printf 'o\n' >"$odd" && git --literal-pathspecs add -- "$odd"
    guard
    rc=$?
    res "P2 a staged '$odd' is refused" PASS eq "$rc" 1
    git reset -q && rm -- "$odd"
  done
)

echo "# names that read as patterns"
(
  # A name holding a glob character goes through while, read as a pattern, it
  # matches nothing but itself.
  newrepo p3
  printf 'k\n' >keep && git add -A && git commit -qm base
  for glob in 'g*.txt' 'q?.txt' 'x[y].txt' 'a\b.txt'; do
    printf 'g\n' >"$glob" && git add -A
    guard
    rc=$?
    res "P3 a staged $glob goes through while it matches nothing else" PASS eq "$rc" 0
    git reset -q && rm -- "$glob"
  done
  printf 'o\n' >'x]y.txt' && printf 'o\n' >'b{1,2}.txt' && git add -A
  guard
  rc=$?
  res "P3 ... and ']' or braces are no pattern at all" PASS eq "$rc" 0
  git reset -q && rm -- 'x]y.txt' 'b{1,2}.txt'
  mkdir -p 'app/[id]' && printf 'p\n' >'app/[id]/page.txt' && git add -A
  guard
  rc=$?
  res "P3 a route file like app/[id]/page.txt goes through" PASS eq "$rc" 0
  mkdir -p app/i && printf 'i\n' >app/i/page.txt
  guard
  rc=$?
  res "P3 ... until an untracked app/i/page.txt is another file it matches" PASS eval '[ "$rc" = 1 ] && grep -q "also matches .app/i/page.txt." "$R.out"'
)
(
  # A name that also matches another file is refused, whatever that file is:
  # ignored, untracked, tracked with an unstaged edit, tracked and clean, or
  # deleted from the working tree. Each is staged alone, literally.
  newrepo p4
  printf 'e\n' >xy.txt && printf 'c\n' >clean.txt && printf 'd\n' >ab.txt
  git add -A && git commit -qm base
  printf 'gsecret.txt\n' >>.git/info/exclude
  printf 'S\n' >gsecret.txt && printf 'u\n' >qq.txt && printf 'edit\n' >>xy.txt && rm ab.txt
  for pair in 'g*.txt gsecret.txt' 'q?.txt qq.txt' 'x[y].txt xy.txt' 'c[l]ean.txt clean.txt' 'a\b.txt ab.txt'; do
    glob=${pair% *} other=${pair#* }
    printf 'g\n' >"$glob" && git --literal-pathspecs add -- "$glob"
    guard
    rc=$?
    res "P4 a staged $glob that also matches $other is refused, naming it" PASS eval '[ "$rc" = 1 ] && grep -qF -- "$other" "$R.out"'
    git reset -q && rm -- "$glob"
  done
  # Pathspecs resolve from the current directory, and a `root:` job runs in a
  # subdirectory.
  printf 'g\n' >'g*.txt' && git --literal-pathspecs add -- 'g*.txt'
  mkdir -p sub && (cd sub && "$PATHSPEC_GUARD") >"$R.out" 2>&1
  rc=$?
  res "P4 ... also run from a subdirectory" PASS eval '[ "$rc" = 1 ] && grep -qF gsecret.txt "$R.out"'
)
(
  # Many such names are checked in chunks that sh -c takes as one argument,
  # and halved down to the one that matches another file: asked about one by
  # one, 3,000 of them took 24 s.
  newrepo p5
  printf 'k\n' >keep && git add -A && git commit -qm base
  mkdir many
  for i in $(seq 1 2000); do : >"many/a-name-long-enough-that-these-take-a-few-chunks-$i-[x].txt"; done
  git add -A
  guard
  rc=$?
  res "P5 2000 bracket names that match only themselves go through" PASS eq "$rc" 0
  : >many/a-name-long-enough-that-these-take-a-few-chunks-1999-x.txt
  count=$(shim p5-shim 'case " $* " in *" ls-files "*) echo >>"$CALLS" ;; esac')
  : >"$T/p5-calls"
  CALLS=$T/p5-calls "$count" >"$R.out" 2>&1
  rc=$?
  res "P5 ... and the one that matches another file is named, alone" PASS eval '[ "$rc" = 1 ] && [ "$(grep -c "also matches" "$R.out")" = 1 ] && grep -qF -- "-1999-[x].txt" "$R.out"'
  calls=$(wc -l <"$T/p5-calls")
  echo "   P5 git ls-files calls for 2000 names, one of them matching: $calls"
  res "P5 ... in a few dozen git calls, not one per name" PASS eval '[ "$calls" -gt 2 ] && [ "$calls" -lt 50 ]'
)
(
  # A check that cannot run refuses: finding the top, listing the staged
  # names, or asking git what a pattern matches. (2026-10-21 panel: the guard
  # in auto-commit used to pass then.)
  newrepo p6
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'r\n' >'x[y].txt' && git add -A
  failing=$(shim p6-shim 'case " $* " in *" $FAIL_GIT "*) exit 128 ;; esac')
  FAIL_GIT='ls-files' "$failing" >"$R.out" 2>&1
  rc=$?
  res "P6 when git cannot say what a pattern matches, it refuses" PASS eval '[ "$rc" = 1 ] && grep -q "could not be checked" "$R.out"'
  FAIL_GIT='diff' "$failing" >"$R.out" 2>&1
  rc=$?
  res "P6 when the staged names cannot be listed, it refuses" PASS eval '[ "$rc" = 1 ] && grep -q "could not be listed" "$R.out"'
  FAIL_GIT='rev-parse' "$failing" >"$R.out" 2>&1
  rc=$?
  res "P6 when the top of the working tree cannot be found, it refuses" PASS eval '[ "$rc" = 1 ] && grep -q "could not be listed" "$R.out"'
)
(
  # `git --literal-pathspecs commit`, magit's default, exports
  # GIT_LITERAL_PATHSPECS to the hook, and lefthook's git calls then read each
  # name as itself. The guard keeps the variable and reads the names as they
  # do: a pattern goes through, while a name lefthook rewrites before git sees
  # it is still refused.
  newrepo p7
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'gsecret.txt\n' >>.git/info/exclude
  printf 'S\n' >gsecret.txt
  printf 'g\n' >'g*.txt' && git --literal-pathspecs add -- 'g*.txt'
  GIT_LITERAL_PATHSPECS=1 "$PATHSPEC_GUARD" >"$R.out" 2>&1
  res "P7 under git --literal-pathspecs, g*.txt goes through: git reads it as itself there" PASS eq "$?" 0
  git reset -q && rm -- 'g*.txt'
  printf 'g\n' >'gsecret.txt ' && git --literal-pathspecs add -- 'gsecret.txt '
  GIT_LITERAL_PATHSPECS=1 "$PATHSPEC_GUARD" >"$R.out" 2>&1
  res "P7 ... while 'gsecret.txt ', which lefthook trims first, is still refused" PASS eq "$?" 1
)

echo "# lefthook's backup of the unstaged changes"
# lhstash: a stash entry as lefthook makes one, of every tracked change,
# before its jobs run.
lhstash() { git stash store -m "lefthook auto backup" "$(git stash create)"; }
(
  newrepo k1
  printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'mine\n' >keep && git stash -q
  guard
  rc=$?
  res "K1 with no backup of lefthook's on top of the stash, nothing is written" PASS eval '[ "$rc" = 0 ] && ! git rev-parse -q --verify refs/lefthook/backup >/dev/null'
  printf 'edit\n' >keep && lhstash
  guard && guard
  res "K1 lefthook's backup is kept in refs/lefthook/backup, once however often the guard runs" PASS eval '[ "$(git rev-parse refs/lefthook/backup)" = "$(git rev-parse refs/stash)" ] && [ "$(git reflog show refs/lefthook/backup | wc -l)" = 1 ]'
  git stash drop -q && printf 'edit 2\n' >keep && lhstash
  failing=$(shim k1-shim 'case " $* " in *" update-ref "*) exit 1 ;; esac')
  "$failing" >"$R.out" 2>&1
  rc=$?
  res "K1 when the backup cannot be kept, it refuses" PASS eval '[ "$rc" = 1 ] && grep -q "could not be kept" "$R.out"'
)
(
  # Known limitation: git stash leaves out a file marked assume-unchanged, so
  # the backup lacks its local edit, which lefthook 2.1.7 to 2.1.15 reset with
  # the rest. (2026-10-21 panel.)
  newrepo k2
  printf 'local: default\n' >au.txt && printf 'k\n' >keep && git add -A && git commit -qm base
  printf 'local: mine\n' >au.txt && git update-index --assume-unchanged au.txt
  printf 'edit\n' >keep && lhstash
  guard
  res "K2 the backup holds an assume-unchanged file's local edit" FAIL eval '[ "$(git show refs/lefthook/backup:au.txt)" = "local: mine" ]'
)

echo "# the rendered job"
# guardrepo NAME: a repository committing through GUARD_CONFIG, the render of
# a formatter (format-yaml), which puts the guard first. No auto-commit.
guardrepo() {
  newrepo "$1" && use_render "$GUARD_CONFIG"
  printf 'k: v\n' >keep.yml && git add -A && LEFTHOOK=0 git commit -qm base
}
PATH=${PATHSPEC_GUARD%/*}:$PATH
(
  guardrepo r1
  printf 'a:   1\n' >a.yml && git add a.yml
  git commit -qm a >"$R.out" 2>&1
  rc=$?
  res "R1 an ordinary commit goes through, formatted" PASS eval '[ "$rc" = 0 ] && [ "$(git show HEAD:a.yml)" = "a: 1" ]'
  # Without the guard, lefthook staged the formatter's fix to g*.yml with
  # `git add --force -- g*.yml`, which also staged the ignored gsecret.yml,
  # and the commit took it in.
  printf 'gsecret.yml\n' >>.git/info/exclude
  printf 'secret:   1\n' >gsecret.yml
  printf 'g:   1\n' >'g*.yml' && git add -A
  git commit -qm 'add g*.yml' >"$R.out" 2>&1
  rc=$?
  res "R1 with no auto-commit, g*.yml next to an ignored gsecret.yml is blocked" PASS eval '[ "$rc" != 0 ] && [ "$(commits)" = 2 ] && grep -q "also matches .gsecret.yml." "$R.out"'
  res "R1 ... before the formatter: g*.yml as written, gsecret.yml not staged" PASS eval '[ "$(cat "g*.yml")" = "g:   1" ] && [ -z "$(git ls-files gsecret.yml)" ]'
  # lefthook trims the blank off "gsecret.yml " and formats and stages the
  # ignored gsecret.yml instead.
  git reset -q && rm -- 'g*.yml'
  printf 'g:   1\n' >'gsecret.yml ' && git --literal-pathspecs add -- 'gsecret.yml '
  git commit -qm 'add gsecret.yml ' >"$R.out" 2>&1
  rc=$?
  res "R1 'gsecret.yml ' next to an ignored gsecret.yml: blocked, gsecret.yml untouched and not staged" PASS eval '[ "$rc" != 0 ] && [ "$(commits)" = 2 ] && [ "$(cat gsecret.yml)" = "secret:   1" ] && [ -z "$(git ls-files gsecret.yml)" ]'
)
(
  # A merge runs the formatters too, so the guard has no skip for it.
  guardrepo r2
  git checkout -qb side
  printf 'g:   1\n' >'g*.yml' && git --literal-pathspecs add -- 'g*.yml' && LEFTHOOK=0 git commit -qm 'add g*.yml'
  git checkout -q main
  printf 'm: 1\n' >main.yml && git add main.yml && LEFTHOOK=0 git commit -qm main
  printf 'gsecret.yml\n' >>.git/info/exclude
  printf 'secret:   1\n' >gsecret.yml
  git merge -q --no-ff --no-commit side >/dev/null 2>&1
  git commit -qm merge >"$R.out" 2>&1
  rc=$?
  res "R2 concluding a merge that brings in g*.yml: blocked, the merge still in progress" PASS eval '[ "$rc" != 0 ] && [ -e .git/MERGE_HEAD ] && grep -q "also matches .gsecret.yml." "$R.out"'
  res "R2 ... gsecret.yml not staged" PASS eval '[ -z "$(git ls-files gsecret.yml)" ]'
)
(
  # Nothing to guard where no enabled job stages a fix: lefthook then hands
  # the names to git only to set unstaged changes aside, before any job runs.
  res "R3 a render where nothing stages a fix has no guard job" PASS eval '! grep -q pathspec-guard "$NO_STAGING_CONFIG"'
)
(
  # When putting the unstaged hunks back conflicts with a formatter's fix,
  # lefthook's stash is the only copy of the hunk (and with lefthook 2.1.7 to
  # 2.1.15 of every other tracked file's unstaged edit), and lefthook drops it
  # at the next commit with a partially staged file. (2026-10-21 panel.)
  guardrepo r4
  printf 'a: 1\nb: 2\n' >p.yml && printf 'q\n' >q.txt && printf 'x: 1\ny: 2\n' >s.yml
  git add -A && LEFTHOOK=0 git commit -qm files
  printf 'a: 1\nb:    3\n' >p.yml && git add p.yml # staged: a line the formatter fixes
  printf 'a: 1\nb:    33\n' >p.yml                 # unstaged: that line edited again
  printf 'q edited\n' >q.txt                       # unstaged, in another file
  git commit -qm one >"$R.out" 2>&1
  res "R4 a commit with a partially staged file keeps lefthook's backup" PASS eval '[ "$(git show refs/lefthook/backup:p.yml | tail -1)" = "b:    33" ] && [ "$(git show refs/lefthook/backup:q.txt)" = "q edited" ]'
  printf 'x: 10\ny: 2\n' >s.yml && git add s.yml
  printf 'x: 10\ny: 20\n' >s.yml
  git commit -qm two >"$R.out" 2>&1
  res "R4 ... which the reflog keeps once the next such commit has dropped lefthook's stash" PASS eval '[ -z "$(git stash list)" ] && [ "$(git show "refs/lefthook/backup@{1}:p.yml" | tail -1)" = "b:    33" ]'
  git restore --source='refs/lefthook/backup@{1}' -- p.yml
  res "R4 ... from which git restore brings the edit back" PASS eval '[ "$(tail -1 p.yml)" = "b:    33" ]'
)
(
  # A config rendered with auto-commit's prepare pass (2026-08-15 on) but
  # before the guard job keeps the backup through that pass.
  newrepo r5 && use_render "$PREPARE_ONLY_CONFIG"
  PATH=${AUTO_COMMIT%/*}:$PATH
  printf 'a: 1\nb: 2\n' >p.yml && git add -A && LEFTHOOK=0 git commit -qm base
  printf 'a: 10\nb: 2\n' >p.yml && git add p.yml
  printf 'a: 10\nb: 20\n' >p.yml
  git commit -qm one >"$R.out" 2>&1
  res "R5 with no guard job, auto-commit's prepare pass keeps the backup" PASS eval '! grep -q pathspec-guard lefthook-generated.yml && [ "$(git show refs/lefthook/backup:p.yml | tail -1)" = "b: 20" ] && [ "$(git log -1 --format=%s)" = "Update p.yml" ]'
)

summary 43
