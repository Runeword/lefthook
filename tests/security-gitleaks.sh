#!/usr/bin/env bash
# Behavioural checks for scripts/security-gitleaks.sh (flake check
# `behaviour-security-gitleaks`). See tests/lib.sh for the result format.
#
# The scan runs on a copy of the wrapper pointed at a one-rule config that
# flags a harmless marker, so nothing in these files looks like a secret.
#
# Assertions are single-quoted strings that `res` evaluates later.
# shellcheck disable=SC1091,SC2016
set -u
# shellcheck source=tests/lib.sh
. "$TEST_LIB"

printf '[[rules]]\nid = "test-marker"\ndescription = "a test marker"\nregex = %s\n' \
  "'''lefthook-test-marker-[0-9]{4}'''" >"$T/marker.toml"
SCAN=$T/security-gitleaks
sed "s|^GITLEAKS_CONFIG_FILE=.*|GITLEAKS_CONFIG_FILE=$T/marker.toml|" "$SECURITY_GITLEAKS" >"$SCAN"
chmod +x "$SCAN"

echo "## naming the files"
(
  # The loop that names the offending files diffs each path. As a pathspec,
  # g*.txt took in gx.txt's lines and :x.txt meant x.txt, so the report also
  # named files that hold nothing. (2026-10-21 panel.)
  newrepo g1
  printf 'base\n' >keep && git add -A && git commit -qm base
  printf 'clean\n' >'g*.txt' && printf 'clean\n' >':x.txt'
  printf 'lefthook-test-marker-1234\n' >gx.txt && printf 'lefthook-test-marker-5678\n' >x.txt
  git add -A
  "$SCAN" >"$R.out" 2>&1
  rc=$?
  res "G1 a marker in the staged changes fails the scan" PASS eq "$rc" 1
  res "G1 the report names the files that hold it" PASS eval 'grep -qxF "  gx.txt" "$R.out" && grep -qxF "  x.txt" "$R.out"'
  res "G1 ... and not g*.txt or :x.txt, which only match them as patterns" PASS eval '! grep -qxF "  g*.txt" "$R.out" && ! grep -qxF "  :x.txt" "$R.out"'
  # `git --literal-pathspecs commit`, magit's default, exports
  # GIT_LITERAL_PATHSPECS to the hook, and git refused the `:(literal)` paths.
  GIT_LITERAL_PATHSPECS=1 "$SCAN" >"$R.out" 2>&1
  rc=$?
  res "G1 under git --literal-pathspecs: the scan fails and the report names the files" PASS eval '[ "$rc" = 1 ] && grep -qxF "  gx.txt" "$R.out" && grep -qxF "  x.txt" "$R.out"'
)

summary 4
