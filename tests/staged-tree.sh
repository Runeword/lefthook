#!/usr/bin/env bash
# Assertions are strings res() evals, so $ inside single quotes is meant.
# shellcheck disable=SC1091,SC2016,SC2034
# Behavioural checks for scripts/staged-tree.sh through the wrappers that use
# it (flake check `behaviour-staged-tree`). See tests/lib.sh for the result
# format. trivy cannot fetch its checks bundle here and falls back to the
# checks it embeds.
set -u
# shellcheck source=tests/lib.sh
. "$TEST_LIB"

export GOCACHE=$TMPDIR/gocache GOPATH=$TMPDIR/gopath
export GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local CGO_ENABLED=0 GOTELEMETRY=off
# What a user's own golangci-lint (an editor, a manual run) would share.
export GOLANGCI_LINT_CACHE=$TMPDIR/user-golangci-cache
export TFLINT_DISABLE_VERSION_CHECK=1
STAGED=$HOME/.cache/lefthook/staged
# Tools the wrapper carries, for runs "outside the hook": its golangci-lint,
# and the flock it locks with.
wrapper_bin() { sed -n 's/^export PATH="\(.*\):\$PATH"$/\1/p' "$1" | tr ':' '\n' | grep -m1 "$2"; }
GL=$(wrapper_bin "$LINT_GO" golangci-lint)/golangci-lint
PATH=$PATH:$(wrapper_bin "$LINT_GO" flock)
# Without them, the tests that use them would fail, or pass, on nothing.
if [ ! -x "$GL" ] || ! command -v flock >/dev/null; then
  echo "the lint-go wrapper's PATH has no golangci-lint or no flock" >&2
  exit 1
fi

# A failing test shows the tail of what the wrapper printed.
eval "lib_$(declare -f res)"
res() {
  lib_res "$@"
  case $(tail -1 "$T/results") in
    UNEXPECTED*) if [ -f "${R:-}.out" ]; then tail -15 "$R.out" | sed 's/^/      | /'; fi ;;
  esac
}

# gorepo NAME [DIR]: a committed Go module (example.com/m) with one main
# package, at the top or in DIR.
gorepo() {
  newrepo "$1"
  mkdir -p "${2:-.}"
  printf 'module example.com/m\n\ngo 1.22\n' >"${2:-.}/go.mod"
  printf 'package main\n\nfunc main() {}\n' >"${2:-.}/main.go"
  git add -A && git commit -qm base
}
# privmod: a module, example.com/priv/x.git v1.0.0, that go fetches with git
# from $T/priv, as it fetches a private module (GOPRIVATE): git rewrites its
# https URL to the local repository. For the calling subshell only.
privmod() {
  if [ ! -d "$T/priv/x.git" ]; then
    (
      newrepo priv-src
      printf 'module example.com/priv/x.git\n\ngo 1.22\n' >go.mod
      printf 'package x\n\nfunc X() int { return 1 }\n' >x.go
      git add -A && git commit -qm x && git tag v1.0.0
      git clone -q --bare "$R" "$T/priv/x.git"
    )
  fi
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$T/priv/.insteadOf" GIT_CONFIG_VALUE_0=https://example.com/priv/
  export GOPRIVATE=example.com/priv
}
lint() { "$LINT_GO" "$@" >"$R.out" 2>&1; }
# staged_key: the name of the current working tree's directory under $STAGED.
staged_key() { git rev-parse --absolute-git-dir | tr -d '\n' | git hash-object --stdin | cut -c1-16; }
leftover_trees() { find "$STAGED" -mindepth 3 -maxdepth 3 -name tree 2>/dev/null | wc -l; }

echo "## staged-tree (go $(go env GOVERSION), $("$GL" version 2>/dev/null | head -1))"

