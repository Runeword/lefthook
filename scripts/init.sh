#!/bin/sh
# Scaffold lefthook into the current git repository.
#
# Detects which language lanes the repository needs, renders the matching
# config, writes it plus a `lefthook.yml` that extends it, and installs the
# git hooks. Prepended at build time with SELF, NIXPKGS and SYSTEM store paths.
#
# Usage: lefthook-init [--lanes a,b] [--no-gitleaks] [--no-auto-commit]
#                      [--force] [--adopt-existing-config]

# The oldest lefthook this config supports. `jobs:` landed in 1.10.0, but the
# real floor is 1.13.0: below it the parallel lanes' post-format `git add` calls
# race `.git/index.lock`, `stage_fixed` fails with only a warning, and the
# commit lands the UN-formatted blobs (exit 0). An even older runner accepts the
# config, ignores every job and exits 0. Either way a too-old runner checks
# nothing silently, so the floor is enforced rather than merely stamped.
feature_floor=1.13.0

# lane:regex — the file extensions each lane's hooks glob for. Single source of
# truth for detection, for validating --lanes, and for --help.
lane_probes='go:\.go$ lua:\.lua$ nix:\.nix$ opentofu:\.(tf|tofu|tfvars)$'
lane_probes=$lane_probes' rust:\.rs$ shell:\.sh$ toml:\.toml$'
lane_probes=$lane_probes' yaml:\.(yml|yaml)$ zig:\.(zig|zon)$'
all_lanes=$(printf '%s\n' "$lane_probes" | tr ' ' '\n' | sed 's/:.*//' | tr '\n' ' ')
# The trailing space `tr` leaves would make `case " $all_lanes "` contain a
# double space, which an empty lane name then matches.
all_lanes=${all_lanes% }

lanes=""
gitleaks=true
auto_commit=true
force=false
adopt=false

while [ "$#" -gt 0 ]; do
  case $1 in
    --lanes)
      if [ "$#" -lt 2 ]; then
        echo "lefthook-init: --lanes requires a value (e.g. --lanes nix,shell)" >&2
        exit 2
      fi
      lanes=$2
      shift 2
      ;;
    --lanes=*)
      lanes=${1#--lanes=}
      shift
      ;;
    --no-gitleaks)
      gitleaks=false
      shift
      ;;
    --no-auto-commit)
      auto_commit=false
      shift
      ;;
    --force)
      force=true
      shift
      ;;
    --adopt-existing-config)
      adopt=true
      shift
      ;;
    -h | --help)
      cat <<'USAGE'
Scaffold lefthook into the current git repository.

Detects the language lanes the repository needs, renders the matching config,
writes it plus a lefthook.yml that extends it, and installs the git hooks.

Usage: lefthook-init [--lanes a,b] [--no-gitleaks] [--no-auto-commit]
                     [--force] [--adopt-existing-config]

  --lanes a,b               skip detection and use these lanes
  --no-gitleaks             omit the repo-wide secret scan
  --no-auto-commit          omit the per-file commit splitter
  --force                   overwrite an existing, differing lefthook-generated.yml
  --adopt-existing-config   install hooks even though this repository already
                            ships its own lefthook config (see the warning it
                            prints first — this activates that file's jobs)

gitleaks and auto-commit are ON by default. auto-commit splits each commit into
one commit per file and cancels the umbrella commit, so `git commit` reports
failure even when it succeeded; pass --no-auto-commit if that is not wanted.
USAGE
      printf '\nLanes: %s\n' "$all_lanes"
      exit 0
      ;;
    *)
      echo "lefthook-init: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "lefthook-init: not inside a git work tree" >&2
  exit 1
fi
root=$(git rev-parse --show-toplevel)
cd "$root" || exit 1

