#!/bin/sh
# Scaffold lefthook into the current git repository.
#
# Detects which language lanes the repository needs, renders the matching
# config, writes it plus a `lefthook.yml` that extends it, and installs the
# git hooks. Prepended at build time with SELF, NIXPKGS and SYSTEM store paths.
#
# Usage: lefthook-init [--lanes a,b] [--no-gitleaks] [--no-auto-commit] [--force]

lanes=""
gitleaks=true
auto_commit=true
force=false

while [ "$#" -gt 0 ]; do
  case $1 in
    --lanes)
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
    -h | --help)
      cat <<'USAGE'
Scaffold lefthook into the current git repository.

Detects the language lanes the repository needs, renders the matching config,
writes it plus a lefthook.yml that extends it, and installs the git hooks.

Usage: lefthook-init [--lanes a,b] [--no-gitleaks] [--no-auto-commit] [--force]

  --lanes a,b       skip detection and use these lanes
  --no-gitleaks     omit the repo-wide secret scan
  --no-auto-commit  omit the per-file commit splitter
  --force           overwrite an existing, differing lefthook-generated.yml
USAGE
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

# List candidate files: tracked ones when the repo has any, otherwise the
# working tree (a freshly `git init`ed repo has nothing tracked yet).
list_files() {
  if [ "$(git ls-files)" != "" ]; then
    git ls-files
  else
    find . -type d \( -name .git -o -name .direnv -o -name node_modules \) -prune -o -type f -print
  fi
}

if [ "$lanes" = "" ]; then
  files=$(list_files)
  detected=""
  # Each lane is claimed by the extensions its hooks glob for.
  for probe in \
    'go:\.go$' \
    'lua:\.lua$' \
    'nix:\.nix$' \
    'opentofu:\.(tf|tofu|tfvars)$' \
    'rust:\.rs$' \
    'shell:\.sh$' \
    'toml:\.toml$' \
    'yaml:\.(yml|yaml)$' \
    'zig:\.(zig|zon)$'; do
    lane=${probe%%:*}
    pattern=${probe#*:}
    if printf '%s\n' "$files" | grep -qE "$pattern"; then
      detected="$detected${detected:+,}$lane"
    fi
  done
  lanes=$detected
fi

if [ "$lanes" = "" ] && [ "$gitleaks" = false ]; then
  echo "lefthook-init: no lanes detected and gitleaks disabled — nothing to do" >&2
  exit 1
fi

# The lefthook that will actually run the hook: the user's, if they have one.
# Its version becomes the config's floor, and it installs the shim, so the
# config can never demand a newer lefthook than the one on this machine.
runner=$(command -v lefthook || echo "$LEFTHOOK_FALLBACK")
runner_version=$("$runner" version)

# Turn "nix,shell" into the Nix list literal '"nix" "shell"'.
lanes_nix=$(printf '%s' "$lanes" | tr ',' '\n' | sed 's/^/"/; s/$/"/' | tr '\n' ' ')

echo "lefthook-init: lanes: ${lanes:-(none)}  gitleaks: $gitleaks  auto-commit: $auto_commit"
echo "lefthook-init: runner: $runner ($runner_version)"

# Render through the same module the dev-shell path uses, so a repo scaffolded
# this way and one wired via `lib.mkShell` produce identical config.
# --impure only to allow importing this flake's own baked-in store paths; the
# expression reads nothing from the environment, so it stays deterministic.
rendered=$(nix build --impure --no-link --print-out-paths --expr "
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

if [ -e lefthook-generated.yml ] && [ "$force" = false ] && ! cmp -s "$rendered" lefthook-generated.yml; then
  echo "lefthook-init: lefthook-generated.yml already exists and differs; re-run with --force to replace it" >&2
  exit 1
fi
install -m 644 "$rendered" lefthook-generated.yml

if [ -f lefthook.yml ]; then
  if ! grep -Eq '(^|[^.])lefthook-generated\.yml' lefthook.yml; then
    echo "lefthook-init: warning: existing lefthook.yml does not extend lefthook-generated.yml; add it to its 'extends:' list" >&2
  fi
else
  printf 'extends:\n  - lefthook-generated.yml\n' >lefthook.yml
fi

"$runner" install >/dev/null
git add lefthook.yml lefthook-generated.yml

cat <<EOF
lefthook-init: done.
  wrote    lefthook-generated.yml, lefthook.yml (staged — commit them)
  hooks    installed into $(git rev-parse --git-path hooks)
  tools    the config calls them by bare name; they must be on PATH at commit
           time (a dev shell, or installed globally)
EOF