echo "# the copy is the staged tree"
(
  gorepo d0
  printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("hi") }\n' >main.go && git add main.go
  s=$(date +%s%N)
  lint main.go
  rc=$?
  echo "   d0 cold lint of a 1-file package: rc=$rc $((($(date +%s%N) - s) / 1000000))ms"
  res "a clean staged package lints clean" PASS eq "$rc" 0
)
(
  gorepo d1
  printf 'package main\n\nimport "fmt"\n\nfunc main() { fmt.Println("v2") }\n' >main.go && git add main.go
  printf 'package main\n\nfunc broken( {\n' >wip.go
  lint main.go
  res "an untracked broken neighbour does not fail the commit" PASS eq "$?" 0
)
(
  gorepo d1b
  printf 'package main\n\nfunc helper() {}\n' >helper.go && git add helper.go && git commit -qm helper
  printf 'package main\n\nfunc main() { helper() }\n' >main.go && git add main.go
  printf 'package main\n\nfunc helper( {\n' >helper.go # unstaged, broken
  lint main.go
  res "an unstaged broken edit to another file of the package is not linted" PASS eq "$?" 0
)
(
  gorepo d2
  printf 'package main\n\nfunc main() { helper() }\n' >main.go && git add main.go
  printf 'package main\n\nfunc helper() {}\n' >helper.go
  lint main.go
  res "a staged file that needs an untracked file fails" PASS eval '[ "$(cat "$R.out" | grep -c "undefined: helper")" != 0 ]'
)
(
  gorepo d3
  printf 'package main\n\nimport "os"\n\nfunc main() { os.Remove("x") }\n' >main.go && git add main.go
  printf 'package main\n\nimport "os"\n\nfunc main() { _ = os.Remove("x") }\n' >main.go # the formatter's fix
  lint main.go
  res "the hook's own file is taken from the working tree (the formatter's fix)" PASS eq "$?" 0
)
(
  gorepo d8
  printf 'package main\n\nfunc broken( {\n' >ita.go && git add -N ita.go
  printf 'package main\n\nfunc main() { _ = 4 }\n' >main.go && git add main.go
  lint main.go
  res "an intent-to-add broken file is left out of the copy" PASS eq "$?" 0
)
(
  gorepo d10
  printf 'package main\n\nfunc helper() {}\n' >helper.go && git add helper.go && git commit -qm helper
  git update-index --skip-worktree helper.go
  printf 'package main\n\nfunc helper( {\n' >helper.go
  printf 'package main\n\nfunc main() { helper() }\n' >main.go && git add main.go
  lint main.go
  res "a skip-worktree file is taken from the index, not the working tree" PASS eq "$?" 0
)
(
  gorepo d11
  printf 'package main\n\nfunc helper() {}\n' >helper.go && git add helper.go && git commit -qm helper
  git config core.ignoreStat true
  printf 'package main\n\nfunc helper( {\n' >helper.go
  printf 'package main\n\nfunc main() { helper() }\n' >main.go && git add main.go
  lint main.go
  res "under core.ignoreStat every neighbour comes from the index" PASS eq "$?" 0
)
(
  # A clean filter that rot13s, as git-crypt encrypts: the blob is unreadable,
  # the working tree holds the plain file. Defined in the global config, so it
  # applies like a user's own filter driver.
  git config --global filter.rot.clean 'tr A-Za-z N-ZA-Mn-za-m'
  git config --global filter.rot.smudge 'tr A-Za-z N-ZA-Mn-za-m'
  gorepo d12
  printf 'secret.go filter=rot\nsecret2.go filter=rot\n' >.gitattributes
  printf 'package main\n\nfunc secret() int { return 1 }\n' >secret.go
  printf 'package main\n\nfunc secret2() int { return 2 }\n' >secret2.go
  git add -A && git commit -qm secrets
  printf 'package main\n\nfunc main() { _ = secret() + secret2() }\n' >main.go && git add main.go
  lint main.go
  rc1=$?
  printf 'package main\n\nfunc secret2( {\n' >secret2.go # unstaged, broken: the blob must be used
  lint main.go
  rc2=$?
  git config --global --unset filter.rot.clean
  git config --global --unset filter.rot.smudge
  res "filtered neighbours the working tree matches reach the linter in working-tree form (copied)" PASS eq "$rc1" 0
  # Known limitation: no filter driver runs in the copy (d13), so the staged
  # blob of a changed file stays as git stores it, as git-crypt ciphertext.
  res "a changed filtered neighbour reaches the linter smudged" FAIL eq "$rc2" 0
)
(
  # LFS files whose objects were never downloaded, as in a sparse or partial
  # clone: one outside the sparse checkout (skip-worktree), one deleted, one
  # changed, so all three come from the index. Checking them out ran LFS's
  # smudge filter, which fetched each object, and offline (here: no remote at
  # all) the commit failed. No filter driver runs in the copy: it holds the
  # pointers. (Round-11 review.)
  gorepo d13
  git lfs install --local >/dev/null
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >.gitattributes
  printf 'payload 1\n' >sparse.bin
  printf 'payload 2\n' >gone.bin
  printf 'payload 3\n' >changed.bin
  git add -A && git commit -qm lfs
  git update-index --skip-worktree sparse.bin && rm sparse.bin
  rm gone.bin
  printf 'edited\n' >changed.bin
  rm -rf .git/lfs/objects # after update-index, whose refresh stores the object again
  printf 'package main\n\nfunc main() { _ = 13 }\n' >main.go && git add main.go
  lint main.go
  res "LFS objects never downloaded (sparse, deleted, changed) do not fail the check offline" PASS eq "$?" 0
)
(
  # The same in a submodule, whose files all come from its own objects.
  newrepo d14dep
  printf 'module example.com/x\n\ngo 1.22\n' >go.mod
  printf 'package x\n\nfunc X() int { return 1 }\n' >x.go
  printf '*.bin filter=lfs diff=lfs merge=lfs -text\n' >.gitattributes
  git lfs install --local >/dev/null
  printf 'payload\n' >asset.bin
  git add -A && git commit -qm dep
  gorepo d14
  printf 'module example.com/m\n\ngo 1.22\n\nrequire example.com/x v0.0.0\n\nreplace example.com/x => ./dep\n' >go.mod
  git clone -q "$T/d14dep" dep # no LFS config here yet: no object is fetched
  git -C dep remote remove origin
  git -C dep lfs install --local >/dev/null
  git add -A 2>/dev/null
  printf 'package main\n\nimport "example.com/x"\n\nfunc main() { _ = x.X() }\n' >main.go && git add main.go
  lint main.go
  rc=$?
  res "(setup) the submodule holds an LFS pointer whose object it lacks" PASS eval '[ "$(git -C dep lfs ls-files | awk "{ print \$2 }")" = "-" ]'
  res "an LFS object a submodule never downloaded does not fail the check offline" PASS eq "$rc" 0
)

