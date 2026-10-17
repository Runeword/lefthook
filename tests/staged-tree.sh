#!/usr/bin/env bash
# Assertions are strings res() evals, so $ inside single quotes is meant.
# shellcheck disable=SC1091,SC2016,SC2034
# Behavioural checks for scripts/staged-tree.sh through the wrappers that use
# it (flake check `behaviour-staged-tree`). See tests/lib.sh for the result
# format. trivy needs a checks bundle from the network, so security-opentofu
# is exercised outside the sandbox only.
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

# A failing test shows the tail of what the wrapper printed.
eval "lib_$(declare -f res)"
res() {
  lib_res "$@"
  case $(tail -1 "$T/results") in
    UNEXPECTED*) if [ -f "${R:-}.out" ]; then tail -15 "$R.out" | sed 's/^/      | /'; fi ;;
  esac
}

# gorepo NAME: a committed Go module (example.com/m) with one main package.
gorepo() {
  newrepo "$1"
  printf 'module example.com/m\n\ngo 1.22\n' >go.mod
  printf 'package main\n\nfunc main() {}\n' >main.go
  git add -A && git commit -qm base
}
lint() { "$LINT_GO" "$@" >"$R.out" 2>&1; }
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
  printf 'package main\n\nfunc secret2( {\n' >secret2.go # unstaged, broken: the blob must be used, smudged
  lint main.go
  rc=$?
  git config --global --unset filter.rot.clean
  git config --global --unset filter.rot.smudge
  res "filtered neighbours reach the linter in working-tree form (clean: copied; changed: smudged blob)" PASS eq "$rc" 0
)

echo "# where the copy lives"
(
  gorepo l1
  printf 'package main\n\nimport "os"\n\nfunc main() { os.Remove("x") }\n' >main.go && git add main.go
  mkdir -p "$T/shared" && printf 'version: "2"\nlinters:\n  disable:\n    - errcheck\n' >"$T/shared/.golangci.yml"
  mkdir -p "$T/shared/tmp"
  (
    unset XDG_RUNTIME_DIR
    TMPDIR=$T/shared/tmp "$LINT_GO" main.go >"$R.out" 2>&1
  )
  rc=$?
  res "a lint config next to TMPDIR does not apply (the copy is not under TMPDIR)" PASS eval '[ "$rc" != 0 ]'
  res "the copy's directory is under ~/.cache/lefthook/staged, per repository and hook" PASS eval '[ -e "$(echo "$STAGED"/*/lint-go/lock | cut -d" " -f1)" ]'
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
  gorepo l3
  printf 'package main\n\nfunc main() { _ = 2 }\n' >main.go && git add main.go
  GIT_DIR=.git GIT_WORK_TREE=. "$LINT_GO" main.go >"$R.out" 2>&1
  res "relative GIT_DIR and GIT_WORK_TREE are honoured" PASS eq "$?" 0
)
(
  gorepo l4
  printf 'package main\n\nfunc main() { _ = 3 }\n' >main.go && git add main.go
  lint main.go
  key=$(git rev-parse --path-format=absolute --git-common-dir | tr -d "\n" | git hash-object --stdin | cut -c1-16)
  mkdir -p "$STAGED/$key/lint-go/tree/leak" && touch "$STAGED/$key/lint-go/tree/leak/x"
  lint main.go
  res "a copy left by a killed run of the same hook is reclaimed by the next run" PASS eval '[ ! -e "$STAGED/$key/lint-go/tree" ]'
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
  # lefthook SIGKILLs the job's process group on ^C: no trap runs.
  gorepo l5
  for i in $(seq 1 40); do printf 'package main\n\nfunc f%s() {}\n' "$i" >"f$i.go"; done
  git add -A && git commit -qm many
  printf 'package main\n\nfunc main() {\n' >main.go && for i in $(seq 1 40); do printf '\tf%s()\n' "$i" >>main.go; done && printf '}\n' >>main.go && git add main.go
  set -m
  "$LINT_GO" main.go >"$R.out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ -n "$(find "$STAGED" -mindepth 4 -maxdepth 4 -path '*/lint-go/tree/main.go' 2>/dev/null)" ] && break
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
  gorepo g3
  printf 'package main\n\nimport "os"\n\nfunc main() { os.Remove("x") }\n' >main.go
  printf 'version: "2"\nissues:\n  fix: true\n' >.golangci.yml
  git add -A
  lint main.go
  rc=$?
  res "--fix=false: a fixable config does not hide the finding" PASS eval '[ "$rc" != 0 ] && git diff --quiet main.go'
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

summary
