#!/bin/sh
# enter_staged_tree FILE...
#
# Prepended by wrappers.nix to the hooks that check a whole package or module
# rather than the staged files alone (lint-go, lint-opentofu,
# security-opentofu). It builds a copy of the staged tree and changes into it,
# so the check sees what the commit will record. Read from the working tree,
# the package's other files bring their unstaged edits and any untracked
# neighbour along: half-done work there would fail a commit that does not
# include it, and a commit that only works together with it would pass.
#
# Where the copy lives. One directory per repository and hook, always the same
# one: ${XDG_CACHE_HOME:-$HOME/.cache}/lefthook/staged/<repo>/<hook>/, each level
# created 0700 and refused unless the user owns it and nobody else can write
# to it. Not a fresh random directory, and never /tmp:
#   - golangci-lint caches its findings by package content but records them
#     with absolute paths. From a new directory each run, a re-lint of the same
#     content (a retried commit) replayed findings that pointed into the
#     deleted copy, so //nolint and generated-file exclusions stopped applying
#     and the commit stayed blocked. The go build cache missed every time too.
#   - go and golangci-lint look for go.work and .golangci.* in every parent
#     directory, and /tmp is shared with every other user of the machine.
# <repo> is a hash of the repository's common git directory, so linked
# worktrees share it, and <hook> keeps the hooks of parallel lanes apart. A
# flock on <hook>/lock serializes two commits in the same repository. The copy
# (tree/) is rebuilt on every run and removed on exit; <hook>/cache/ keeps what
# a tool may reuse. lefthook SIGKILLs a job on ^C, so no trap runs then: the
# next run of the same hook reclaims the copy, and every run deletes the copies
# idle for an hour whose lock is free.
#
# What the copy holds, for each entry of the staged tree:
#   - a file whose working-tree copy matches the index: the working-tree file,
#     i.e. in the form git checked it out (decrypted by git-crypt, smudged by
#     LFS, with the configured line endings), which is what the tools read in
#     the working tree;
#   - a file whose working-tree copy differs, is missing, or that git is told
#     not to look at (skip-worktree, assume-unchanged, core.ignoreStat): the
#     staged blob, checked out with the attributes of the staged tree;
#   - the hook's own FILEs: the working-tree file whenever it is a regular file
#     on both sides. It holds the formatter's fix, which lefthook stages only
#     after the hook, and lefthook has already set their unstaged hunks aside.
#     It does so for a plain `git commit`, but not under --no-stage-fixed or
#     --all-files, and lefthook before 2.0 carries on when hiding them fails;
#   - a submodule: its files at the recorded commit, read from its own object
#     store, or an empty directory when it is not initialized or lacks that
#     commit.
# Intent-to-add entries are left out, as the commit will leave them out.
# Untracked and ignored files are not in the copy; the scripts appended to
# this one carry over the ignored inputs their tool is known to need.
#
# The index is copied before write-tree, which takes .git/index.lock, and
# anything may hold that lock at that moment (see auto-commit.sh). Nothing here
# writes the real index: the working-tree comparison runs with optional locks
# off.