echo "# where the copy lives"
(
  gorepo l1
  printf 'package main\n\nfunc main() { _ = 1 }\n' >main.go && git add main.go
  mkdir -p "$T/shared/tmp"
  TMPDIR=$T/shared/tmp lint main.go
  res "the copy's directory is under ~/.cache/lefthook/staged, per working tree and hook, whatever TMPDIR says" PASS eval '[ -e "$STAGED/$(staged_key)/lint-go/lock" ]'
  res "no copy is left behind after the runs so far" PASS eq "$(leftover_trees)" 0
)
(
  gorepo l2
  mkdir -p "$HOME/.cache/lefthook" && chmod 777 "$HOME/.cache/lefthook"
  printf 'package main\n\nfunc main() { _ = 1 }\n' >main.go && git add main.go
  lint main.go
  rc=$?
  chmod 700 "$HOME/.cache/lefthook"
  res "a cache directory others can write to is refused" PASS eval '[ "$rc" != 0 ] && grep -q "refusing" "$R.out"'
)
(
  gorepo l4
  printf 'package main\n\nfunc main() { _ = 3 }\n' >main.go && git add main.go
  lint main.go
  key=$(staged_key)
  mkdir -p "$STAGED/$key/lint-go/tree/leak" && touch "$STAGED/$key/lint-go/tree/leak/x"
  lint main.go
  rc=$?
  res "a copy left by a killed run of the same hook is reclaimed by the next run, which passes" PASS eval '[ "$rc" = 0 ] && [ ! -e "$STAGED/$key/lint-go/tree" ]'
  mkdir -p "$STAGED/0000000000000000/lint-go/tree" "$STAGED/1111111111111111/lint-go/tree"
  touch -d '-2 hours' "$STAGED/0000000000000000/lint-go/tree" "$STAGED/1111111111111111/lint-go/tree"
  touch "$STAGED/1111111111111111/lint-go/lock"
  (
    exec 8>"$STAGED/1111111111111111/lint-go/lock"
    flock 8
    lint main.go
  )
  res "an idle copy of another repository is swept" PASS eval '[ ! -e "$STAGED/0000000000000000/lint-go/tree" ]'
  res "a copy whose lock is held is kept" PASS eval '[ -e "$STAGED/1111111111111111/lint-go/tree" ]'
  rm -rf "$STAGED/0000000000000000" "$STAGED/1111111111111111"
)
(
  # lefthook's root: runs a job in a subdirectory and names its files ./so,
  # while git hands the hook GIT_INDEX_FILE relative to the top. (Round-11
  # review: the index went missing, the copy came out empty, and the job passed
  # on nothing.)
  gorepo l7 sub
  printf 'package main\n\nimport "os"\n\nfunc main() { os.Remove("x") }\n' >sub/main.go && git add sub/main.go
  (cd sub && GIT_INDEX_FILE=.git/index lint ./main.go)
  rc=$?
  res "a root: job lints the staged tree" PASS eval '[ "$rc" != 0 ] && grep -q errcheck "$R.out"'
  printf 'package main\n\nimport "os"\n\nfunc main() { _ = os.Remove("x") }\n' >sub/main.go # the formatter's fix
  (cd sub && GIT_INDEX_FILE=.git/index lint ./main.go)
  res "a root: job's own ./file is taken from the working tree (the formatter's fix)" PASS eq "$?" 0
)
(
  # The same through lefthook and git commit.
  gorepo l7e sub
  printf 'no_auto_install: true\npre-commit:\n  jobs:\n    - name: lint-go\n      root: sub/\n      glob: "*.go"\n      run: %s {staged_files}\n' "$LINT_GO" >lefthook.yml
  printf 'lefthook.yml\n' >>.git/info/exclude
  lefthook install >/dev/null 2>&1
  printf 'package main\n\nimport "os"\n\nfunc main() { os.Remove("x") }\n' >sub/main.go && git add sub/main.go
  git commit -qm lint-error >"$R.out" 2>&1
  rc=$?
  res "a root: job's lint error blocks git commit" PASS eval '[ "$rc" != 0 ] && [ "$(commits)" = 1 ] && grep -q errcheck "$R.out"'
)
(
  gorepo l8
  printf 'package main\n\nfunc main() { _ = 8 }\n' >main.go && git add main.go
  GIT_INDEX_FILE=$R/.git/no-such-index lint main.go
  rc=$?
  res "a missing index fails the check instead of linting an empty copy" PASS eval '[ "$rc" != 0 ] && grep -q "there is no index" "$R.out"'
)
(
  # lefthook SIGKILLs the job's process group on ^C: no trap runs.
  gorepo l5
  for i in $(seq 1 40); do printf 'package main\n\nfunc f%s() {}\n' "$i" >"f$i.go"; done
  git add -A && git commit -qm many
  printf 'package main\n\nfunc main() {\n' >main.go && for i in $(seq 1 40); do printf '\tf%s()\n' "$i" >>main.go; done && printf '}\n' >>main.go && git add main.go
  set -m
  "$LINT_GO" main.go >"$R.out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ -n "$(find "$STAGED" -path "*/lint-go/tree$R/main.go" 2>/dev/null)" ] && break
    sleep 0.05
  done
  kill -KILL -- "-$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  set +m
  leaked=$(leftover_trees)
  lint main.go
  rc=$?
  res "after a SIGKILL the next run gets the lock and passes" PASS eq "$rc" 0
  res "after a SIGKILL the next run reclaims the copy (leaked before: $leaked)" PASS eq "$(leftover_trees)" 0
)
(
  gorepo l6
  for i in 1 2 3; do printf 'package main\n\nfunc g%s() {}\n' "$i" >"g$i.go"; done
  git add -A && git commit -qm gs
  printf 'package main\n\nfunc main() { g1(); g2(); g3() }\n' >main.go && git add main.go
  "$LINT_GO" main.go >"$R.a" 2>&1 &
  a=$!
  "$LINT_GO" main.go >"$R.b" 2>&1 &
  b=$!
  wait "$a"
  ra=$?
  wait "$b"
  rb=$?
  res "two concurrent runs in one repository both pass (serialized by the lock)" PASS eval '[ "$ra" = 0 ] && [ "$rb" = 0 ]'
)
(
  # cp keeps a directory's mode, so a read-only directory of the working tree
  # came out read-only in the copy, which then could not be removed: the run
  # failed on exit, and every run after it failed to reclaim the copy.
  # (Round-11 review.)
  gorepo l9
  mkdir -p ro && printf 'package ro\n\nfunc R() int { return 1 }\n' >ro/r.go
  printf 'package main\n\nimport "example.com/m/ro"\n\nfunc main() { _ = ro.R() }\n' >main.go
  git add -A && git commit -qm ro
  chmod 555 ro
  printf 'package main\n\nimport "example.com/m/ro"\n\nfunc main() { _ = ro.R() + 1 }\n' >main.go && git add main.go
  lint main.go
  rc1=$?
  left=$(leftover_trees)
  lint main.go
  rc2=$?
  chmod 755 ro
  res "a read-only directory in the copy: the run passes and removes the copy" PASS eval '[ "$rc1" = 0 ] && [ "$left" = 0 ]'
  res "a read-only directory in the copy: the next run passes too" PASS eq "$rc2" 0
)
(
  # What a run lefthook killed leaves behind: a copy with a read-only
  # directory, and the index.lock of the git killed with it, on which every
  # later run failed with exit 128. (Round-11 review.)
  gorepo l10
  printf 'package main\n\nfunc main() { _ = 10 }\n' >main.go && git add main.go
  lint main.go
  key=$(staged_key)
  mkdir -p "$STAGED/$key/lint-go/tree/ro" && touch "$STAGED/$key/lint-go/tree/ro/f" && chmod 555 "$STAGED/$key/lint-go/tree/ro"
  : >"$STAGED/$key/lint-go/index.lock"
  other=$STAGED/2222222222222222/lint-go
  mkdir -p "$other/tree/ro" && touch "$other/tree/ro/f" "$other/lock" && chmod 555 "$other/tree/ro"
  touch -d '-2 hours' "$other/tree"
  lint main.go
  rc=$?
  res "a killed run's index.lock and read-only directory are reclaimed by the next run" PASS eval '[ "$rc" = 0 ] && [ ! -e "$STAGED/$key/lint-go/tree" ] && [ ! -e "$STAGED/$key/lint-go/index.lock" ]'
  res "an idle copy of another repository holding a read-only directory is swept" PASS eval '[ ! -e "$other/tree" ]'
  chmod -R u+w "$STAGED"
  rm -rf "$STAGED/2222222222222222"
)
(
  # Each working tree has a directory of its own. Keyed on the git directory
  # linked worktrees share, they shared golangci-lint's cache while their
  # copies lay at different paths, and a linked worktree that linted what the
  # main one had just linted was handed its findings: //nolint and the
  # generated-file exclusion no longer applied. (2026-10-21 panel.)
  newrepo l11
  printf 'module example.com/m\n\ngo 1.22\n' >go.mod
  printf 'package main\n\nimport "os"\n\nfunc main() { os.Remove("x") //nolint:errcheck\n}\n' >main.go
  mkdir gen
  printf '// Code generated by hand. DO NOT EDIT.\n\npackage gen\n\nimport "os"\n\nfunc G() { os.Remove("y") }\n' >gen/g.go
  printf 'package gen\n\nfunc H() {}\n' >gen/h.go
  git add -A && git commit -qm base
  git worktree add -q "$R-linked" -b side
  change() {
    printf 'package main\n\nimport "os"\n\nfunc main() { os.Remove("x") //nolint:errcheck\n\t_ = 1\n}\n' >main.go
    printf 'package gen\n\n// H does nothing.\nfunc H() {}\n' >gen/h.go
    git add main.go gen/h.go
  }
  change
  lint main.go gen/h.go
  rc1=$?
  main_key=$(staged_key)
  cd "$R-linked" || exit 9
  change
  lint main.go gen/h.go
  rc2=$?
  res "a linked worktree has a directory of its own" PASS eval '[ "$(staged_key)" != "$main_key" ] && [ -e "$STAGED/$(staged_key)/lint-go/lock" ]'
  res "a linked worktree linting what the main one just linted is not handed its findings" PASS eval '[ "$rc1" = 0 ] && [ "$rc2" = 0 ]'
)

