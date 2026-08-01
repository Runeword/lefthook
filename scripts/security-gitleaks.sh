#!/bin/sh
# Scan the staged changes for secrets.
#
# A wrapper rather than a `run:` one-liner, because four separate guarantees
# were being lost in the config:
#
#   * `gitleaks git --staged` reads `git diff`, which honours `.gitattributes`:
#     one `*.env -diff` (or `binary`) line committed to the repository silently
#     drops those paths from the scan. `--text` below overrides that and cannot
#     be switched off from inside the repository.
#   * lefthook runs `run:` through `sh -c` with pipefail OFF, so in a pipeline
#     only the LAST command's status survives — if `git diff` failed, gitleaks
#     scanned empty input and the hook PASSED. Here the diff is captured and
#     checked before anything is scanned.
#   * gitleaks resolves `.gitleaks.toml` from the working directory, so a
#     repository can ship `[allowlist] regexes = ['''.*''']` and disable the
#     scan outright. The ruleset is pinned to the flake's copy instead. A
#     project that genuinely needs different rules disables the hook in its Nix
#     config, where the decision is visible.
#   * scanning the whole diff flags secrets being DELETED and ones sitting on
#     unchanged context lines, so the very commit that removes a secret is
#     blocked, and every later edit near an old one is blocked forever. Only
#     added lines are scanned, which is what `gitleaks git --staged` did.

# An empty result from a failed diff is indistinguishable from "nothing staged"
# by the time it reaches gitleaks, so refuse to report a clean scan instead.
if ! diff=$(git diff --cached --text --diff-filter=ACMR); then
  echo "security-gitleaks: 'git diff --cached' failed; refusing to report a clean scan" >&2
  exit 1
fi

# Added lines only, dropping the `+++ b/path` file headers.
added=$(printf '%s\n' "$diff" | sed -n '/^+++/!{/^+/p;}') || true
if [ "$added" = "" ]; then
  exit 0
fi

if printf '%s\n' "$added" |
  gitleaks stdin --redact --no-banner --log-level=warn --config="$GITLEAKS_CONFIG_FILE"; then
  exit 0
fi

# `gitleaks stdin` has no path context, so the report above names no file — on a
# large commit that leaves the developer hunting. Re-scan per staged path just
# to say where. Diagnostic only: the exit status was already decided above.
echo "security-gitleaks: secret(s) found in the staged changes to:" >&2
git -c core.quotePath=false diff --cached --name-only --diff-filter=ACMR |
  while IFS= read -r path; do
    [ "$path" != "" ] || continue
    if ! git diff --cached --text -- "$path" |
      sed -n '/^+++/!{/^+/p;}' |
      gitleaks stdin --no-banner --log-level=error --config="$GITLEAKS_CONFIG_FILE" >/dev/null 2>&1; then
      printf '  %s\n' "$path" >&2
    fi
  done
exit 1
