#!/bin/sh
# Split the staged index into one commit per file with a generated message,
# then abort the umbrella commit.
#
# A file that was CLEAN at hook start (worktree == index) is committed from its
# WORKTREE blob, so a formatter's in-hook fix is folded in no matter when
# lefthook stages it — lefthook >= 2.1.7 defers "stage_fixed" to AFTER this
# finalize job, leaving the index alone still holding the pre-format blob. A
# file that ALREADY had unstaged changes is committed from its STAGED blob, so
# partial staging ("git add -p") is preserved: unstaged hunks stay uncommitted.
# The two are told apart by the "--prepare" pass below, which must run as the
# FIRST pre-commit job, before any formatter touches the worktree.
#
# The commits are built in a PRIVATE index file, never in the real one: any
# other git process may lock the real index mid-split (a "git status" in
# another terminal, an editor's git integration, a shell prompt), and a split
# rebuilding it would then fail partway with the staging half dismantled. The
# real index keeps the staging throughout, so a split that stops partway leaves
# whatever it did not commit still staged. Its one write comes at the end,
# staging the formatter fixes folded in above.
#
# Runs as lefthook's "finalize" job (its "--prepare" sibling runs first). On
# success it exits 1 to cancel the original "git commit" (whose files are now
# committed individually) — so "git commit" always reports failure even though
# every commit went through.

# Prevent recursion: the per-file "git commit" calls below re-enter the hook.
# Namespaced because a bare AUTO_COMMIT in the environment would silently
# disable splitting.
if [ "${LEFTHOOK_AUTO_COMMIT_SPLITTING:-}" = "1" ]; then
  exit 0
fi

git_dir=$(git rev-parse --git-dir)
predirty_file="$git_dir/lefthook-ac-predirty"

# "--prepare" runs as the FIRST pre-commit job, before any formatter. It records
# the staged paths that ALREADY carry unstaged changes, so the finalize pass can
# tell a formatter's in-hook edit (fold into the commit) from a deliberate
# partial stage (leave the excluded hunks out). quotePath=false so these match
# the diff-tree paths the finalize pass compares them against. The redirect
# always creates the file, so a later MISSING file means this pass never ran.
if [ "${1:-}" = "--prepare" ]; then
  git -c core.quotePath=false diff --name-only >"$predirty_file" 2>/dev/null || true
  exit 0
fi

# A merge, squash-merge, cherry-pick, revert, or rebase in progress must
# conclude as the single commit git expects: the first per-file commit below
# would consume its state (e.g. MERGE_HEAD) and record a history that never
# happened. SQUASH_MSG covers "git merge --squash", which sets no MERGE_HEAD
# and whose whole purpose is to land as one commit.
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
# Resolved once: the loop also checks that HEAD is still here before its first
# commit.
if start_head=$(git rev-parse --verify --quiet HEAD); then
  base=$start_head
else
  start_head=""
  base=$(git hash-object -t tree /dev/null)
fi

tab=$(printf '\t')

# The private index, in a directory of its own: unique per run, so two splits
# at once never share one, and absolute so it still resolves from a hook that
# changes directory. A split killed outright (lefthook SIGKILLs a job on ^C)
# cannot remove its own, so first sweep any left idle for an hour; a live one
# is touched by every commit it makes.
abs_git_dir=$(git rev-parse --absolute-git-dir)
find "$abs_git_dir" -maxdepth 1 -type d -name 'lefthook-split.*' -mmin +60 -exec rm -rf -- {} + 2>/dev/null || true
split_dir=$(mktemp -d "$abs_git_dir/lefthook-split.XXXXXX")
split_index=$split_dir/index
# One "mode oid<TAB>path" line per path staged from the worktree rather than
# the index; cleanup stages in the real index the ones HEAD ends up holding.
folded=$split_dir/folded