echo "# golangci-lint"
(
  gorepo g1
  printf 'package main\n\nimport "os"\n\nfunc main() { os.Remove("x") //nolint:errcheck\n}\n' >main.go
  mkdir -p gen && printf '// Code generated by hand. DO NOT EDIT.\n\npackage gen\n\nimport "os"\n\nfunc G() { os.Remove("y") }\n' >gen/g.go
  printf 'package gen\n\nfunc H() {}\n' >gen/h.go
  git add -A
  ok=0
  for i in 1 2 3; do lint main.go gen/h.go && ok=$((ok + 1)); done
  res "//nolint and generated-file exclusions hold on attempts 1-3 (cache replay)" PASS eq "$ok" 3
  "$GL" run --fix=false ./... >"$R.wt" 2>&1
  res "the user's own golangci-lint cache is not poisoned with the copy's paths" PASS eval '! grep -q lefthook "$R.wt"'
)
(
  gorepo g2
  printf 'package main\n\nimport "os"\n\nfunc old() { os.Remove("x") }\n' >old.go
  printf 'version: "2"\nissues:\n  new-from-rev: HEAD\n' >.golangci.yml
  git add -A && git commit -qm debt
  idx_before=$(sha256sum .git/index)
  printf 'package main\n\nfunc main() { old() }\n' >main.go && git add main.go
  idx_staged=$(sha256sum .git/index)
  lint main.go
  rc=$?
  res "new-from-rev: pre-existing debt does not block a clean change" PASS eq "$rc" 0
  printf 'package main\n\nimport "os"\n\nfunc main() { old(); os.Remove("z") }\n' >main.go && git add main.go
  lint main.go
  rc=$?
  res "new-from-rev: a new issue in the staged change still blocks" PASS eval '[ "$rc" != 0 ]'
  git add main.go
  sum1=$(sha256sum .git/index)
  lint main.go
  res "the real index is never written" PASS eval '[ "$sum1" = "$(sha256sum .git/index)" ] && [ "$idx_before" != "$idx_staged" ]'
)
(
  # A finding golangci-lint can fix (godot), which `issues.fix: true` would
  # fix in the copy and stop reporting.
  gorepo g3
  printf 'package main\n\n// main has no period\nfunc main() {}\n' >main.go
  printf 'version: "2"\nlinters:\n  enable:\n    - godot\nissues:\n  fix: true\n' >.golangci.yml
  git add -A
  lint main.go
  rc=$?
  res "--fix=false: a finding the config asks to fix is still reported" PASS eval '[ "$rc" != 0 ] && grep -q godot "$R.out" && git diff --quiet main.go'
)
(
  gorepo g4
  printf 'version: "2"\nlinters:\n  enable:\n    - godot\n' >.golangci.yml # untracked
  printf 'package main\n\n// main has no period\nfunc main() {}\n' >main.go && git add main.go
  lint main.go
  rc=$?
  res "an untracked config the working tree would use still applies" PASS eval '[ "$rc" != 0 ] && grep -q godot "$R.out"'
)
(
  gorepo g5
  printf 'version: "2"\nlinters:\n  enable:\n    - godot\n' >"$T/g5-parent.golangci.yml"
  mkdir -p "$T/g5parent" && mv "$T/g5-parent.golangci.yml" "$T/g5parent/.golangci.yml"
  newrepo g5parent/repo
  printf 'module example.com/m\n\ngo 1.22\n' >go.mod
  printf 'package main\n\n// main has no period\nfunc main() {}\n' >main.go
  git add -A
  lint main.go
  rc=$?
  res "a config in a parent directory of the repository still applies" PASS eval '[ "$rc" != 0 ] && grep -q godot "$R.out"'
)
# errgen: a staged package gen/ with an errcheck finding.
errgen() {
  mkdir -p gen && printf 'package gen\n\nimport "os"\n\nfunc G() { os.Remove("y") }\n' >gen/g.go && git add gen/g.go
}
# exclude RULE: a config excluding errcheck by the path rule RULE.
exclude() { printf 'version: "2"\nlinters:\n  exclusions:\n    rules:\n      - %s\n        linters: [errcheck]\n' "$1"; }
(
  # golangci-lint matches a config's path rules against paths relative to the
  # config's directory. A config read where it lay, outside the copy, met the
  # copy's files by their cache path: an exclusion stopped applying, and a
  # path-except hid what it should have kept. (Round-11 review.)
  gorepo g6
  errgen
  exclude 'path: ^gen/' >.golangci.yml # untracked
  lint gen/g.go
  res "an untracked config's path rule matches the staged files" PASS eq "$?" 0
  exclude 'path-except: ^gen/' >.golangci.yml
  lint gen/g.go
  rc=$?
  res "an untracked config's path-except keeps the finding in its path" PASS eval '[ "$rc" != 0 ] && grep -q errcheck "$R.out"'
)
(
  mkdir -p "$T/g7parent"
  exclude 'path: ^repo/gen/' >"$T/g7parent/.golangci.yml"
  newrepo g7parent/repo
  printf 'module example.com/m\n\ngo 1.22\n' >go.mod && git add go.mod
  errgen
  lint gen/g.go
  res "a parent directory's config's path rule matches, relative to that directory" PASS eq "$?" 0
)
(
  # $HOME is not above the repository here, so the rule climbs out of it.
  gorepo g8
  errgen
  exclude "path: ^$(realpath --relative-to="$HOME" "$R" | sed 's/[.]/\\./g')/gen/" >"$HOME/.golangci.yml"
  lint gen/g.go
  rc=$?
  rm -f "$HOME/.golangci.yml"
  res "a \$HOME config's path rule matches, relative to \$HOME" PASS eq "$rc" 0
)
(
  # A tracked symlink out of the repository: golangci-lint takes the config's
  # directory from where the symlink leads.
  mkdir -p "$T/g9shared"
  exclude 'path: ^\.\./g9/gen/' >"$T/g9shared/golangci.yml"
  gorepo g9
  ln -s ../g9shared/golangci.yml .golangci.yml && git add .golangci.yml
  errgen
  lint gen/g.go
  res "a config symlinked out of the repository: its path rule matches, relative to where it leads" PASS eq "$?" 0
)

