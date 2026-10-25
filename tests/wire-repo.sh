#!/usr/bin/env bash
# Behavioural checks for scripts/wire-repo.sh (flake check
# `behaviour-wire-repo`). See tests/lib.sh for the result format.
#
# Assertions are single-quoted strings that `res` evaluates later.
# shellcheck disable=SC1091,SC2016
set -u
# shellcheck source=tests/lib.sh
. "$TEST_LIB"

# What wire-repo is given to write as lefthook-generated.yml: any config does.
printf 'pre-commit:\n  jobs:\n    - name: x\n      run: "true"\n' >"$T/render.yml"
wire() { "$WIRE_REPO" "$T/render.yml" lefthook --no-install >"$R.out" 2>&1; }

echo "## the main config"
(
  newrepo w1
  wire
  res "W1 no config: a lefthook.yml extending the generated one is written and named" PASS eval '[ "$(cat lefthook.yml)" = "$(printf "extends:\n  - lefthook-generated.yml")" ] && grep -q "wrote lefthook-generated.yml and lefthook.yml" "$R.out"'
)
(
  newrepo w2
  printf 'pre-commit:\n  jobs: []\n' >lefthook.yml
  wire
  res "W2 a lefthook.yml that does not extend the generated config is warned about" PASS grep -q "lefthook.yml does not extend lefthook-generated.yml" "$R.out"
)
(
  # Under another name lefthook loads, a lefthook.yml would shadow it: none is
  # written, and the warning says to extend the generated config from there.
  newrepo w3
  printf 'pre-commit:\n  jobs: []\n' >.lefthook.yml
  wire
  res "W3 a .lefthook.yml that does not extend the generated config: no lefthook.yml, a warning naming it" PASS eval '[ ! -e lefthook.yml ] && grep -q "already has .lefthook.yml" "$R.out"'
)
(
  # Once it does, there is nothing to warn about. The warning was printed
  # regardless, into every mkHooksCheck log of such a repository too.
  # (2026-10-24.)
  newrepo w4
  printf 'extends:\n  - lefthook-generated.yml\n' >.lefthook.yml
  mkdir -p .config && printf '{"extends": ["lefthook-generated.yml"]}\n' >.config/lefthook.json
  wire
  res "W4 a .lefthook.yml that extends the generated config: no lefthook.yml, no warning" PASS eval '[ ! -e lefthook.yml ] && ! grep -q warning "$R.out"'
  rm .lefthook.yml
  wire
  res "W4 ... nor for a .config/lefthook.json that does" PASS eval '[ ! -e lefthook.yml ] && ! grep -q warning "$R.out"'
)
(
  # A commented-out line extends nothing.
  newrepo w5
  printf 'extends:\n  # - lefthook-generated.yml\n' >.lefthook.yml
  wire
  res "W5 a .lefthook.yml whose extends line is commented out is warned about" PASS grep -q "already has .lefthook.yml" "$R.out"
)

summary 6
