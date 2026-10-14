#!/bin/sh
# golangci-lint analyzes packages, not files: lint the directories of the
# staged files, so pre-existing debt elsewhere in the repository cannot block
# a commit that never touched it. Lint them as staged, in the copy
# enter_staged_tree (scripts/staged-tree.sh) checks out, not as they sit in the
# working tree, where the package's other files may be mid-edit.
#
# Run golangci-lint from *inside* each directory rather than passing "./$dir"
# from the repo root: golangci-lint needs a module context (a go.mod at or above
# its working directory). A repo whose Go code lives in nested modules (e.g.
# packages/custom/<tool>/ each with its own go.mod) has no go.mod at the root,
# so "golangci-lint run ./packages/custom/tool" fails with "no go files to
# analyze". cd'ing in first lets it find the module that owns the staged file.
#
# --fix=false: with `issues.fix: true` in its config, golangci-lint would fix
# the copy, which is thrown away, and stop reporting what it fixed.
[ "$#" -gt 0 ] || exit 0
enter_staged_tree "$@"
for f in "$@"; do
  dirname -- "$f"
done | sort -u | while IFS= read -r dir; do
  (cd -- "$dir" && golangci-lint run --fix=false .) || exit 1
done