echo "# ignored inputs and locations"
(
  gorepo i1
  printf 'gen_*.go\n' >.gitignore && git add .gitignore && git commit -qm ignore
  printf 'package main\n\nfunc (c color) String() string { return "red" }\n' >gen_color.go
  printf 'package main\n\ntype color int\n\nfunc main() { _ = color(0).String() }\n' >main.go && git add main.go
  lint main.go
  res "a git-ignored generated file the package needs is carried over" PASS eq "$?" 0
  res "the carried file is named" PASS grep -q 'gen_color.go' "$R.out"
  printf 'package main\n\nfunc broken( {\n' >wip2.go
  printf 'package main\n\nfunc (c color) Other() string { return "x" }\n' >untracked_ok.go
  lint main.go
  res "an untracked file git does not ignore is still left out" PASS eq "$?" 0
)
(
  newrepo i2
  mkdir -p a b
  printf 'module example.com/a\n\ngo 1.22\n' >a/go.mod
  printf 'module example.com/b\n\ngo 1.22\n' >b/go.mod
  printf 'package b\n\nfunc B() int { return 1 }\n' >b/b.go
  printf 'package main\n\nimport "example.com/b"\n\nfunc main() { _ = b.B() }\n' >a/main.go
  git add a b && git commit -qm modules
  printf 'go 1.22\n\nuse (\n\t./a\n\t./b\n)\n' >go.work # untracked: Go advises not to commit it
  printf 'package main\n\nimport "example.com/b"\n\nfunc main() { _ = b.B() + 1 }\n' >a/main.go && git add a/main.go
  GOFLAGS='' lint a/main.go # -mod=mod is refused in workspace mode
  res "an untracked go.work is carried over" PASS eq "$?" 0
)
(
  rm -rf "$T/i3x" && mkdir -p "$T/i3x"
  printf 'module example.com/x\n\ngo 1.22\n' >"$T/i3x/go.mod"
  printf 'package x\n\nfunc X() int { return 1 }\n' >"$T/i3x/x.go"
  gorepo i3
  printf 'module example.com/m\n\ngo 1.22\n\nrequire example.com/x v0.0.0\n\nreplace example.com/x => ../i3x\n' >go.mod
  printf 'package main\n\nimport "example.com/x"\n\nfunc main() { _ = x.X() }\n' >main.go
  git add -A
  lint main.go
  res "a replace pointing outside the repository resolves" PASS eq "$?" 0
)
(
  rm -rf "$T/ws" && mkdir -p "$T/ws/other"
  printf 'module example.com/other\n\ngo 1.22\n' >"$T/ws/other/go.mod"
  printf 'package other\n\nfunc O() int { return 1 }\n' >"$T/ws/other/o.go"
  newrepo ws/repo
  printf 'module example.com/m\n\ngo 1.22\n' >go.mod
  printf 'package main\n\nimport "example.com/other"\n\nfunc main() { _ = other.O() }\n' >main.go
  git add -A
  printf 'go 1.22\n\nuse (\n\t./repo\n\t./other\n)\n' >"$T/ws/go.work"
  GOFLAGS='' lint main.go # -mod=mod is refused in workspace mode
  res "a go.work in a parent directory (a multi-repository workspace) applies" PASS eq "$?" 0
  rm -f "$T/ws/go.work"
)
(
  newrepo i5
  printf 'package x\n\nfunc X() int { return 1 }\n' >x.go
  printf 'module example.com/x\n\ngo 1.22\n' >go.mod
  git add -A && git commit -qm x
  newrepo i5top
  printf 'module example.com/m\n\ngo 1.22\n\nrequire example.com/x v0.0.0\n\nreplace example.com/x => ./third_party_x\n' >go.mod
  printf 'package main\n\nimport "example.com/x"\n\nfunc main() { _ = x.X() }\n' >main.go
  git clone -q "$T/i5" third_party_x
  git add -A 2>/dev/null
  res "(setup) the submodule is a gitlink" PASS eq "$(git ls-files -s third_party_x | cut -c1-6)" 160000
  lint main.go
  res "a replace into a submodule finds its files at the recorded commit" PASS eq "$?" 0
)
(
  # The carry's go list runs in the working tree, where -mod=mod from GOFLAGS
  # let it add the missing requirement to go.mod, for a commit staging go.mod
  # to record. (Round-11 review.)
  rm -rf "$T/i7x" && mkdir -p "$T/i7x"
  printf 'module example.com/x\n\ngo 1.22\n' >"$T/i7x/go.mod"
  printf 'package x\n\nfunc X() int { return 1 }\n' >"$T/i7x/x.go"
  gorepo i7
  printf 'gen_*.go\n' >.gitignore
  printf 'module example.com/m\n\ngo 1.22\n\nreplace example.com/x => ../i7x\n' >go.mod
  git add -A && git commit -qm replace
  printf 'package main\n\nfunc gen() {}\n' >gen_a.go
  printf 'package main\n\nimport "example.com/x"\n\nfunc main() { gen(); _ = x.X() }\n' >main.go && git add main.go
  cp go.mod "$R.gomod"
  # The sandbox has no network to try, so log what that go list is told.
  mkdir -p "$T/i7bin"
  cat >"$T/i7bin/go" <<EOF
#!$BASH
[ "\$1" != list ] || printf '%s %s %s\n' "\$GOPROXY" "\$GONOPROXY" "\$*" >>"$R.golist"
exec $(command -v go) "\$@"
EOF
  chmod +x "$T/i7bin/go"
  PATH=$T/i7bin:$PATH GOFLAGS=-mod=mod GOPRIVATE='example.com/*' lint main.go
  res "GOFLAGS=-mod=mod: the working tree's go.mod is left alone" PASS cmp -s go.mod "$R.gomod"
  res "GOFLAGS=-mod=mod: the ignored file the package needs is still carried over" PASS grep -q 'gen_a.go' "$R.out"
  res "the working tree's go list may not download, private modules included" PASS grep -q '^off none list -mod=readonly ' "$R.golist"
)
(
  gorepo i6
  mkdir -p p q
  printf 'package p\n\nfunc Helper() int { return 1 }\n' >p/a.go
  printf 'package p\n\nfunc Use() int { return Helper() }\n' >p/b.go
  printf 'package q\n\nfunc Q() int { return 1 }\n' >q/q.go
  git add -A && git commit -qm pq
  git rm -q p/a.go
  printf 'package q\n\nfunc Q() int { return 2 }\n' >q/q.go && git add q/q.go
  lint q/q.go
  rc=$?
  res "the package that lost a file is linted too" PASS eval '[ "$rc" != 0 ] && grep -q "undefined: Helper" "$R.out"'
)
(
  # For a package with tests, go list -test also reports the test main, a file
  # in go's build cache; it reached check-ignore as an absolute path, git
  # refused it, and nothing was carried over. (Round-11 review.)
  gorepo i8
  printf 'gen_*.go\n' >.gitignore
  printf 'package main\n\nimport "testing"\n\nfunc TestX(t *testing.T) {}\n' >main_test.go
  git add -A && git commit -qm test
  printf 'package main\n\nfunc gen() int { return 1 }\n' >gen_a.go
  printf 'package main\n\nfunc main() { _ = gen() }\n' >main.go && git add main.go
  lint main.go
  res "a package with tests still gets its git-ignored generated file" PASS eq "$?" 0
)
(
  # A git-ignored build output that //go:embed takes (a web bundle): go list
  # reports it in EmbedFiles, which the carry did not read. (Round-11 review.)
  gorepo i9
  printf 'dist/\n' >.gitignore && git add .gitignore && git commit -qm ignore
  mkdir -p dist && printf 'x\n' >dist/app.js
  printf 'package main\n\nimport "embed"\n\n//go:embed dist\nvar dist embed.FS\n\nfunc main() { _ = dist }\n' >main.go && git add main.go
  lint main.go
  res "a git-ignored file that //go:embed takes is carried over" PASS eq "$?" 0
)
(
  # More carried names than a pipe holds: `| head -3` exited early, and under
  # pipefail the writer it left behind failed the hook. (Round-11 review.)
  gorepo i10
  printf 'gen_*.go\n' >.gitignore && git add .gitignore && git commit -qm ignore
  long=$(printf 'x%.0s' $(seq 1 150))
  for i in $(seq 1 450); do printf 'package main\n' >"gen_${long}_n$i.go"; done
  printf 'package main\n\nfunc main() { _ = 10 }\n' >main.go && git add main.go
  lint main.go
  rc=$?
  res "450 carried files (70 KiB of names) do not fail the hook" PASS eval '[ "$rc" = 0 ] && grep -q "using 450 untracked" "$R.out"'
)
(
  # direnv's `layout go` puts GOPATH, and so the module cache, in the
  # repository: the carry copied the dependencies' files in from there, though
  # go reads them by absolute path, and their read-only directories with them.
  # (Round-11 review.)
  privmod
  gorepo i11
  gopath=$R/.direnv/go
  printf '.direnv/\n' >.gitignore
  printf 'module example.com/m\n\ngo 1.22\n\nrequire example.com/priv/x.git v1.0.0\n' >go.mod
  printf 'package main\n\nimport "example.com/priv/x.git"\n\nfunc main() { _ = x.X() }\n' >main.go
  GOPATH=$gopath go mod tidy >"$R.tidy" 2>&1
  git add -A && git commit -qm dep
  printf 'package main\n\nimport "example.com/priv/x.git"\n\nfunc main() { _ = x.X() + 1 }\n' >main.go && git add main.go
  GOPATH=$gopath lint main.go
  rc=$?
  res "(setup) the module cache is in the repository" PASS eval '[ -n "$(find .direnv/go/pkg/mod -name x.go)" ]'
  res "a module cache in the repository (direnv layout go) is not copied in" PASS eval '[ "$rc" = 0 ] && ! grep -q "pkg/mod" "$R.out" && [ "$(leftover_trees)" = 0 ]'
  chmod -R u+w .direnv
)
(
  # go fetches a module the module cache lacks, a private one with git, in a
  # repository it creates with `git init --bare`. The GIT_* variables
  # golangci-lint gets for new-from-rev reached that git, which refused to run;
  # with GIT_DIR alone it would have turned this repository bare.
  # (Round-11 review.)
  privmod
  gopath=$TMPDIR/gopath-i12
  gorepo i12
  printf 'package main\n\nimport "os"\n\nfunc old() { os.Remove("x") }\n' >old.go
  printf 'version: "2"\nissues:\n  new-from-rev: HEAD\n' >.golangci.yml
  git add -A && git commit -qm debt
  printf 'module example.com/m\n\ngo 1.22\n\nrequire example.com/priv/x.git v1.0.0\n' >go.mod
  printf 'package main\n\nimport "example.com/priv/x.git"\n\nfunc main() { old(); _ = x.X() }\n' >main.go
  git add -A
  GOPATH=$gopath lint main.go
  rc=$?
  res "new-from-rev, with a private module fetched with git during the hook" PASS eq "$rc" 0
  res "the fetch leaves this repository as it was (not bare)" PASS eq "$(git config --type=bool core.bare)" false
  chmod -R u+w "$gopath"
)
(
  # A file go lists inside a submodule: check-ignore aborts on such a path, and
  # the files after it in its input were never carried.
  newrepo i13dep
  printf 'module example.com/x\n\ngo 1.22\n' >go.mod
  printf 'package x\n\nfunc X() int { return 1 }\n' >x.go
  git add -A && git commit -qm x
  gorepo i13
  printf 'zz_gen_*.go\n' >.gitignore
  printf 'module example.com/m\n\ngo 1.22\n\nrequire example.com/x v0.0.0\n\nreplace example.com/x => ./a_dep\n' >go.mod
  git clone -q "$T/i13dep" a_dep
  git add -A 2>/dev/null && git commit -qm dep
  printf 'package x\n' >a_dep/extra.go # untracked in the submodule
  printf 'package main\n\nfunc gen() int { return 1 }\n' >zz_gen_a.go
  printf 'package main\n\nimport "example.com/x"\n\nfunc main() { _ = x.X() + gen() }\n' >main.go && git add main.go
  lint main.go
  rc=$?
  res "(setup) the dependency is a submodule" PASS eq "$(git ls-files -s a_dep | cut -c1-6)" 160000
  res "a file go lists inside a submodule does not stop the carry" PASS eval '[ "$rc" = 0 ] && grep -q zz_gen_a.go "$R.out"'
)