splitting=0
split_done=0
# Reached only through the traps installed below.
# shellcheck disable=SC2329
cleanup() {
  if [ "$splitting" = 1 ] && [ "$split_done" = 0 ]; then
    echo "auto-commit: split stopped; whatever it did not commit is still staged" >&2
  fi
  # The real index still holds the pre-format blob of every file committed
  # from the worktree; left alone, the next commit would revert those fixes.
  # Only where HEAD still holds the committed blob, though: after a checkout or
  # reset elsewhere the index describes some other commit. This is the only
  # write to the real index, so it waits out whoever holds the lock.
  if [ -s "$folded" ]; then
    while IFS= read -r _entry; do
      _oid=${_entry%%"$tab"*}
      if [ "$(git rev-parse --verify --quiet "HEAD:${_entry#*"$tab"}" || true)" = "${_oid#* }" ]; then
        printf '%s\n' "$_entry"
      fi
    done <"$folded" >"$split_dir/stage"
    _tries=0
    while [ -s "$split_dir/stage" ] && ! _err=$(git update-index --index-info <"$split_dir/stage" 2>&1); do
      _tries=$((_tries + 1))
      if [ "$_tries" -ge 50 ]; then
        printf '%s\n' "$_err" >&2
        echo "auto-commit: formatter fixes committed but not staged (git add to stage them):" >&2
        sed "s/^[^$tab]*$tab/  /" "$split_dir/stage" >&2 || true
        break
      fi
      sleep 0.1
    done
  fi
  rm -rf "$split_dir" 2>/dev/null || true
  # Per-run scratch from the "--prepare" pass; drop it whichever way we leave.
  rm -f "$predirty_file" 2>/dev/null || true
}
trap cleanup EXIT
# bash does NOT run the EXIT trap when it dies from a SIGINT delivered to the
# foreground process group (^C at the terminal), which would leave the folded
# fixes unstaged. Clean up explicitly, then disarm EXIT so cleanup does not run
# twice.
trap 'cleanup; trap - EXIT; exit 130' INT
trap 'cleanup; trap - EXIT; exit 143' TERM
trap 'cleanup; trap - EXIT; exit 129' HUP

# Snapshot the staging from a copy of the real index. git replaces that file
# atomically, so the copy is always whole, and write-tree then locks the copy
# rather than contending for the real index's lock.
cp -- "$(git rev-parse --git-path index)" "$split_index"
staged_tree=$(GIT_INDEX_FILE=$split_index git write-tree)

# Walk the snapshot's changes vs base, one raw line per path:
# ":oldmode newmode oldoid newoid STATUS<TAB>path", so the loop has each path's
# staged mode and blob without asking git again. --no-renames keeps every entry
# to a single-letter status plus one path; core.quotePath=false keeps UTF-8 and
# spaces literal. Collected up front so an unsupported path can bail out before
# anything is committed.
changes=$(git -c core.quotePath=false diff-tree -r --no-renames "$base" "$staged_tree")

# Guard the loop below: printing an empty list still yields one blank line,
# which would read back as an empty path.
if [ "$changes" = "" ]; then
  exit 0
fi

# A path holding a tab, newline, double quote or backslash still comes back
# C-quoted, and feeding that back to git fails partway through — committing the
# paths that sort before it and wedging every retry. Hand the whole commit to
# git untouched instead.
case $changes in
  *"$tab"'"'*)
    echo "auto-commit: tab, newline, quote or backslash in a staged filename is unsupported; committing as one commit" >&2
    exit 0
    ;;
esac

# Which staged paths already had unstaged changes when the hook started (from
# the "--prepare" pass). A path NOT listed was clean then, so its current
# worktree blob is exactly "what was staged, plus any formatter fix" — safe to
# fold in. A listed path keeps its staged blob, preserving partial staging. If
# the file is absent the prepare pass never ran: fall back to staged blobs so
# behaviour never regresses below today's.
if [ -f "$predirty_file" ]; then
  predirty=$(cat "$predirty_file")
  have_predirty=1
else
  predirty=""
  have_predirty=0
fi

# Start the private index at base; the loop below adds one change per commit.
GIT_INDEX_FILE=$split_index git read-tree "$base"

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
added_paths=$(printf '%s\n' "$changes" | sed -n "s/^[^$tab]* A$tab//p")

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
  case ${line%%"$tab"*} in
    *" D")
      if under_added_path "${line#*"$tab"}"; then
        conflicting="$conflicting$line$nl"
        continue
      fi
      ;;
  esac
  ordered="$ordered$line$nl"