# Reject unknown lanes here rather than letting them surface as a Nix
# module-system stack trace from the render below.
remaining=$lanes
while [ "$remaining" != "" ]; do
  case $remaining in
    *,*)
      lane=${remaining%%,*}
      remaining=${remaining#*,}
      ;;
    *)
      lane=$remaining
      remaining=""
      ;;
  esac
  if [ "$lane" = "" ]; then
    echo "lefthook-init: --lanes has an empty entry (stray or doubled comma?)" >&2
    exit 2
  fi
  case " $all_lanes " in
    *" $lane "*) ;;
    *)
      echo "lefthook-init: unknown lane: $lane" >&2
      echo "lefthook-init: valid lanes: $all_lanes" >&2
      exit 2
      ;;
  esac
done

# Candidate files for detection: tracked plus untracked-but-not-ignored, so a
# repo whose sources are written but not yet added still gets its lanes. Our
# own output is filtered out — otherwise the second run detects the yaml lane
# from the files the first run wrote.
# core.quotePath=false: without it git C-quotes any non-ASCII path
# ("caf\303\251.nix"), so the extension patterns below never match and a repo
# whose only sources have accented names detects no lanes at all.
list_files() {
  {
    git -c core.quotePath=false ls-files
    git -c core.quotePath=false ls-files --others --exclude-standard
  } | grep -vE '^(.*/)?lefthook(-generated|-local)?\.yml$' || true
}

if [ "$lanes" = "" ]; then
  files=$(list_files)
  detected=""
  # Consumed field by field rather than with `for probe in $lane_probes`,
  # which relies on unquoted word splitting, or a heredoc: both get rewritten
  # by shellharden into something that no longer means this.
  remaining_probes=$lane_probes
  while [ "$remaining_probes" != "" ]; do
    case $remaining_probes in
      *' '*)
        probe=${remaining_probes%% *}
        remaining_probes=${remaining_probes#* }
        ;;
      *)
        probe=$remaining_probes
        remaining_probes=""
        ;;
    esac
    lane=${probe%%:*}
    pattern=${probe#*:}
    # Deliberately not `grep -q`: under the bash `pipefail` that
    # writeShellApplication injects, grep exiting early on its first match
    # makes printf die of SIGPIPE and the whole test read as false, so large
    # repositories silently detect nothing.
    if printf '%s\n' "$files" | grep -E "$pattern" >/dev/null; then
      detected="$detected${detected:+,}$lane"
    fi
  done
  lanes=$detected
fi

if [ "$lanes" = "" ] && [ "$gitleaks" = false ] && [ "$auto_commit" = false ]; then
  echo "lefthook-init: no lanes detected, gitleaks and auto-commit disabled — nothing to do" >&2
  exit 1
fi

# A config already in the tree belongs to the repository, not to us. Installing
# hooks would activate ITS jobs, `rc` file and `remotes` — something git
# deliberately does not do for a fresh clone, since .git/hooks is never cloned.
#
# lefthook does not read only lefthook.yml. It discovers config as STEM x
# EXTENSION for a main and a "-local" family (internal/config/load.go), and the
# local family is merged UNCONDITIONALLY — a root lefthook.yml shadows a rival
# MAIN config, but nothing shadows `.config/lefthook-local.yml`. So a clone
# carrying only a local config, and no lefthook.yml at all, still gets its jobs
# and `rc` run on the next hook. Gate activation on every one of those names.
# Writing files stays safe, so only the install step is gated.
#
# Enumerated from the two axes rather than listed by hand: the hand-written list
# this replaces silently omitted the whole `.config/` stem and the `.jsonc`
# extension, which reopened exactly the hole the gate exists to close.
own_config=$(printf 'extends:\n  - lefthook-generated.yml')
config_stems="lefthook .lefthook .config/lefthook"
config_exts="yml yaml json jsonc toml"
config_names=""
remaining_stems=$config_stems
while [ "$remaining_stems" != "" ]; do
  case $remaining_stems in
    *' '*)
      stem=${remaining_stems%% *}
      remaining_stems=${remaining_stems#* }
      ;;
    *)
      stem=$remaining_stems
      remaining_stems=""
      ;;
  esac
  remaining_exts=$config_exts
  while [ "$remaining_exts" != "" ]; do
    case $remaining_exts in
      *' '*)
        ext=${remaining_exts%% *}
        remaining_exts=${remaining_exts#* }
        ;;
      *)
        ext=$remaining_exts
        remaining_exts=""
        ;;
    esac
    config_names="$config_names $stem.$ext $stem-local.$ext"
  done
