#!/bin/sh
# golangci-lint analyzes packages, not files: lint the directories of the
# staged files, so pre-existing debt elsewhere in the repository cannot block
# a commit that never touched it.
#
# Run golangci-lint from *inside* each directory rather than passing "./$dir"
# from the repo root: golangci-lint needs a module context (a go.mod at or above
# its working directory). A repo whose Go code lives in nested modules (e.g.
# packages/custom/<tool>/ each with its own go.mod) has no go.mod at the root,
# so "golangci-lint run ./packages/custom/tool" fails with "no go files to
# analyze". cd'ing in first lets it find the module that owns the staged file.
for f in "$@"; do
  dirname -- "$f"
done | sort -u | while IFS= read -r dir; do
  (cd -- "$dir" && golangci-lint run .) || exit 1
done
