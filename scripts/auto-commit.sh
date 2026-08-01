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
# Namespaced because a bare AUTO_COMMIT in the environment would silently
# disable splitting.
if [ "${LEFTHOOK_AUTO_COMMIT_SPLITTING:-}" = "1" ]; then
  exit 0
fi

# A merge, squash-merge, cherry-pick, revert, or rebase in progress must
# conclude as the single commit git expects: the first per-file commit below
# would consume its state (e.g. MERGE_HEAD) and record a history that never
# happened. SQUASH_MSG covers "git merge --squash", which sets no MERGE_HEAD
# and whose whole purpose is to land as one commit.
git_dir=$(git rev-parse --git-dir)
for state in MERGE_HEAD SQUASH_MSG CHERRY_PICK_HEAD REVERT_HEAD rebase-merge rebase-apply; do
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

# Walk the snapshot's changes vs base. --no-renames keeps every entry to a
# single-letter status plus one path; core.quotePath=false keeps UTF-8 and
# spaces literal. Collected before the index is touched so an unsupported path
# can bail out while there is still nothing to undo.
changes=$(git -c core.quotePath=false diff-tree -r --no-renames --name-status "$base" "$staged_tree")

# Guard the loop below: printing an empty list still yields one blank line,
# which would read back as an empty path.
if [ "$changes" = "" ]; then
  exit 0
fi

# A path holding a tab, newline, double quote or backslash still comes back
# C-quoted, and feeding that back to git fails partway through — committing the
# paths that sort before it and wedging every retry. Hand the whole commit to
# git untouched instead.
tab=$(printf '\t')
case $changes in
  *"$tab"'"'*)
    echo "auto-commit: tab, newline, quote or backslash in a staged filename is unsupported; committing as one commit" >&2
    exit 0
    ;;
esac

# Restoring the index costs its stat cache and, in a sparse checkout, its
# skip-worktree bits — which would make every excluded path read as deleted to
# the next "git add -A". Put both back whichever way we leave. --bool so git's
# other truthy spellings (1, yes, on) are read as sparse too.
sparse=$(git config --bool --get core.sparseCheckout 2>/dev/null || echo false)

# read-tree below also drops manually-set skip-worktree and assume-unchanged
# bits. A sparse checkout gets skip-worktree back via "sparse-checkout reapply";
# a plain "git update-index --skip-worktree" / "--assume-unchanged" (the "hide
# my local edit" workflow) has no such machinery, so snapshot those paths now
# and replay them in cleanup — otherwise the hidden file reappears tracked and
# the next "git add -A" stages the private change. Skipped under sparse, where
# the S list is every excluded path and reapply already covers it.
flags=$(git -c core.quotePath=false ls-files -v)
# In a sparse checkout the skip-worktree set is every excluded path, and
# "sparse-checkout reapply" in cleanup restores it — so only snapshot it when
# there is no sparse machinery to do the job.
skip_worktree_paths=""
if [ "$sparse" != true ]; then
  skip_worktree_paths=$(printf '%s\n' "$flags" | sed -n 's/^[Ss] //p')
fi
# assume-unchanged has no such machinery: "reapply" does not restore it, so it
# must be snapshotted in sparse checkouts as well or the "hide my local edit"
# workflow breaks there exactly as it did everywhere else.
assume_unchanged_paths=$(printf '%s\n' "$flags" | sed -n 's/^[a-z] //p')

