#!/bin/sh
# shellcheck disable=SC2154 # staged_* are set by enter_staged_tree (scripts/staged-tree.sh)
# tflint analyzes module directories: lint the directories of the staged files
# instead of the whole repository, so pre-existing debt elsewhere cannot block
# a commit that never touched it. Lint them as staged, in the copy
# enter_staged_tree (scripts/staged-tree.sh) builds, which also makes the
# .tflint.hcl files the staged ones.
#
# Two things tflint finds by location come from the working tree, because git
# ignores them and the copy cannot hold them:
#   - .terraform/modules, the modules `tofu init` downloaded: with
#     call_module_type = "all", tflint needs them to evaluate module calls;
#   - the plugin directory. tflint resolves a relative `plugin_dir` from its
#     working directory, i.e. inside the copy, where `tflint --init` would
#     download every plugin again on each commit, or fail offline. Such a path
#     is rewritten to the same place in the working tree, and a
#     ./.tflint.d/plugins found there becomes TFLINT_PLUGIN_DIR unless that is
#     already set. tflint ranks a config's plugin_dir above TFLINT_PLUGIN_DIR,
#     and TFLINT_PLUGIN_DIR above ./.tflint.d/plugins.
[ "$#" -gt 0 ] || exit 0
enter_staged_tree "$@"

# lo_plugin_dir DIR: point a relative plugin_dir in the copy's DIR/.tflint.hcl
# at the working tree's DIR, where tflint run from DIR would have put it. The
# file goes to awk on stdin: an operand like env=prod/.tflint.hcl is a variable
# assignment to awk, which then read the loop's list of directories instead,
# leaving that config empty (its rules off) or holding the next directory's
# name, a directory then never linted.
lo_plugin_dir() {
  [ -f "$1/.tflint.hcl" ] || return 0
  lo_wt=$(cd -- "$staged_worktree/$staged_prefix$1" 2>/dev/null && pwd) || return 0
  lo_wt=$lo_wt awk '
    match($0, /^[ \t]*plugin_dir[ \t]*=[ \t]*"/) {
      rest = substr($0, RLENGTH + 1)
      if (rest !~ /^[\/~"]/) $0 = substr($0, 1, RLENGTH) ENVIRON["lo_wt"] "/" rest
    }
    { print }' <"$1/.tflint.hcl" >"$staged_scratch/tflint.hcl"
  mv -- "$staged_scratch/tflint.hcl" "$1/.tflint.hcl"
}

if [ -z "${TFLINT_PLUGIN_DIR:-}" ] && [ -d "$staged_worktree/$staged_prefix.tflint.d/plugins" ]; then
  TFLINT_PLUGIN_DIR=$staged_worktree/$staged_prefix.tflint.d/plugins
  export TFLINT_PLUGIN_DIR
fi
lo_plugin_dir .
if [ -f .tflint.hcl ]; then
  tflint --init || exit "$?"
fi
for f in "$@"; do
  dirname -- "$f"
done | sort -u | while IFS= read -r dir; do
  staged_carry "$dir" .terraform/modules
  lo_plugin_dir "$dir"
  # --chdir=<dir> rather than --chdir <dir>: a directory whose name starts with
  # a dash would otherwise be read as another flag.
  tflint --chdir="$dir" || exit 1
done