done
config_names=${config_names# }

# Consumed field by field (the shellharden-safe idiom the lane probes use), not
# `for c in $config_names`.
foreign_configs=""
remaining_names=$config_names
while [ "$remaining_names" != "" ]; do
  case $remaining_names in
    *' '*)
      cfg=${remaining_names%% *}
      remaining_names=${remaining_names#* }
      ;;
    *)
      cfg=$remaining_names
      remaining_names=""
      ;;
  esac
  [ -e "$cfg" ] || [ -L "$cfg" ] || continue
  # Our own root stub is not foreign.
  if [ "$cfg" = lefthook.yml ] &&
    [ "$(cat lefthook.yml 2>/dev/null || true)" = "$own_config" ]; then
    continue
  fi
  # A *-local config the developer wrote themselves is the documented per-user
  # override, kept untracked (wire-repo excludes it). Only a *-local file that
  # git TRACKS arrived with the repository — the clone-delivered code this gate
  # exists to stop — so leave an untracked one alone to keep re-runs quiet. Main
  # configs are always repo-owned: any that isn't our stub is foreign.
  # (A tree delivered as a tarball and `git init`ed has nothing tracked yet;
  # that case is outside what this proxy can see.)
  case $cfg in
    *-local.*)
      git ls-files --error-unmatch -- "$cfg" >/dev/null 2>&1 || continue
      ;;
  esac
  foreign_configs="$foreign_configs${foreign_configs:+ }$cfg"
done

# LEFTHOOK_CONFIG points lefthook at an arbitrary extra config we cannot vouch
# for; if it is set, gate on it too.
foreign_env_config=${LEFTHOOK_CONFIG:-}

adopted_foreign_config=false
if [ "$foreign_configs" != "" ] || [ "$foreign_env_config" != "" ]; then
  adopted_foreign_config=true
fi

runner=""
if runner=$(command -v lefthook 2>/dev/null) && [ "$runner" != "" ]; then
  :
else
  runner=$LEFTHOOK_FALLBACK
  echo "lefthook-init: warning: no lefthook on PATH; falling back to this flake's copy." >&2
  echo "lefthook-init: warning: the installed hook will point at a Nix store path that nothing" >&2
  echo "lefthook-init: warning: keeps alive. Install lefthook globally, or the hooks stop" >&2
  echo "lefthook-init: warning: working after the next garbage collection: every commit is then" >&2
  echo "lefthook-init: warning: blocked with \"Can't find lefthook in PATH\" until you install one." >&2
fi

# Some wrappers print "lefthook version 1.2.3" rather than a bare version, and
# the value is both compared numerically and spliced into a Nix expression.
# Captured in an `if` (not a bare `x=$(cmd | sed)`): under the errexit+pipefail
# writeShellApplication injects, a broken shim whose `version` exits non-zero
# would abort the whole script here — before the diagnostic below — and its
# output, sent to /dev/null, would never be seen.
if runner_out=$("$runner" version 2>&1); then
  runner_version=$(printf '%s\n' "$runner_out" | sed -n '1s/[^0-9]*\([0-9][0-9.]*\).*/\1/p')
else
  runner_ec=$?
  echo "lefthook-init: '$runner version' failed (exit $runner_ec):" >&2
  printf '%s\n' "$runner_out" | sed 's/^/  /' >&2
  exit 1
fi
case $runner_version in
  "" | *[!0-9.]*)
    echo "lefthook-init: could not read a version number from '$runner version':" >&2
    printf '%s\n' "$runner_out" | sed 's/^/  /' >&2
    exit 1
    ;;
esac

# True when dotted version $1 is at least $2; missing components read as zero.
version_ge() {
  _have=$1
  _want=$2
  while [ "$_have" != "" ] || [ "$_want" != "" ]; do
    _h=${_have%%.*}
    _w=${_want%%.*}
    [ "$_h" != "" ] || _h=0
    [ "$_w" != "" ] || _w=0
    if [ "$_h" -gt "$_w" ]; then return 0; fi
    if [ "$_h" -lt "$_w" ]; then return 1; fi
    case $_have in *.*) _have=${_have#*.} ;; *) _have="" ;; esac
    case $_want in *.*) _want=${_want#*.} ;; *) _want="" ;; esac
  done
  return 0
}

