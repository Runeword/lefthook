#!/bin/sh
# tflint analyzes module directories: lint the directories of the staged files
# instead of the whole repository, so pre-existing debt elsewhere cannot block
# a commit that never touched it.
if [ -f .tflint.hcl ]; then
  tflint --init || exit "$?"
fi
for f in "$@"; do
  dirname -- "$f"
done | sort -u | while IFS= read -r dir; do
  # --chdir=<dir> rather than --chdir <dir>: a directory whose name starts with
  # a dash would otherwise be read as another flag.
  tflint --chdir="$dir" || exit 1
done