echo "# tflint"
(
  newrepo t1
  printf '.terraform/\n' >.gitignore
  printf 'module "sg" {\n  source  = "example/sg/aws"\n  version = "1.0.0"\n}\n' >main.tf
  printf 'config {\n  call_module_type = "all"\n}\nrule "terraform_required_version" {\n  enabled = false\n}\n' >.tflint.hcl
  mkdir -p .terraform/modules/sg
  printf 'variable "x" {\n  default = 1\n}\n' >.terraform/modules/sg/main.tf
  printf '{"Modules":[{"Key":"","Source":"","Dir":"."},{"Key":"sg","Source":"registry.terraform.io/example/sg/aws","Version":"1.0.0","Dir":".terraform/modules/sg"}]}\n' >.terraform/modules/modules.json
  git add -A
  "$LINT_OPENTOFU" main.tf >"$R.out" 2>&1
  res "tflint call_module_type=all finds the modules tofu init downloaded" PASS eq "$?" 0
)
(
  newrepo t2
  printf 'resource "null_resource" "a" {}\n' >main.tf
  printf 'config {\n  plugin_dir = "./my-plugins"\n}\nrule "terraform_required_version" {\n  enabled = false\n}\nrule "terraform_required_providers" {\n  enabled = false\n}\n' >.tflint.hcl
  mkdir -p my-plugins
  git add main.tf .tflint.hcl
  TFLINT_LOG=debug "$LINT_OPENTOFU" main.tf >"$R.out" 2>&1
  rc=$?
  res "a relative plugin_dir is resolved in the working tree, not the copy" PASS eval '[ "$rc" = 0 ] && grep -q "PluginDir: $R/./my-plugins" "$R.out"'
)
(
  # A directory named like an awk assignment: awk took env=prod/.tflint.hcl
  # for one and read the loop's list of directories in its place. The config
  # came out empty, its naming rule off, or held the next directory's name,
  # a directory then never linted. (Round-11 review.)
  newrepo t3
  # Clean for tflint's default rules, so only the naming rule can fail it.
  tfmodule() {
    mkdir -p "$1"
    printf 'terraform {\n  required_version = ">= 1.0"\n  required_providers {\n    null = {\n      source  = "hashicorp/null"\n      version = "~> 3.0"\n    }\n  }\n}\n\nresource "null_resource" "%s" {}\n' "$2" >"$1/main.tf"
    printf 'rule "terraform_naming_convention" {\n  enabled = true\n}\n' >"$1/.tflint.hcl"
  }
  tfmodule 'env=prod' BadName
  git add -A
  "$LINT_OPENTOFU" 'env=prod/main.tf' >"$R.out" 2>&1
  rc=$?
  res "a directory named env=prod is linted with its own .tflint.hcl" PASS eval '[ "$rc" != 0 ] && grep -q BadName "$R.out"'
  tfmodule 'env=prod' ok
  tfmodule zz AlsoBad
  git add -A
  "$LINT_OPENTOFU" 'env=prod/main.tf' zz/main.tf >"$R.out" 2>&1
  rc=$?
  res "... and the directories after it are linted too" PASS eval '[ "$rc" != 0 ] && grep -q AlsoBad "$R.out"'
)