split_ok=0
# Reached only through the EXIT trap installed below.
# shellcheck disable=SC2329
cleanup() {
  if [ "$split_ok" -eq 0 ]; then
    # The split failed partway: put the original staging back so nothing is lost.
    git read-tree "$staged_tree" 2>/dev/null || true
  fi
  if [ "$sparse" = true ]; then
    git sparse-checkout reapply >/dev/null 2>&1 || true
  fi
  # Replay the manual index bits read-tree dropped (see the snapshot above).
  if [ "$skip_worktree_paths" != "" ]; then
    printf '%s\n' "$skip_worktree_paths" | while IFS= read -r p; do
      [ "$p" = "" ] || git update-index --skip-worktree -- "$p" 2>/dev/null || true
    done
  fi
  if [ "$assume_unchanged_paths" != "" ]; then
    printf '%s\n' "$assume_unchanged_paths" | while IFS= read -r p; do
      [ "$p" = "" ] || git update-index --assume-unchanged -- "$p" 2>/dev/null || true
    done
  fi
  git update-index -q --refresh >/dev/null 2>&1 || true
}
trap cleanup EXIT
# bash does NOT run the EXIT trap when it dies from a SIGINT delivered to the
# foreground process group (^C at the terminal), which would leave the index
# rebuilt and the manual bits above stripped. Restore explicitly, then disarm
# EXIT so cleanup does not run twice.
trap 'cleanup; trap - EXIT; exit 130' INT
trap 'cleanup; trap - EXIT; exit 143' TERM
trap 'cleanup; trap - EXIT; exit 129' HUP

# Reset the index to base without touching the working tree.
git read-tree "$base"

# Staging the file `a` fails while `a/b` is still in the index: git refuses with
# "'a' appears as both a file and a directory", and under set -e that aborts the
# split and wedges every retry. diff-tree emits `A a` before `D a/b`, so those
# deletions have to be committed first.
#
# ONLY those. Moving every deletion ahead of every addition would split a rename
# (`D old` + `A new`) so that the intermediate commit holds neither path, and a
# bisect landing there sees the file simply missing. Everything else keeps
# diff-tree's order, which emits the addition first.
nl='
'
added_paths=$(printf '%s\n' "$changes" | sed -n "s/^A$tab//p")

# True when one of the added paths is a parent directory of $1.
under_added_path() {
  _p=$1
  while :; do
    _parent=${_p%/*}
    [ "$_parent" != "$_p" ] || return 1
    case "$nl$added_paths$nl" in
      *"$nl$_parent$nl"*) return 0 ;;
    esac
    _p=$_parent
  done
}

conflicting=""
ordered=""
remaining_changes=$changes
while [ "$remaining_changes" != "" ]; do
  case $remaining_changes in
    *"$nl"*)
      line=${remaining_changes%%"$nl"*}
      remaining_changes=${remaining_changes#*"$nl"}
      ;;
    *)
      line=$remaining_changes
      remaining_changes=""
      ;;
  esac
  case $line in
    "D$tab"*)
      if under_added_path "${line#*"$tab"}"; then
        conflicting="$conflicting$line$nl"
        continue
      fi
      ;;
  esac
  ordered="$ordered$line$nl"
done
changes=$(printf '%s%s' "$conflicting" "$ordered")

# Stage a single path's blob (mode + object id) from the snapshot tree.
stage_one() {
  # ":(literal)" because ls-tree takes a PATHSPEC: a staged name containing *,
  # ? or [ would otherwise match sibling entries too and ${_mode%% *} would take
  # the first one's mode. (rev-parse "<tree>:<path>" below is already literal.)
  _mode=$(git ls-tree "$staged_tree" -- ":(literal)$1")
  _mode=${_mode%% *}
  _oid=$(git rev-parse "$staged_tree:$1")
  git update-index --add --cacheinfo "$_mode" "$_oid" "$1"
}

printf '%s\n' "$changes" |
  while IFS="$tab" read -r status path; do
    case $status in
      A) message="Add $path" && stage_one "$path" ;;
      D) message="Delete $path" && git update-index --force-remove -- "$path" ;;
      *) message="Update $path" && stage_one "$path" ;;
    esac

    printf '  → %s\n' "$message"
    LEFTHOOK_AUTO_COMMIT_SPLITTING=1 LEFTHOOK=0 git commit --quiet --no-verify -m "$message"
  done

# Every path is committed, so the index already matches the snapshot: skip the
# restore and keep what stat data the per-file commits left.
split_ok=1

# Cancel the original commit: every change is already committed individually.
exit 1
