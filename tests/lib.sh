#!/usr/bin/env bash
# Shared helpers for the behavioural checks in tests/*.sh, sourced by each.
#
# They run inside the Nix build sandbox (flake.nix `checks.behaviour-*`): real
# git, real lefthook, no network, a throwaway HOME. Every test records one line:
#
#   <ok|UNEXPECTED> <PASS|FAIL> (expect <PASS|FAIL>) <name>
#
# `expect FAIL` marks a known, documented limitation. The check goes red both
# when a passing behaviour regresses and when a known limitation starts to
# pass: then flip the expectation and fix the documentation that describes it.

T=${TMPDIR:?}/t
mkdir -p "$T"
: >"$T/results"

# res NAME EXPECT CMD...: run CMD and record PASS/FAIL against EXPECT.
res() {
  local name=$1 expect=$2 got tag
  shift 2
  if "$@"; then got=PASS; else got=FAIL; fi
  if [ "$got" = "$expect" ]; then tag=ok; else tag=UNEXPECTED; fi
  printf '%-10s %-4s (expect %-4s) %s\n' "$tag" "$got" "$expect" "$name" | tee -a "$T/results"
}

eq() { [ "$1" = "$2" ]; }

# newrepo NAME: a fresh repository at $T/NAME; cds into it and sets R.
newrepo() {
  R=$T/$1
  rm -rf "$R"
  mkdir -p "$R" && cd "$R" || exit 9
  git init -q
}

# use_render CONFIG: commit through CONFIG, one of this flake's renders, as a
# consumer does: it becomes lefthook-generated.yml, which a lefthook.yml
# extends, both kept out of the commits, and the hooks are installed.
use_render() {
  cp "$1" lefthook-generated.yml
  printf 'extends:\n  - lefthook-generated.yml\n' >lefthook.yml
  printf 'lefthook.yml\nlefthook-generated.yml\n' >>.git/info/exclude
  lefthook install >/dev/null 2>&1
}

commits() { git rev-list --count HEAD 2>/dev/null || echo 0; }

# idx / headtree: "mode oid<TAB>path" for the index and for HEAD's tree.
idx() { git ls-files -s | sed 's/^\([0-7]*\) \([0-9a-f]*\) [0-3]\t/\1 \2\t/'; }
headtree() { git ls-tree -r --full-tree HEAD | sed 's/^\([0-7]*\) [a-z]* \([0-9a-f]*\)\t/\1 \2\t/'; }

# instrument WRAPPER ON AT CMD: print the path of a copy of WRAPPER (a
# writeShellApplication script) whose PATH starts with a git shim. The shim
# passes every call through to the real git and, right after the AT-th
# successful `git ON …` (ON is the subcommand, found past any -c/-C options),
# runs the shell snippet CMD once, from git's directory, with the hook's index
# override unset. It stands in for another terminal acting mid-run,
# deterministically. Each call resets the counter.
instrument() {
  local wrapper=$1 on=$2 at=$3 cmd=$4 dir
  dir=$(mktemp -d "$T/shim.XXXXXX")
  printf '0\n' >"$dir/count"
  printf '%s\n' "$cmd" >"$dir/cmd"
  cat >"$dir/git" <<EOF
#!$BASH
$REAL_GIT "\$@"
rc=\$?
sub= skip=
for a in "\$@"; do
  if [ -n "\$skip" ]; then skip=; continue; fi
  case \$a in
    -c | -C) skip=1 ;;
    -*) ;;
    *) sub=\$a; break ;;
  esac
done
if [ "\$rc" = 0 ] && [ "\$sub" = "$on" ]; then
  n=\$((\$(cat "$dir/count") + 1))
  printf '%s\n' "\$n" >"$dir/count"
  if [ "\$n" = "$at" ]; then
    (
      unset GIT_INDEX_FILE LEFTHOOK_AUTO_COMMIT_SPLITTING LEFTHOOK
      PATH=${REAL_GIT%/*}:\$PATH
      . "$dir/cmd"
    ) </dev/null >"$dir/out" 2>&1
  fi
fi
exit "\$rc"
EOF
  chmod +x "$dir/git"
  sed "s|^export PATH=\"|export PATH=\"$dir:|" "$wrapper" >"$dir/wrapper"
  chmod +x "$dir/wrapper"
  printf '%s\n' "$dir/wrapper"
}

# fired WRAPPER: whether the snippet of an instrumented WRAPPER ran, so that a
# test cannot pass because its injection point was never reached.
fired() { [ -e "${1%/wrapper}/out" ]; }

# summary EXPECTED: print the tally; fail when any line is UNEXPECTED, or when
# there are not EXPECTED lines: a subshell that dies early (set -u) records
# nothing, and the check stayed green.
summary() {
  local n u
  n=$(wc -l <"$T/results")
  u=$(grep -c '^UNEXPECTED' "$T/results" || true)
  echo "SUMMARY results=$n (expected $1) unexpected=$u"
  [ "$u" = 0 ] && [ "$n" = "$1" ]
}