echo "# trivy"
(
  # A root module below the scanned directory, named like it: trivy resolves a
  # relative --skip-files against the current directory first, so infra/*.tf,
  # meant for infra/infra, skipped infra's own files. (Round-11 review.)
  newrepo s1
  mkdir -p infra/infra
  printf 'resource "aws_s3_bucket" "b" {\n  bucket = "public"\n  acl    = "public-read"\n}\n' >infra/main.tf
  printf 'resource "null_resource" "a" {}\n' >infra/infra/main.tf
  git add -A
  s=$(date +%s%N)
  "$SECURITY_OPENTOFU" infra/main.tf >"$R.out" 2>&1
  rc=$?
  echo "   s1 security-opentofu, offline: rc=$rc $((($(date +%s%N) - s) / 1000000))ms"
  res "a root module at infra/infra does not hide infra's own findings" PASS eval '[ "$rc" != 0 ] && grep -q AWS-0092 "$R.out"'
)
(
  newrepo s2
  mkdir -p envs/prod modules/bucket
  printf 'resource "null_resource" "a" {}\n' >main.tf
  printf 'resource "aws_s3_bucket" "b" {\n  bucket = "public"\n  acl    = "public-read"\n}\n' >envs/prod/main.tf
  git add -A
  "$SECURITY_OPENTOFU" main.tf >"$R.out" 2>&1
  res "another root module below the scanned directory is skipped" PASS eq "$?" 0
  cp envs/prod/main.tf modules/bucket/main.tf
  printf 'module "b" {\n  source = "./modules/bucket"\n}\n' >>main.tf
  git add -A
  "$SECURITY_OPENTOFU" main.tf >"$R.out" 2>&1
  rc=$?
  res "a module the scanned directory calls is scanned" PASS eval '[ "$rc" != 0 ] && grep -q AWS-0092 "$R.out"'
)

