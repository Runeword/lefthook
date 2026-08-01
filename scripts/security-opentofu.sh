#!/bin/sh
# `trivy config` takes exactly one target and rejects a second with a usage
# dump, so passing it the staged file list fails every commit that touches more
# than one .tf file. Scan the directories of the staged files instead — which is
# also what trivy needs to resolve variables and locals across a module.
#
# Two flags keep that from becoming a whole-repository scan. Terraform at the
# repository root gives `dirname` a plain ".", and trivy both recurses and scans
# every config language it knows, so a single staged .tf would otherwise fail
# the commit over a Dockerfile or a k8s manifest that was never touched:
#   --misconfig-scanners terraform   only terraform findings, not dockerfile/helm/k8s
#   --skip-dirs '*/*'                the module's own files, not everything below it
# `dirname` output is re-split on newlines below, so a directory whose name
# contains one would be scanned as two different paths — and if both happen to
# exist and be clean, the real directory is never scanned and the hook passes.
# Refuse rather than under-scan.
nl='
'
for f in "$@"; do
  case $f in
    *"$nl"*)
      echo "security-opentofu: newline in a staged path is unsupported; refusing to scan" >&2
      exit 1
      ;;
  esac
done

for f in "$@"; do
  dirname -- "$f"
done | sort -u | while IFS= read -r dir; do
  trivy config --quiet --exit-code 1 \
    --misconfig-scanners terraform --skip-dirs '*/*' -- "$dir" || exit 1
done