# Reached through the script wrappers.nix appends to this file.
# shellcheck disable=SC2329
enter_staged_tree() {
  _st_tab=$(printf '\t')
  # Git exports these to hooks, sometimes relative ("." for --work-tree=.):
  # pin them to the directory they were set from, before anything below
  # changes directory.
  _st_val=""
  for _st_var in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE; do
    eval "_st_val=\${$_st_var:-}"
    case $_st_val in
      '' | /*) ;;
      *) eval "$_st_var=\$PWD/\$_st_val && export $_st_var" ;;
    esac
  done

  _st_hook=$(printf '%s' "${0##*/}" | tr -c 'A-Za-z0-9._-' '_')
  _st_prefix=$(git rev-parse --show-prefix)
  _st_top=$(git rev-parse --show-toplevel)
  _st_git_dir=$(git rev-parse --absolute-git-dir)
  _st_common=$(git rev-parse --path-format=absolute --git-common-dir)
  _st_real_index=$(git rev-parse --path-format=absolute --git-path index)
  cd -- "$_st_top" || exit

  case ${XDG_CACHE_HOME:-} in
    /*) _st_base=$XDG_CACHE_HOME/lefthook ;;
    *) _st_base=${HOME:?is unset, so the staged-tree copy has nowhere to go}/.cache/lefthook ;;
  esac
  _st_repo=$(printf '%s' "$_st_common" | git hash-object --stdin | cut -c1-16)
  _st_dir=$_st_base/staged/$_st_repo/$_st_hook
  mkdir -p -- "${_st_base%/*}"
  for _st_d in "$_st_base" "$_st_base/staged" "$_st_base/staged/$_st_repo" "$_st_dir"; do
    mkdir -m 700 -- "$_st_d" 2>/dev/null || [ -d "$_st_d" ] || exit
    if [ -L "$_st_d" ] ||
      [ -z "$(find "$_st_d" -maxdepth 0 -user "$(id -u)" ! -perm /022)" ]; then
      echo "$_st_hook: $_st_d is not a directory only $(id -un) can write to; refusing to use it" >&2
      exit 1
    fi
  done

  exec 9>"$_st_dir/lock"
  if ! flock -w 300 9; then
    echo "$_st_hook: another $_st_hook run in this repository still holds $_st_dir/lock after 300 s" >&2
    exit 1
  fi
  # A copy left by a run lefthook killed: ours to reclaim, now that we hold the lock.
  rm -rf -- "$_st_dir/tree" "$_st_dir/index" "$_st_dir/scratch"
  trap 'rm -rf -- "$_st_dir/tree" "$_st_dir/index" "$_st_dir/scratch"' EXIT
  # bash skips the EXIT trap when a signal kills it; exiting from a trap runs it.
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP
  find "$_st_base/staged" -mindepth 3 -maxdepth 3 -name tree -type d -mmin +60 2>/dev/null |
    while IFS= read -r _st_old; do
      _st_owner=${_st_old%/tree}
      [ "$_st_owner" != "$_st_dir" ] || continue
      flock -n "$_st_owner/lock" rm -rf -- "$_st_old" "$_st_owner/index" "$_st_owner/scratch" 2>/dev/null || true
    done || true

  mkdir -m 700 -- "$_st_dir/tree" "$_st_dir/scratch"
  [ -d "$_st_dir/cache" ] || mkdir -m 700 -- "$_st_dir/cache"
  _st_work=$_st_dir/scratch

  if [ -f "$_st_real_index" ]; then
    cp -- "$_st_real_index" "$_st_work/index"
    _st_tree=$(GIT_INDEX_FILE=$_st_work/index git write-tree)
    rm -f -- "$_st_work/index"
  else
    _st_tree=$(git hash-object -t tree /dev/null)
  fi
  # A fresh index read from that tree: no skip-worktree bit or stale stat data.
  GIT_INDEX_FILE=$_st_dir/index git read-tree "$_st_tree"

  # The staged entries the working tree cannot be trusted for: changed or
  # missing there, or flagged so that git does not look at them. Under
  # core.ignoreStat git looks at none of them.
  : >"$_st_work/dirty"
  if [ "$(git config --type=bool --get core.ignoreStat || true)" = true ]; then
    _st_trust=none
  else
    _st_trust=clean
    GIT_OPTIONAL_LOCKS=0 git diff --name-only -z --no-renames >"$_st_work/dirty"
    git ls-files -z -v | LC_ALL=C awk 'BEGIN { RS = "\0" }
      substr($0, 1, 1) ~ /[a-zS]/ { printf "%s%c", substr($0, 3), 0 }' >>"$_st_work/dirty"
  fi
  : >"$_st_work/hookfiles"
  for _st_f in "$@"; do
    _st_f=$_st_prefix$_st_f
    # Regular files only: cp would write through a symlink, and an
    # intent-to-add or unstaged path has no entry in the copy to replace.
    if [ -f "$_st_f" ] && [ ! -L "$_st_f" ]; then
      printf '%s\0' "$_st_f" >>"$_st_work/hookfiles"
    fi
  done
  GIT_INDEX_FILE=$_st_dir/index git ls-files -s -z >"$_st_work/entries"
  : >"$_st_work/from-worktree"
  : >"$_st_work/from-index"
  : >"$_st_work/gitlinks"
  st_work=$_st_work st_trust=$_st_trust LC_ALL=C awk '
    BEGIN { RS = "\0"; work = ENVIRON["st_work"]; trust = ENVIRON["st_trust"] }
    FILENAME == ARGV[1] { dirty[$0] = 1; next }
    FILENAME == ARGV[2] { hook[$0] = 1; next }
    {
      t = index($0, "\t"); path = substr($0, t + 1); split(substr($0, 1, t - 1), m, " ")
      if (m[1] == "160000") {
        if (path !~ /[\t\n]/) printf "%s\t%s\n", m[2], path > (work "/gitlinks")
        next
      }
      regular = (m[1] == "100644" || m[1] == "100755")
      if ((path in hook && regular) || (trust == "clean" && !(path in dirty)))
        printf "%s%c", path, 0 > (work "/from-worktree")
      else
        printf "%s%c", path, 0 > (work "/from-index")
    }' "$_st_work/dirty" "$_st_work/hookfiles" "$_st_work/entries"

  # One checkout-index and a few cp batches, not one process per file.
  if [ -s "$_st_work/from-index" ]; then
    GIT_INDEX_FILE=$_st_dir/index git --attr-source="$_st_tree" \
      checkout-index -z --stdin --prefix="$_st_dir/tree/" <"$_st_work/from-index"
  fi
  if [ -s "$_st_work/from-worktree" ]; then
    xargs -0 cp --parents --no-dereference --preserve=mode -t "$_st_dir/tree" -- <"$_st_work/from-worktree"
  fi
  if [ -s "$_st_work/gitlinks" ]; then
    _st_fill_submodules "$_st_work/gitlinks" "$_st_top" "$_st_dir/tree"
  fi

  # For the script that follows. It runs outside the repository: nothing in it
  # may reach the real index through an inherited GIT_INDEX_FILE, or take the
  # copy for a work tree; it gets the paths it needs instead.
  # shellcheck disable=SC2034
  {
    staged_worktree=$_st_top
    staged_prefix=$_st_prefix
    staged_copy=$_st_dir/tree
    staged_index=$_st_dir/index
    staged_git_dir=$_st_git_dir
    staged_cache=$_st_dir/cache
    staged_scratch=$_st_work
  }
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  mkdir -p -- "$_st_dir/tree/$_st_prefix"
  cd -- "$_st_dir/tree/$_st_prefix" || exit
}

# _st_fill_submodules LIST WORKTREE COPY: LIST holds "commit<TAB>path" lines,
# paths relative to WORKTREE and COPY. A queue file rather than recursion, so
# nested submodules line up without clobbering the loop's variables.
# shellcheck disable=SC2329
_st_fill_submodules() {
  st_wt=$2 st_cp=$3 awk '{ print $0 "\t" ENVIRON["st_wt"] "\t" ENVIRON["st_cp"] }' "$1" >"$_st_work/subqueue"
  while [ -s "$_st_work/subqueue" ]; do
    mv -- "$_st_work/subqueue" "$_st_work/subbatch"
    : >"$_st_work/subqueue"
    while IFS="$_st_tab" read -r _st_oid _st_path _st_wt _st_cp; do
      mkdir -p -- "$_st_cp/$_st_path"
      (
        # The superproject's overrides would point git back at the superproject.
        unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
        cd -- "$_st_wt/$_st_path" 2>/dev/null || exit 0
        if [ ! -e .git ]; then
          exit 0 # not initialized: empty here, as in the working tree
        fi
        if ! git cat-file -e "$_st_oid^{commit}" 2>/dev/null; then
          echo "$_st_hook: submodule $_st_path does not have commit $_st_oid; its files are missing from the copy" >&2
          exit 0
        fi
        rm -f -- "$_st_work/subindex"
        GIT_INDEX_FILE=$_st_work/subindex git read-tree "$_st_oid"
        GIT_INDEX_FILE=$_st_work/subindex git --attr-source="$_st_oid" \
          checkout-index -a --prefix="$_st_cp/$_st_path/"
        GIT_INDEX_FILE=$_st_work/subindex git ls-files -s -z |
          st_wt=$_st_wt/$_st_path st_cp=$_st_cp/$_st_path LC_ALL=C awk '
            BEGIN { RS = "\0" }
            {
              t = index($0, "\t"); path = substr($0, t + 1); split(substr($0, 1, t - 1), m, " ")
              if (m[1] == "160000" && path !~ /[\t\n]/)
                print m[2] "\t" path "\t" ENVIRON["st_wt"] "\t" ENVIRON["st_cp"]
            }' >>"$_st_work/subqueue"
      )
    done <"$_st_work/subbatch"
  done
}

# staged_carry DIR PATH: copy DIR/PATH (DIR relative to the current directory
# in the copy) in from the working tree when the copy lacks it. For what git
# ignores but a tool finds by location, such as the modules `tofu init`
# downloads into .terraform/modules. A copy, not a link: trivy does not follow
# a symlinked directory.
# shellcheck disable=SC2329
staged_carry() {
  _st_from=$staged_worktree/$staged_prefix$1/$2
  if [ -e "$_st_from" ] && [ ! -e "$1/$2" ]; then
    mkdir -p -- "$(dirname -- "$1/$2")"
    cp -R --no-dereference --preserve=mode -- "$_st_from" "$1/$2"
  fi
}