echo "# the rendered lint-go jobs"
(
  # lefthook leaves a deleted file out of {staged_files} and skips a job left
  # with no files, so lint-go's own job does not run for a commit whose only
  # Go change is a deletion. lint-go-deletions, with no file template and no
  # glob, lints that one. LINT_GO_CONFIG is lint-go's render, as the go lane
  # commits it.
  gorepo h1
  printf 'package main\n\nfunc helper() {}\n' >helper.go
  printf 'package main\n\nfunc main() { helper() }\n' >main.go
  git add -A && git commit -qm helper
  use_render "$LINT_GO_CONFIG"
  PATH=${LINT_GO%/*}:$PATH
  git rm -q helper.go
  printf 'package main\n\nfunc main() { helper(); helper() }\n' >main.go && git add main.go
  git commit -qm 'delete helper, edit main' >"$R.out" 2>&1
  rc=$?
  res "a .go deletion committed with another .go change is linted" PASS eval '[ "$rc" != 0 ] && grep -q "undefined: helper" "$R.out"'
  git reset -q HEAD main.go && git checkout -q main.go
  git commit -qm 'delete helper' >"$R.out" 2>&1
  rc=$?
  res "a commit that only deletes a .go file is linted" PASS eval '[ "$rc" != 0 ] && grep -q "undefined: helper" "$R.out"'
  # magit commits with `git --literal-pathspecs commit`, which exports
  # GIT_LITERAL_PATHSPECS to the hook: lint-go's patterns matched nothing, and
  # the commit landed unlinted. (2026-10-21 panel.)
  git --literal-pathspecs commit -qm 'delete helper' >"$R.out" 2>&1
  rc=$?
  res "... also when made with git --literal-pathspecs" PASS eval '[ "$rc" != 0 ] && grep -q "undefined: helper" "$R.out"'
  # lefthook lists a renamed file by its new name only: a job with a glob of
  # *.go would not see this one.
  git reset -q && git checkout -q helper.go
  git mv helper.go helper.go.orig
  git commit -qm 'rename helper away' >"$R.out" 2>&1
  rc=$?
  res "a commit that only renames a .go file to a name without .go is linted" PASS eval '[ "$rc" != 0 ] && grep -q "undefined: helper" "$R.out"'
)
(
  # lint-go-deletions runs for every commit. It lints nothing for one with no
  # Go change, so it needs no go then, and leaves a deletion to lint-go's own
  # job when a .go file is added or modified too.
  gorepo h2
  mkdir -p lib
  printf 'package lib\n\nfunc helper() {}\n' >lib/a.go
  printf 'package lib\n\nfunc F() { helper() }\n' >lib/b.go
  git add -A && git commit -qm lib
  printf 'doc\n' >README.md && git add README.md
  PATH=/nonexistent lint --deletions
  rc=$?
  res "lint-go --deletions passes a commit with no Go change, with no go on PATH" PASS eq "$rc" 0
  git rm -q lib/a.go
  printf 'package main\n\nfunc main() { _ = 2 }\n' >main.go && git add main.go
  lint --deletions
  rc=$?
  res "lint-go --deletions leaves a deletion to lint-go when a .go file changes too" PASS eval '[ "$rc" = 0 ] && ! grep -q "undefined: helper" "$R.out"'
  lint main.go
  rc=$?
  res "... which lints the package that lost the file" PASS eval '[ "$rc" != 0 ] && grep -q "undefined: helper" "$R.out"'
)

echo "# commits made with git --literal-pathspecs"
(
  # magit commits with `git --literal-pathspecs commit` by default, which
  # exports GIT_LITERAL_PATHSPECS to the hook. The patterns the wrappers pass
  # git then matched nothing, and check-ignore refused to run. (2026-10-21
  # panel.)
  gorepo lp1
  printf 'gen_*.go\n' >.gitignore && git add .gitignore && git commit -qm ignore
  printf 'package main\n\nfunc (c color) String() string { return "red" }\n' >gen_color.go
  printf 'package main\n\ntype color int\n\nfunc main() { _ = color(0).String() }\n' >main.go && git add main.go
  GIT_LITERAL_PATHSPECS=1 lint main.go
  res "a git-ignored generated file the package needs is still carried over" PASS eq "$?" 0
)
(
  gorepo lp2
  mkdir -p p q
  printf 'package p\n\nfunc Helper() int { return 1 }\n' >p/a.go
  printf 'package p\n\nfunc Use() int { return Helper() }\n' >p/b.go
  printf 'package q\n\nfunc Q() int { return 1 }\n' >q/q.go
  git add -A && git commit -qm pq
  git rm -q p/a.go
  printf 'package q\n\nfunc Q() int { return 2 }\n' >q/q.go && git add q/q.go
  GIT_LITERAL_PATHSPECS=1 lint q/q.go
  rc=$?
  res "the package that lost a file is still linted too" PASS eval '[ "$rc" != 0 ] && grep -q "undefined: Helper" "$R.out"'
)

echo "# cost"
(
  gorepo c1
  mkdir -p big
  for i in $(seq 1 5000); do printf 'line %s\n' "$i" >"big/f$i.txt"; done
  git add -A && git commit -qm big
  printf 'package main\n\nfunc main() { _ = 1 }\n' >main.go && git add main.go
  lint main.go
  s=$(date +%s%N)
  lint main.go
  t1=$((($(date +%s%N) - s) / 1000000))
  echo "   c1 warm lint-go with 5003 tracked files: ${t1}ms"
)

summary 82
