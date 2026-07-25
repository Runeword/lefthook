#!/bin/sh
# golangci-lint analyzes packages, not files: lint the directories of the
# staged files, so pre-existing debt elsewhere in the repository cannot block
# a commit that never touched it.
for f in "$@"; do
  dirname "$f"
done | sort -u | while IFS= read -r dir; do
  golangci-lint run "./$dir" || exit 1
done