done
changes=$(printf '%s%s' "$conflicting" "$ordered")

# True when $1 was recorded as already-dirty by the "--prepare" pass.
is_predirty() {
  case "$nl$predirty$nl" in
    *"$nl$1$nl"*) return 0 ;;
  esac
  return 1
}

# True for a regular-file mode (100644 or 100755). A symlink (120000) or gitlink
# (160000) is EXCLUDED from the worktree-blob branch below. "git hash-object"
# FOLLOWS a staged symlink and hashes its TARGET file's contents (unlike
# "git add"/update-index, which lstat and store the link-target string), so a
# symlink pointing at a local secret would fold that secret's bytes into the
# commit; and it would error on a gitlink's worktree directory, aborting the
# split under "set -e". Neither is ever reformatted in-hook, so its staged blob
# is always the correct source.
is_regular_mode() {
  case "$1" in
    100644 | 100755) return 0 ;;
  esac
  return 1
}

# Stage path $1 in the private index with its staged mode $2 (formatters do not
# change it) and its staged blob $3, EXCEPT for a regular file that was clean
# at hook start, whose worktree blob is taken instead so an in-hook reformat
# lands in this commit.
stage_one() {
  _oid=$3
  if [ "$have_predirty" = 1 ] && ! is_predirty "$1" && is_regular_mode "$2"; then
    # hash-object -w applies clean filters (as "git add" would) and writes the
    # blob to the object db so update-index can reference it.
    _oid=$(git hash-object -w -- "$1")
  fi
  GIT_INDEX_FILE=$split_index git update-index --add --cacheinfo "$2" "$_oid" "$1"
  # A blob other than the staged one has to reach the real index as well;
  # cleanup stages it if the commit holding it lands.
  if [ "$_oid" != "$3" ]; then
    printf '%s %s\t%s\n' "$2" "$_oid" "$1" >>"$folded"
  fi
}

splitting=1
seen_head=$start_head
committed=0
printf '%s\n' "$changes" >"$split_dir/changes"
# Read from a file rather than a pipe so the loop runs in this shell, not a
# subshell: a signal trap then waits for the git command in flight before
# cleanup removes the private index. From a subshell, a trap could fire while
# a "git commit" was still reading that index, and git takes a missing index
# for an empty one — committing a tree with every file deleted.
while IFS= read -r line; do
  path=${line#*"$tab"}
  meta=${line%%"$tab"*}
  status=${meta##* }
  mode=${meta#* }
  oid=${mode#* * }
  mode=${mode%% *}
  oid=${oid%% *}
  case $status in
    A) message="Add $path" && stage_one "$path" "$mode" "$oid" ;;
    D) message="Delete $path" && GIT_INDEX_FILE=$split_index git update-index --force-remove -- "$path" ;;
    *) message="Update $path" && stage_one "$path" "$mode" "$oid" ;;
  esac

  # Stop if HEAD moved since the split last looked (another commit, checkout
  # or reset from elsewhere, which nothing locks out while the real index
  # stays free): this commit would be stacked on top with the private index's
  # tree, silently reverting whatever moved HEAD. Before the first commit HEAD
  # must still be where the split started; after that, a child of the HEAD
  # seen last time, i.e. the commit just made. One rev-parse lists HEAD and
  # its parents, or fails while the branch is still unborn.
  heads=$(git rev-parse HEAD 'HEAD^@' 2>/dev/null) || heads=""
  if [ "$committed" = 0 ]; then
    found=${heads%%"$nl"*}
  else
    found=""
    case $heads in
      *"$nl"*) found=${heads#*"$nl"} && found=${found%%"$nl"*} ;;
    esac
  fi
  if [ "$found" != "$seen_head" ]; then
    echo "auto-commit: HEAD moved during the split (another commit, checkout or reset)" >&2
    exit 1
  fi
  seen_head=${heads%%"$nl"*}

  printf '  → %s\n' "$message"
  GIT_INDEX_FILE=$split_index LEFTHOOK_AUTO_COMMIT_SPLITTING=1 LEFTHOOK=0 git commit --quiet --no-verify -m "$message"
  committed=1
done <"$split_dir/changes"
split_done=1

# Cancel the original commit: every change is already committed individually.
exit 1