if ! version_ge "$runner_version" "$feature_floor"; then
  echo "lefthook-init: lefthook $runner_version is too old; this config needs >= $feature_floor." >&2
  echo "lefthook-init: below it a runner either ignores the jobs syntax and exits 0, or races" >&2
  echo "lefthook-init: .git/index.lock and silently drops formatter fixes. Upgrade, then re-run." >&2
  exit 1
fi

# Turn "nix,shell" into the Nix list literal '"nix" "shell"'.
lanes_nix=$(printf '%s' "$lanes" | tr ',' '\n' | sed 's/^/"/; s/$/"/' | tr '\n' ' ')

echo "lefthook-init: lanes: ${lanes:-(none)}  gitleaks: $gitleaks  auto-commit: $auto_commit"
echo "lefthook-init: runner: $runner ($runner_version)"

# Render through the same module the dev-shell path uses, so a repo scaffolded
# this way and one wired via `lib.mkShell` produce identical config.
# --impure only to allow importing this flake's own baked-in store paths; the
# expression reads nothing from the environment, so it stays deterministic.
# The experimental features are passed explicitly: whatever enabled them for
# the outer `nix run` does not carry into this child process.
rendered=$(nix build --impure --no-link --print-out-paths \
  --extra-experimental-features 'nix-command flakes' \
  --expr "
  let
    pkgs = import $NIXPKGS { system = \"$SYSTEM\"; config = { }; overlays = [ ]; };
    hooks = import $SELF/hooks.nix { inherit pkgs; };
    mk = import $SELF/mk-shell.nix { inherit pkgs; inherit (pkgs) lib; inherit hooks; };
  in
  (mk.mkShell {
    lanes = [ $lanes_nix ];
    gitleaks = $gitleaks;
    autoCommit = $auto_commit;
    minVersion = \"$runner_version\";
  }).lefthookConfig
") || {
  echo "lefthook-init: failed to render the config" >&2
  exit 1
}

if { [ -e lefthook-generated.yml ] || [ -L lefthook-generated.yml ]; } &&
  [ "$force" = false ] && ! cmp -s "$rendered" lefthook-generated.yml; then
  echo "lefthook-init: lefthook-generated.yml already exists and differs; re-run with --force to replace it" >&2
  exit 1
fi
# Decided before wire-repo runs, since it is what creates the file.
created_root_config=false
if ! { [ -e lefthook.yml ] || [ -L lefthook.yml ]; }; then
  created_root_config=true
fi

if [ "$adopted_foreign_config" = true ] && [ "$adopt" = false ]; then
  # Write the files — inert on their own — but stop short of activating hooks.
  wire-repo "$rendered" "$runner" --no-install
  echo "" >&2
  # Show each foreign config rather than grepping for known-dangerous keys.
  # Several keys execute code — run, files, script, runner, rc, remotes — and
  # the set moves between lefthook versions, so anything a pattern misses would
  # read as "clean" on the one screen the reader uses to make a security
  # decision. lefthook merges every one of these files, so show them all.
  remaining_foreign=$foreign_configs
  while [ "$remaining_foreign" != "" ]; do
    case $remaining_foreign in
      *' '*)
        cfg=${remaining_foreign%% *}
        remaining_foreign=${remaining_foreign#* }
        ;;
      *)
        cfg=$remaining_foreign
        remaining_foreign=""
        ;;
    esac
    if [ ! -r "$cfg" ]; then
      # A dangling symlink: nothing to show, and `<$cfg` would emit a raw shell
      # redirect error that no 2>/dev/null on the command can suppress.
      echo "lefthook-init: this repository has a $cfg that cannot be read (dangling symlink?)." >&2
      continue
    fi
    config_lines=$(wc -l <"$cfg" | tr -d ' ')
    if [ "$config_lines" -le 40 ]; then
      echo "lefthook-init: this repository ships its own $cfg:" >&2
      sed 's/^/  | /' "$cfg" >&2
    else
      # No danger-key grep here: quoting a key, or padding a space before its
      # colon, is ordinary YAML that lefthook still parses but a pattern would
      # miss — and an EMPTY result printed under a "dangerous keys" heading reads
      # as "clean", which is worse than saying nothing. Point at the file.
      echo "lefthook-init: this repository ships its own $cfg ($config_lines lines — too long to show here)." >&2
      echo "lefthook-init: open and read it before adopting; any run/script/runner/rc/extends/remotes key runs code." >&2
    fi
    # extends/remotes pull in FURTHER files (local, or fetched over the network)
    # whose payload is not on this screen — flag that for every shown config.
    if grep -qE '^[[:space:]]*(extends|remotes):' "$cfg" 2>/dev/null; then
      echo "lefthook-init: NOTE: $cfg has an 'extends' or 'remotes' key — it loads more files not shown above; review those too." >&2
    fi
  done
  if [ "$foreign_env_config" != "" ]; then
    echo "lefthook-init: LEFTHOOK_CONFIG is set to '$foreign_env_config'; lefthook would load that too." >&2
  fi
  echo "" >&2
  echo "lefthook-init: git does not activate a cloned repository's hooks by itself, and neither" >&2
  echo "lefthook-init: will this: installing them would run those files' jobs on your next commit." >&2
  echo "lefthook-init: lefthook-generated.yml was written, but NO hooks were installed." >&2
  echo "lefthook-init: Review the file(s) above, then re-run with --adopt-existing-config." >&2
  exit 1
