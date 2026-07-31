#!/bin/sh
# `trivy config` takes exactly one target and rejects a second with a usage
# dump, so passing it the staged file list fails every commit that touches more
# than one .tf file. Scan the directories of the staged files instead — which is
# also what trivy needs to resolve variables and locals across a module.
for f in "$@"; do
  dirname -- "$f"
done | sort -u | while IFS= read -r dir; do
  trivy config --quiet --exit-code 1 -- "$dir" || exit 1
done
