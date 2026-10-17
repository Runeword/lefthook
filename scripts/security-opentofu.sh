#!/bin/sh
# shellcheck disable=SC2154 # staged_* are set by enter_staged_tree (scripts/staged-tree.sh)
# `trivy config` takes exactly one target and rejects a second with a usage
# dump, so passing it the staged file list fails every commit that touches more
# than one .tf file. Scan the directories of the staged files instead — which is
# also what trivy needs to resolve variables and locals across a module.
#
# trivy recurses into its target and evaluates every root module it finds
# there. A directory's subdirectories hold two kinds of module:
#   - those it calls through a local `source` path. They stay in the scan, so
#     a risky value the directory passes into a module is still evaluated;
#   - other root modules, untouched by the commit. Their files are skipped one
#     directory at a time (--skip-files <subdir>/*.tf), or a staged .tf at the
#     repository root would fail the commit over every one of them.
# (`--skip-dirs '*/*'` used to skip every subdirectory, called modules
# included: those calls failed to load, the log saying so was silenced, and
# nothing passed into a module was ever checked.) --misconfig-scanners
# terraform keeps it to terraform findings, not dockerfile/helm/k8s.
#
# A module call trivy cannot load fails the commit, with trivy's message: its
# resources would otherwise go unchecked while the hook passed. The modules
# `tofu init` downloaded (.terraform/modules, which git ignores) are copied in
# from the working tree; without them trivy fetches each one on every commit.
# --skip-version-check and --disable-telemetry keep it from phoning home on
# every run.
#
# `dirname` output is re-split on newlines below, so a directory whose name
# contains one would be scanned as two different paths — and if both happen to
# exist and be clean, the real directory is never scanned and the hook passes.
# Refuse rather than under-scan.
#
# The directories are scanned as staged, in the copy enter_staged_tree
# (scripts/staged-tree.sh) builds, not as they sit in the working tree.
[ "$#" -gt 0 ] || exit 0
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

enter_staged_tree "$@"
log=$staged_scratch/trivy.log

# so_sources DIR: the local module sources DIR's .tf files call.
so_sources() {
  for so_tf in "$1"/*.tf "$1"/*.tofu; do
    [ -f "$so_tf" ] || continue
    sed -n 's/^[[:space:]]*source[[:space:]]*=[[:space:]]*"\(\.\.\{0,1\}\/[^"]*\)".*$/\1/p' "$so_tf"
  done
}

for f in "$@"; do
  dirname -- "$f"
done | sort -u | while IFS= read -r dir; do
  staged_carry "$dir" .terraform/modules

  # The directories DIR reaches through local module calls, transitively.
  (cd -- "$dir" && pwd -P) >"$staged_scratch/called"
  cp -- "$staged_scratch/called" "$staged_scratch/queue"
  while [ -s "$staged_scratch/queue" ]; do
    mv -- "$staged_scratch/queue" "$staged_scratch/batch"
    : >"$staged_scratch/queue"
    while IFS= read -r so_d; do
      so_sources "$so_d" | while IFS= read -r so_src; do
        so_t=$(cd -- "$so_d" 2>/dev/null && cd -P -- "$so_src" 2>/dev/null && pwd -P) || continue
        if ! grep -Fx -e "$so_t" "$staged_scratch/called" >/dev/null; then
          printf '%s\n' "$so_t" | tee -a "$staged_scratch/called" >>"$staged_scratch/queue"
        fi
      done
    done <"$staged_scratch/batch"
  done

  # Every other directory below DIR that holds .tf files is a root module of
  # its own: skip its files (not its subdirectories, which may hold modules
  # DIR calls).
  set --
  (cd -- "$dir" && find . -name .terraform -prune -o \( -name '*.tf' -o -name '*.tofu' -o -name '*.tf.json' \) -print) |
    sed 's|/[^/]*$||' | sort -u >"$staged_scratch/tfdirs"
  while IFS= read -r so_d; do
    [ "$so_d" != . ] || continue
    so_abs=$(cd -- "$dir/$so_d" && pwd -P)
    if ! grep -Fx -e "$so_abs" "$staged_scratch/called" >/dev/null; then
      so_d=${so_d#./}
      set -- "$@" --skip-files "$so_d/*.tf" --skip-files "$so_d/*.tofu" --skip-files "$so_d/*.tf.json"
    fi
  done <"$staged_scratch/tfdirs"

  so_rc=0
  trivy config --exit-code 1 --skip-version-check --disable-telemetry \
    --misconfig-scanners terraform "$@" -- "$dir" 2>"$log" || so_rc=$?
  if grep -F -e 'Failed to load module' "$log" >/dev/null; then
    echo "security-opentofu: $dir calls a module trivy could not load, so its resources were not scanned:" >&2
    grep -F -e 'Failed to load module' "$log" >&2
    echo "security-opentofu: run 'tofu init' there (or fix the module source), then commit again" >&2
    exit 1
  fi
  if [ "$so_rc" != 0 ]; then
    grep -E -e 'ERROR|FATAL' "$log" >&2 || true
    exit 1
  fi
done