fi

# Writes the config, seeds lefthook.yml, keeps lefthook-local.yml out of the
# index, warns on core.hooksPath, and installs the hooks. The shim's "can't find
# lefthook" branch exits 1 rather than 0 because the rendered config carries
# `assert_lefthook_installed` — honoured since lefthook 1.4.8, well below the
# floor enforced above, and read through `extends`.
# `git add` below fails on an ignored path, and errexit would abort AFTER the
# hooks were installed — leaving the repository hooked with a config git will
# never commit, and only git's generic advice to explain it.
if ignore_rule=$(git check-ignore -v -- lefthook-generated.yml 2>/dev/null); then
  echo "lefthook-init: lefthook-generated.yml is ignored by: $ignore_rule" >&2
  echo "lefthook-init: it has to be committed for the hooks to travel with the repository." >&2
  echo "lefthook-init: drop that ignore rule, then re-run. NO hooks were installed." >&2
  exit 1
fi

wire-repo "$rendered" "$runner"

git add -- lefthook-generated.yml
if [ "$created_root_config" = true ]; then
  git add -- lefthook.yml
  wrote="lefthook-generated.yml, lefthook.yml (staged — commit them)"
else
  wrote="lefthook-generated.yml (staged — commit it); kept your existing lefthook.yml"
fi

# With an existing lefthook.yml kept (the --adopt path), the generated hooks run
# only if that file extends lefthook-generated.yml. If it does not, gitleaks /
# formatters / auto-commit are all inactive — say so loudly rather than let the
# clean "done" below read as "everything is protected".
generated_active=true
if [ ! -r lefthook.yml ] ||
  ! grep -E '(^|[^.])lefthook-generated\.yml' lefthook.yml >/dev/null 2>&1; then
  generated_active=false
fi

cat <<EOF
lefthook-init: done.
  wrote    $wrote
  hooks    installed into $(git rev-parse --git-path hooks)
  tools    the config calls them by bare name; they must be on PATH at commit
           time (a dev shell, or installed globally)
EOF

if [ "$generated_active" = false ]; then
  echo "lefthook-init: WARNING: your lefthook.yml does not extend lefthook-generated.yml, so the" >&2
  echo "lefthook-init: generated hooks (gitleaks, formatters, auto-commit) are NOT active. Add:" >&2
  echo "lefthook-init:     extends:" >&2
  echo "lefthook-init:       - lefthook-generated.yml" >&2
  echo "lefthook-init: to your lefthook.yml, then re-run 'lefthook install'." >&2
fi
