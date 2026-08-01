#!/bin/sh
# Point the current git repository at a rendered lefthook config, and install
# the hooks.
#
# Shared by `lefthook-init` and the dev shell's shellHook. Both used to carry
# their own copy of this sequence, in two languages, and had already drifted:
# only one of them kept `lefthook-local.yml` out of the index.
#
# Usage: wire-repo <rendered-config> <lefthook-binary> [--no-install] [--warn-drift]
#
#   --no-install   write the files but leave .git/hooks alone. Used when the
#                  caller has decided the repository's own lefthook.yml must
#                  not be activated without consent.
#   --warn-drift   never overwrite an existing lefthook-generated.yml: create
#                  it when missing, but when it drifts from the render, print a
#                  warning naming `lefthook-regen` instead of rewriting it.
#                  Used by the dev shell's shellHook, so entering a directory
#                  reconciles only unversioned state (.git/hooks, info/exclude)
#                  — rewriting a tracked file stays an explicit action.

usage() {
  echo "usage: wire-repo <rendered-config> <lefthook-binary> [--no-install] [--warn-drift]" >&2
  exit 2
}

# Exposed as a package, so misuse comes from outside this flake too: fail with a
# usage message rather than `$1: unbound variable`, and before any file is
# written — a two-argument call that put a flag in $2 used to mutate the
# repository and only then fail on the missing binary.
if [ "$#" -lt 2 ] || [ "$1" = "" ] || [ "$2" = "" ]; then
  usage
fi
case $2 in
  --no-install | --warn-drift) usage ;;
esac
rendered=$1
lefthook_bin=$2
shift 2
# Flags are validated rather than merely compared: --no-install is the consent
# gate, so a typo like `--no-instal` must not silently fall through to
# installing hooks.
install_hooks=true
warn_drift=false
for flag in "$@"; do
  case $flag in
    --no-install) install_hooks=false ;;
    --warn-drift) warn_drift=true ;;
    *) usage ;;
  esac
done

# Checked here rather than by each caller, so neither needs git on its own PATH.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "lefthook: not inside a git work tree; skipping hook install" >&2
  exit 0
fi
project_root=$(git rev-parse --show-toplevel)
cd "$project_root" || exit 1

# Materialize the rendered config as a plain file, meant to be committed: the
# hook definitions then travel with the repository rather than depending on
# this machine's Nix store surviving garbage collection. install(1) rather than
# cp: cp -f writes THROUGH a symlink, so a link planted here would redirect the
# write out of the repository. The `-L` test comes first because `cmp` follows
# symlinks: a link whose target happens to hold the current render would
# otherwise be left in place and later committed as a symlink to a store path,
# which dangles on every other machine.
#
# Under --warn-drift only a MISSING config is created (first-time wiring has
# nothing to preserve); an existing file that differs — or is a symlink — is
# reported and left alone. The rewrite is `lefthook-regen`, which runs this
# script without the flag; the `mkConfigCheck` flake check is what makes
# ignoring the warning fail loudly instead of drifting silently.
if [ -L lefthook-generated.yml ] || ! cmp -s "$rendered" lefthook-generated.yml 2>/dev/null; then
  if [ "$warn_drift" = true ] && { [ -e lefthook-generated.yml ] || [ -L lefthook-generated.yml ]; }; then
    echo "lefthook: warning: lefthook-generated.yml no longer matches what the flake renders;" >&2
    echo "lefthook: warning: run 'lefthook-regen' to rewrite it, then commit the result." >&2
  else
    install -m 644 "$rendered" lefthook-generated.yml
  fi
fi

# Migration: drop the git-ignored symlink older versions left behind.
if [ -L .lefthook-generated.yml ]; then
  rm -f .lefthook-generated.yml
fi

