#!/bin/sh
# Split the staged index into one commit per file with a generated message,
# then abort the umbrella commit.
#
# Each file is committed from its STAGED blob (not the working tree), so
# partial staging ("git add -p") is preserved: unstaged hunks stay uncommitted.
# Formatters re-stage their fixes via lefthook's "stage_fixed" before this runs,
# so the index already holds the final content.
#
# Runs as lefthook's "finalize" job. On success it exits 1 to cancel the
# original "git commit" (whose files are now committed individually) — so
# "git commit" always reports failure even though every commit went through.

# Prevent recursion: the per-file "git commit" calls below re-enter the hook.
if [ "${AUTO_COMMIT:-}" = "1" ]; then
  exit 0
fi

# A merge, cherry-pick, revert, or rebase in progress must conclude as the
# single commit git expects: the first per-file commit below would consume its
# state (e.g. MERGE_HEAD) and record a history that never happened.
git_dir=$(git rev-parse --git-dir)
for state in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
  if [ -e "$git_dir/$state" ]; then
    exit 0
  fi
done

# "git commit -a" and pathspec commits run the hook against a temporary index
# (a *.lock path) that git discards when the umbrella commit aborts; splitting
# from it leaves the real index stale, and the next commit would silently
# revert the split commits.
case ${GIT_INDEX_FILE:-} in
  *.lock) exit 0 ;;
esac

# Nothing staged: let the normal commit path handle it.
if git diff --cached --quiet; then
  exit 0
fi

# Base to diff the snapshot against: HEAD, or the empty tree on the first commit.
if git rev-parse --verify --quiet HEAD >/dev/null; then
  base=HEAD
else
  base=$(git hash-object -t tree /dev/null)
fi

# Snapshot the current index; we rebuild it one path at a time from this tree.
staged_tree=$(git write-tree)

# If anything below fails, restore the original staging so nothing is lost.
trap 'git read-tree "$staged_tree" 2>/dev/null || true' EXIT

# Reset the index to base without touching the working tree.
git read-tree "$base"

# Stage a single path's blob (mode + object id) from the snapshot tree.
stage_one() {
  _mode=$(git ls-tree "$staged_tree" -- "$1")
  _mode=${_mode%% *}
  _oid=$(git rev-parse "$staged_tree:$1")
  git update-index --add --cacheinfo "$_mode" "$_oid" "$1"
}

# Walk the snapshot's changes vs base. --no-renames keeps every entry to a
# single-letter status plus one path; core.quotePath=false keeps UTF-8 and
# spaces literal. Filenames containing tabs or newlines are not supported.
git -c core.quotePath=false diff-tree -r --no-renames --name-status "$base" "$staged_tree" |
  while IFS=$(printf '\t') read -r status path; do
    case $status in
      A) message="Add $path" && stage_one "$path" ;;
      D) message="Delete $path" && git update-index --force-remove -- "$path" ;;
      *) message="Update $path" && stage_one "$path" ;;
    esac

    printf '  → %s\n' "$message"
    AUTO_COMMIT=1 LEFTHOOK=0 git commit --quiet --no-verify -m "$message"
  done

# Cancel the original commit: every change is already committed individually.
exit 1
