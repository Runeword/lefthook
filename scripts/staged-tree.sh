#!/bin/sh
# enter_staged_tree FILE...
#
# Prepended by wrappers.nix to the hooks that check a whole package or module
# rather than the staged files alone (lint-go, lint-opentofu,
# security-opentofu). It checks the staged tree out into a private temporary
# directory and changes into it, so the check sees what the commit will record.
# Read from the working tree, the package's other files bring their unstaged
# edits and any untracked neighbour along: half-done work there would fail a
# commit that does not include it, and a commit that only works together with
# it would pass.
#
# The FILEs (the hook's staged files) are then copied in from the working
# tree: that copy holds the formatter's fix, which lefthook stages only after
# the hook, and lefthook has already set their unstaged hunks aside. The staged
# blob alone would fail on what the formatter just fixed (gofumpt's
# `for i, _ := range`, tofu fmt's `type = "string"`).
#
# Files git ignores (generated code, `//go:embed` targets, an untracked
# go.work, `.terraform/`) are not in the copy, so a check that needs them fails.
#
# The index is copied first because write-tree takes .git/index.lock, which
# anything may hold at that moment (see auto-commit.sh). write-tree leaves out
# intent-to-add entries, as the commit will; checking out from a fresh index
# read from that tree leaves no skip-worktree bit to hide a file; and the empty
# --attr-source keeps .gitattributes from running a smudge filter (an LFS
# download, git-crypt writing plaintext into the copy).
#
# The copy lives under $XDG_RUNTIME_DIR, private to the user, rather than /tmp
# or .git/: golangci-lint and go look for .golangci.* and go.work in every
# parent directory.

# Reached through the script wrappers.nix appends to this file.
# shellcheck disable=SC2329
enter_staged_tree() {
  # checkout-index --all takes only the entries under the current directory:
  # work from the top, and come back to the same place inside the copy.
  _st_prefix=$(git rev-parse --show-prefix)
  cd -- "./$(git rev-parse --show-cdup)" || exit

  _st_dir=$(mktemp -d "${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/lefthook-staged.XXXXXX")
  # A relative TMPDIR would resolve against the copy after the final cd.
  case $_st_dir in
    /*) ;;
    *) _st_dir=$PWD/$_st_dir ;;
  esac
  trap 'rm -rf -- "$_st_dir"' EXIT
  # bash skips the EXIT trap when a signal kills it; exiting from a trap runs it.
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  cp -- "$(git rev-parse --git-path index)" "$_st_dir/index"
  _st_tree=$(GIT_INDEX_FILE=$_st_dir/index git write-tree)
  rm -- "$_st_dir/index"
  GIT_INDEX_FILE=$_st_dir/index git read-tree "$_st_tree"
  GIT_INDEX_FILE=$_st_dir/index git --attr-source="$(git hash-object -t tree /dev/null)" \
    checkout-index --all --prefix="$_st_dir/tree/"

  for _st_f in "$@"; do
    _st_f=$_st_prefix$_st_f
    # Regular files on both sides only: an intent-to-add or unstaged path is not
    # in the copy, and cp would write through a symlink to wherever it points.
    if [ -f "$_st_f" ] && [ ! -L "$_st_f" ] &&
      [ -f "$_st_dir/tree/$_st_f" ] && [ ! -L "$_st_dir/tree/$_st_f" ]; then
      cp -- "$_st_f" "$_st_dir/tree/$_st_f"
    fi
  done

  # The check runs outside the repository: nothing in it may reach the real
  # index through a relative GIT_INDEX_FILE, or take the copy for a work tree.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
  cd -- "$_st_dir/tree/$_st_prefix" || exit
}