# lefthook merges a per-user "-local" config automatically, under any of three
# stems and five extensions; keep them all out of the index even in repositories
# that don't list them in a tracked .gitignore. Globs rather than the 15 literal
# names, so a new upstream extension is covered too. A hand-edited exclude file
# may lack its final newline, and `>>` would then fuse our entry onto that last
# line — destroying the user's pattern and failing to exclude ours — so
# terminate it first.
exclude=$(git rev-parse --git-path info/exclude)
mkdir -p "$(dirname "$exclude")"
remaining_patterns='lefthook-local.* .lefthook-local.* .config/lefthook-local.*'
while [ "$remaining_patterns" != "" ]; do
  case $remaining_patterns in
    *' '*)
      pattern=${remaining_patterns%% *}
      remaining_patterns=${remaining_patterns#* }
      ;;
    *)
      pattern=$remaining_patterns
      remaining_patterns=""
      ;;
  esac
  grep -qxF "$pattern" "$exclude" 2>/dev/null && continue
  if [ -s "$exclude" ] && [ "$(tail -c 1 "$exclude")" != "" ]; then
    printf '\n' >>"$exclude"
  fi
  printf '%s\n' "$pattern" >>"$exclude"
done

# Seed a root config only if the repository doesn't have one; warn when an
# existing one silently ignores the generated file. Three cases, because `-e` is
# false for a dangling symlink while `-L` is true: a real config, a dangling
# link (which must be unlinked — `>` through it would write outside the repo,
# and lefthook would otherwise create its own config there), or nothing.
if [ -e lefthook.yml ]; then
  # Comments stripped first: a commented-out `- lefthook-generated.yml` line, or
  # a passing mention, used to suppress this warning in exactly the case it
  # exists for.
  if ! sed 's/#.*//' lefthook.yml | grep -E '(^|[^.])lefthook-generated\.yml' >/dev/null 2>&1; then
    echo "lefthook: warning: lefthook.yml does not extend lefthook-generated.yml; generated hooks are inactive" >&2
  fi
else
  # A repository can ship its main config under any of the names lefthook reads.
  # `lefthook.yml` is FIRST in that search order, so seeding one here would make
  # theirs inert — silently, and after the scaffolder just showed it to them as
  # the file that would run. Leave it alone and say what to add instead.
  rival=""
  remaining_mains=$LEFTHOOK_MAIN_CONFIGS
  while [ "$remaining_mains" != "" ]; do
    case $remaining_mains in
      *' '*)
        candidate=${remaining_mains%% *}
        remaining_mains=${remaining_mains#* }
        ;;
      *)
        candidate=$remaining_mains
        remaining_mains=""
        ;;
    esac
    [ "$candidate" != "lefthook.yml" ] || continue
    if [ -e "$candidate" ] || [ -L "$candidate" ]; then
      rival=$candidate
      break
    fi
  done

  if [ "$rival" != "" ]; then
    echo "lefthook: warning: this repository already has $rival, which lefthook loads." >&2
    echo "lefthook: warning: not creating a lefthook.yml, which would shadow it. Add" >&2
    echo "lefthook: warning: 'lefthook-generated.yml' to that file's extends: list to activate" >&2
    echo "lefthook: warning: the generated hooks." >&2
  else
    if [ -L lefthook.yml ]; then
      echo "lefthook: warning: lefthook.yml was a dangling symlink; replacing it with a real config" >&2
      rm -f lefthook.yml
    fi
    printf 'extends:\n  - lefthook-generated.yml\n' >lefthook.yml
  fi
fi

if [ "$install_hooks" = false ]; then
  exit 0
fi

# core.hooksPath redirects git away from .git/hooks. Recent lefthook refuses to
# install rather than write somewhere git will not read (it prints its own hint),
# and older versions install into that directory instead — so do not predict
# which; say what is set and let the install result below speak. The genuine
# hazard is a *global* core.hooksPath, where installing writes this repository's
# shim into a directory every repository on the machine shares.
hooks_path=$(git config --get core.hooksPath || true)
if [ "$hooks_path" != "" ]; then
  echo "lefthook: warning: core.hooksPath is set to '$hooks_path'; lefthook will install there or" >&2
  echo "lefthook: warning: refuse outright, and a global setting is shared by every repository." >&2
fi

# lefthook reports its errors on stdout, so the usual >/dev/null would hide
# "install failed" entirely. Keep the output and show it only when it matters.
if ! install_log=$("$lefthook_bin" install 2>&1); then
  echo "lefthook: ERROR: 'lefthook install' failed; hooks are NOT installed" >&2
  printf '%s\n' "$install_log" >&2
  exit 1
elif printf '%s' "$install_log" | grep -i 'renamed' >/dev/null; then
  # An existing foreign hook was moved aside and disabled — say so. Matched
  # case-insensitively so a change in lefthook's wording is less likely to make
  # this notice disappear silently.
  printf '%s\n' "$install_log" >&2
fi
