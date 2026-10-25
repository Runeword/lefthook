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
# So is a file git does not compare with the index (marked assume-unchanged or
# skip-worktree, or any file under core.ignoreStat), whose working-tree copy
# may hold a local-only edit nobody staged, and one below a symlinked directory.
# The two are told apart by the "--prepare" pass below, which must run before
# any formatter touches the worktree.
#
# The commits are built off to the side and published all at once. Each is
# made with "git commit-tree" from a PRIVATE index file, never the real one:
# any other git process may lock the real index mid-split (a "git status" in
# another terminal, an editor's git integration, a shell prompt). A single
# "git update-ref" then moves the branch from the commit the split started on
# to the last one it built, and refuses if anything moved the branch, or HEAD
# to another branch, meanwhile. So a split lands whole or not at all: stopped
# for any reason before that point, it has committed nothing and the staging is
# exactly as it was. Its one write to the real index comes after publishing.
#
# Runs as lefthook's "finalize" job (its "--prepare" sibling runs first). On
# success it exits 1 to cancel the original "git commit" (whose files are now
# committed individually) — so "git commit" always reports failure even though
# every commit went through. A split that publishes nothing never exits 1: it
# exits 3 when the branch moved under it (or a step failed with 1), and
# otherwise with the failing command's own status.

# Prevent recursion. Nothing below runs "git commit", but the hooks git does
# run along the way (post-index-change, reference-transaction) could, and a
# split must never start another. Namespaced because a bare AUTO_COMMIT in the
# environment would silently disable splitting.
if [ "${LEFTHOOK_AUTO_COMMIT_SPLITTING:-}" = "1" ]; then
  exit 0
fi

git_dir=$(git rev-parse --absolute-git-dir)
predirty_file="$git_dir/lefthook-ac-predirty"

# A split killed outright (lefthook SIGKILLs a job on ^C) cannot remove its
# private index, so every run, the "--prepare" pass included, first sweeps any
# left idle for an hour. A live split touches its own with every commit it
# builds; one stalled that long (an unanswered signing prompt) and swept anyway
# just fails before publishing, with nothing committed.
find "$git_dir" -maxdepth 1 -type d -name 'lefthook-split.*' -mmin +60 -exec rm -rf -- {} + 2>/dev/null || true

# "--prepare" runs ahead of every formatter, as the first job after the
# guards, which change neither the index nor a file. It records the staged
# paths whose working-tree file may ALREADY differ from the staged one, so the
# finalize pass can tell a formatter's in-hook edit (fold into the commit) from
# a deliberate partial stage (leave the excluded hunks out). quotePath=false so
# these match the diff-tree paths the finalize pass compares them against. A
# later MISSING file means this pass never ran, or could not make its list.
if [ "${1:-}" = "--prepare" ]; then
  # Staged names lefthook would hand to git as patterns that reach other files
  # are refused by pathspec-guard (scripts/pathspec-guard.sh), the render's
  # first job wherever a formatter stages its fix, which also keeps a copy of
  # lefthook's backup of the unstaged changes. The render passes --no-guard,
  # which leaves the guard to that job alone: it runs once, and turning the job
  # off turns it off. A config rendered before the flag gets it here as well:
  # from 2026-08-15, when this pass appeared, until that job existed, this pass
  # was its only guard.
  if [ "${2:-}" != --no-guard ]; then
    pathspec-guard || exit 1
  fi
  # Those with unstaged changes, and those git never compares, which "git diff"
  # cannot show: marked assume-unchanged or skip-worktree (lowercase or S in
  # "ls-files -v"), usually because the working-tree copy holds a local-only
  # edit. Under core.ignoreStat git compares none of them, so every staged path
  # is listed. A list that cannot be made is no list at all: the finalize pass
  # then keeps every staged blob, rather than fold what a partial one left out.
  if [ "$(git config --type=bool --get core.ignoreStat || true)" = true ]; then
    git -c core.quotePath=false diff --cached --name-only --no-renames
  else
    GIT_OPTIONAL_LOCKS=0 git -c core.quotePath=false diff --name-only --no-renames &&
      git -c core.quotePath=false ls-files -v | LC_ALL=C sed -n 's/^[a-zS] //p'
  fi >"$predirty_file" 2>/dev/null || rm -f -- "$predirty_file"
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

# lefthook_stub HOOK PATH: whether PATH is the script lefthook installs for HOOK
# (told by its last line, in both forms lefthook has written) while lefthook's
# merged config, as `lefthook dump` prints it, has no HOOK section, so that it
# runs nothing. Anything else counts as a message check, a dump that fails
# included.
lefthook_stub() {
  LC_ALL=C awk -v h="$1" '
    { last = $0 }
    END { exit !(last == "call_lefthook run \"" h "\" \"$@\"" || last == "call_lefthook \"run " h " $@\"") }' "$2" 2>/dev/null ||
    return 1
  _dump=$(lefthook dump 2>/dev/null) || return 1
  printf '%s\n' "$_dump" | LC_ALL=C awk -v h="$1" 'index($0, h ":") == 1 { found = 1 } END { exit found }'
}

# A commit-msg or prepare-commit-msg hook holds commit messages to some rule (a
# ticket id, a convention, a sign-off). The per-file commits carry generated
# messages it would never see, so leave the commit whole and let git run the
# hook on it. --git-path honours core.hooksPath. lefthook's own script for a
# hook its config leaves out runs nothing, though, and lefthook 1.13.0 to
# 2.0.15 install one for prepare-commit-msg on every `lefthook install` (to keep
# the hooks in sync; later versions when the config has no hooks at all), where
# it stays: that one is no reason to keep the commit whole.
for hook in prepare-commit-msg commit-msg; do
  hook_path=$(git rev-parse --git-path "hooks/$hook")
  if [ -f "$hook_path" ] && [ -x "$hook_path" ] && ! lefthook_stub "$hook" "$hook_path"; then
    echo "auto-commit: a $hook hook is installed, so this commit is not split: it stays one commit, for that hook to check"
    exit 0
  fi
done

# Base to diff the snapshot against: HEAD, or the empty tree on the first
# commit. The branch to publish to is resolved now too: HEAD's branch, or HEAD
# itself when detached, which must still be where it is now when the split
# publishes.
if start_head=$(git rev-parse --verify --quiet HEAD); then
  base=$start_head
else
  start_head=""
  base=$(git hash-object -t tree /dev/null)
fi
if head_ref=$(git symbolic-ref -q HEAD); then
  no_deref=""
else
  head_ref=HEAD
  no_deref=--no-deref
fi

# git commit honours commit.gpgSign; commit-tree does not, so pass it on.
sign=--no-gpg-sign
if [ "$(git config --type=bool --get commit.gpgSign || true)" = true ]; then
  sign=-S
fi

tab=$(printf '\t')

# The real index, absolute (git hands the hook a path relative to the top), and
# the lock file git creates before it writes that index.
real_index=$(git rev-parse --path-format=absolute --git-path index)
index_lock=$real_index.lock

# The private index, in a directory of its own: unique per run, so two splits
# at once never share one, and absolute so it still resolves from a hook that
# changes directory.
split_dir=$(mktemp -d "$git_dir/lefthook-split.XXXXXX")
split_index=$split_dir/index
# One "basemode baseoid stagedmode stagedoid finalmode finaloid<TAB>path" line
# per path, in commit order: what reconcile needs once the commits are public.
entries=$split_dir/entries

# The real index still holds the staging the split started from. Once the
# commits are public, bring each path the split handled up to what HEAD now
# records: a formatter's fix that was folded in, or a path another process
# unstaged mid-split, which left alone the next commit would revert. Only where
# HEAD really holds that entry, though (after a checkout or reset elsewhere the
# index describes some other commit), and only where the real index still has
# the entry the split started from or the one it snapshotted: anything else is
# a newer staging, and stays. That write is the only one to the real index.
#
# It is made under index.lock, held from the read to the write: read without
# it, a "git add" or a commit that landed in between was overwritten with what
# the read saw, unstaging the add or setting up the next commit to revert the
# commit. git takes that lock by creating the file exclusively, and so does
# this (noclobber, which bash implements with O_EXCL); git then refuses to write
# the index until the lock is gone, and so waits or fails instead. The new index
# is written into the lock file and renamed over the index, as git does. A first
# look without the lock comes before: usually nothing needs writing, and writing
# nothing needs no lock.
reconcile() {
  reconciled=1
  [ -s "$entries" ] || return 0
  if ! reconcile_plan "$real_index" "$split_dir/stage-unlocked" 2>/dev/null; then
    # No plan: should the read under the lock fail too, every path the split
    # handled is named.
    : >"$split_dir/stage-unlocked"
  elif [ ! -s "$split_dir/stage-unlocked" ]; then
    return 0
  fi
  _tries=0
  until (set -C && : >"$index_lock") 2>/dev/null; do
    _tries=$((_tries + 1))
    if [ "$_tries" -ge 50 ]; then
      echo "auto-commit: another git process held $index_lock for 5 s" >&2
      reconcile_failed "$split_dir/stage-unlocked"
      return 0
    fi
    sleep 0.1
  done
  index_locked=1
  # The copy keeps the index's mtime, against which git tells a racily clean
  # entry, so git still re-checks such an entry rather than trust its stat data.
  if ! cp --preserve=timestamps -- "$real_index" "$index_lock" ||
    ! reconcile_plan "$index_lock" "$split_dir/stage"; then
    rm -f -- "$index_lock"
    reconcile_failed "$split_dir/stage-unlocked"
  elif [ ! -s "$split_dir/stage" ]; then
    rm -f -- "$index_lock"
  elif ! { GIT_INDEX_FILE=$index_lock git update-index --index-info <"$split_dir/stage" &&
    mv -f -- "$index_lock" "$real_index"; }; then
    rm -f -- "$index_lock"
    reconcile_failed "$split_dir/stage"
  fi
  index_locked=0
}

# reconcile_failed PLAN: say which paths PLAN would have brought up to date, or,
# for an empty PLAN (none could be made), every path the split handled: any of
# them may still be staged as before the commits. `git reset -q -- PATH` stages
# what HEAD holds, as reconcile would have; `git add` would stage unstaged
# changes too, and add back a file whose removal `git rm --cached` staged.
reconcile_failed() {
  if [ -s "$1" ]; then
    echo "auto-commit: committed, but the index could not be brought up to date for these (git reset -q -- them):" >&2
    sed "s/^[^$tab]*$tab/  /" "$1" >&2 2>/dev/null || true
  else
    echo "auto-commit: committed, but the index could not be read to bring these up to date; any that git status still lists as staged may be staged as before the commits (git reset -q -- it):" >&2
    sed "s/^[^$tab]*$tab/  /" "$entries" >&2 2>/dev/null || true
  fi
}

# reconcile_plan INDEX OUT: into OUT, the --index-info lines that bring each
# path the split handled in INDEX up to what HEAD records, where reconcile may.
reconcile_plan() {
  : >"$2"
  GIT_INDEX_FILE=$1 git -c core.quotePath=false ls-files -s >"$split_dir/real" || return
  git -c core.quotePath=false ls-tree -r --full-tree HEAD >"$split_dir/head" 2>/dev/null ||
    : >"$split_dir/head"
  # Entries are "mode oid", or "-" for absent; the zero oid (a removal for
  # --index-info) takes its length from the base oid, so SHA-256 works too.
  # The listings hold every path: only those the split handled are parsed.
  LC_ALL=C awk '
    function ent(mode, oid) { return (mode + 0 == 0) ? "-" : (mode " " oid) }
    { t = index($0, "\t"); p = substr($0, t + 1) }
    FILENAME == ARGV[1] {
      split(substr($0, 1, t - 1), f, " ")
      order[++n] = p
      B[p] = ent(f[1], f[2]); S[p] = ent(f[3], f[4]); F[p] = ent(f[5], f[6])
      Z[p] = f[2]; gsub(/./, "0", Z[p])
      next
    }
    !(p in F) { next }
    { split(substr($0, 1, t - 1), f, " ") }
    FILENAME == ARGV[2] { if (f[3] != "0") U[p] = 1; else R[p] = ent(f[1], f[2]); next }
    { H[p] = ent(f[1], f[3]) }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        if (p in U) continue
        h = (p in H) ? H[p] : "-"
        r = (p in R) ? R[p] : "-"
        if (h != F[p] || r == F[p]) continue
        if (r == B[p] || r == S[p]) print ((F[p] == "-") ? ("0 " Z[p]) : F[p]) "\t" p
      }
    }' "$entries" "$split_dir/real" "$split_dir/head" >"$2"
}

published=0
reconciled=0
index_locked=0
reported=0
parent=""
# cleanup STATUS. Reached only through the traps installed below.
# shellcheck disable=SC2329
cleanup() {
  # Stopped while holding index.lock: git would refuse every later write to the
  # index until someone deleted it by hand.
  if [ "$index_locked" = 1 ]; then
    rm -f -- "$index_lock" 2>/dev/null || true
  fi
  # A signal can land right after update-ref succeeded, before the line that
  # records it: look rather than trust the flag.
  if [ "$published" = 0 ] && [ -n "$parent" ] && [ "$parent" != "$start_head" ] &&
    [ "$(git rev-parse --verify --quiet "$head_ref" || true)" = "$parent" ]; then
    published=1
  fi
  if [ "$published" = 1 ]; then
    if [ "$reconciled" = 0 ]; then
      reconcile
    fi
  elif [ "$1" != 0 ] && [ "$reported" = 0 ]; then
    echo "auto-commit: split stopped; nothing was committed and everything is still staged" >&2
  fi
  rm -rf "$split_dir" 2>/dev/null || true
  # Per-run scratch from the "--prepare" pass; drop it whichever way we leave.
  rm -f "$predirty_file" 2>/dev/null || true
}
# Reached only through the EXIT trap.
# shellcheck disable=SC2329
on_exit() {
  _status=$?
  cleanup "$_status"
  # 1 means "split and committed". A git command that fails with 1 before
  # anything was published (commit-tree does, when the signer refuses) must
  # not read as that.
  if [ "$published" = 0 ] && [ "$_status" = 1 ]; then
    exit 3
  fi
}
trap on_exit EXIT
# bash does NOT run the EXIT trap when it dies from a SIGINT delivered to the
# foreground process group (^C at the terminal). Clean up explicitly, then
# disarm EXIT so cleanup does not run twice.
trap 'cleanup 130; trap - EXIT; exit 130' INT
trap 'cleanup 143; trap - EXIT; exit 143' TERM
trap 'cleanup 129; trap - EXIT; exit 129' HUP

# Snapshot the staging from a copy of the real index. git replaces that file
# atomically, so the copy is always whole, and write-tree then locks the copy
# rather than contending for the real index's lock.
cp -- "$real_index" "$split_index"
staged_tree=$(GIT_INDEX_FILE=$split_index git write-tree)

# Walk the snapshot's changes vs base, one raw line per path:
# ":oldmode newmode oldoid newoid STATUS<TAB>path", so the loop has each path's
# base and staged entries without asking git again. --no-renames keeps every
# entry to a single-letter status plus one path; core.quotePath=false keeps
# UTF-8 and spaces literal. Collected up front so an unsupported path can bail
# out before anything is committed.
changes=$(git -c core.quotePath=false diff-tree -r --no-renames "$base" "$staged_tree")

# Guard the loop below: printing an empty list still yields one blank line,
# which would read back as an empty path.
if [ "$changes" = "" ]; then
  exit 0
fi

# A path holding a tab, newline, double quote or backslash still comes back
# C-quoted, and feeding that back to git would fail partway through. Hand the
# whole commit to git untouched instead.
case $changes in
  *"$tab"'"'*)
    echo "auto-commit: tab, newline, quote or backslash in a staged filename is unsupported; committing as one commit" >&2
    exit 0
    ;;
esac
printf '%s\n' "$changes" >"$split_dir/changes"

# Which staged paths' worktree files could already differ from the staged ones
# when the hook started (from the "--prepare" pass): unstaged changes, or a
# file git does not compare. A path NOT listed was clean then, so its current
# worktree blob is exactly "what was staged, plus any formatter fix": safe to
# fold in. A listed path keeps its staged blob, preserving partial staging. If
# the file is absent the prepare pass never ran, or could not make its list:
# every path keeps its staged blob.
if [ -f "$predirty_file" ]; then
  predirty=$predirty_file
  have_predirty=1
else
  predirty=/dev/null
  have_predirty=0
fi

# Plan the commits in one pass, marking with F each path to take from the
# worktree and listing those paths for hashing.
#
# Order: staging the file `a` fails while `a/b` is still in the index (git
# refuses "'a' appears as both a file and a directory"), and diff-tree emits
# `A a` before `D a/b`, so a deletion under an added path is committed first.
# ONLY those: moving every deletion ahead of every addition would split a
# rename (`D old` + `A new`) so that the intermediate commit holds neither
# path, and a bisect landing there sees the file simply missing. Everything
# else keeps diff-tree's order, which emits the addition first.
#
# Worktree blob: only a regular file (100644 or 100755). "git hash-object"
# FOLLOWS a symlink and hashes its TARGET (unlike "git add", which stores the
# link-target string), so a symlink pointing at a local secret would fold that
# secret's bytes into the commit; and a gitlink's worktree is a directory.
# Neither is ever reformatted in-hook, so its staged blob is always right.
: >"$split_dir/fold-cand"
LC_ALL=C awk -v pre="$predirty" -v havepre="$have_predirty" -v cand="$split_dir/fold-cand" '
  FILENAME == pre { P[$0] = 1; next }
  {
    t = index($0, "\t")
    line[++n] = $0
    path[n] = substr($0, t + 1)
    m = split(substr($0, 1, t - 1), f, " ")
    st[n] = f[m]
    mode[n] = f[2]
    if (st[n] == "A") added[path[n]] = 1
  }
  function emit(i, fold) {
    fold = havepre && st[i] != "D" && (mode[i] == "100644" || mode[i] == "100755") && !(path[i] in P)
    print (fold ? "F" : "-") "\t" line[i]
    if (fold) print path[i] > cand
  }
  END {
    for (i = 1; i <= n; i++) if (st[i] == "D") {
      p = path[i]
      while ((k = match(p, /\/[^\/]*$/)) > 0) {
        p = substr(p, 1, k - 1)
        if (p in added) { emit(i); moved[i] = 1; break }
      }
    }
    for (i = 1; i <= n; i++) if (!(i in moved)) emit(i)
  }' "$predirty" "$split_dir/changes" >"$split_dir/plan"

# beyond_symlink PATH: whether a directory above PATH is a symlink in the
# worktree. The file PATH names there is then wherever that link points, maybe
# outside the repository; git itself takes such a path for deleted.
beyond_symlink() {
  _p=$1
  while :; do
    case $_p in
      */*) _p=${_p%/*} ;;
      *) return 1 ;;
    esac
    if [ -L "$_p" ]; then
      return 0
    fi
  done
}

# Only a path that is still a regular file in the worktree can fold: one moved
# or deleted there since it was staged, or now below a symlinked directory,
# keeps its staged blob, as any path with unstaged changes does. One mark per
# candidate, in plan order: H (hashed) or - (staged blob).
while IFS= read -r p; do
  if [ -f "$p" ] && [ ! -L "$p" ] && ! beyond_symlink "$p"; then
    printf '%s\n' "$p" >&4
    echo H
  else
    echo -
  fi
done <"$split_dir/fold-cand" >"$split_dir/fold-marks" 4>"$split_dir/fold-paths"

# The worktree blobs, hashed together and before the first commit: one process
# instead of one per path, and a later edit by some other process to a file not
# yet reached cannot slip into the commit. hash-object -w applies clean filters
# (as "git add" would) and writes each blob so the private index can use it.
: >"$split_dir/fold-oids"
if [ -s "$split_dir/fold-paths" ]; then
  git hash-object -w --stdin-paths <"$split_dir/fold-paths" >"$split_dir/fold-oids"
fi

# Start the private index at base; the loop below adds one change per commit.
GIT_INDEX_FILE=$split_index git read-tree "$base"

# The hooks git runs while the split works (post-index-change,
# reference-transaction) must not run lefthook again, nor start another split.
LEFTHOOK=0
LEFTHOOK_AUTO_COMMIT_SPLITTING=1
export LEFTHOOK LEFTHOOK_AUTO_COMMIT_SPLITTING

parent=$start_head
parent_tree=$(git rev-parse "$base^{tree}")
commits=0
skipped=0
: >"$entries"
# Read from a file rather than a pipe so the loop runs in this shell, not a
# subshell: a signal trap then waits for the git command in flight before
# cleanup removes the private index. From a subshell, a trap could fire while
# a git command was still reading that index, and git takes a missing index
# for an empty one.
while IFS= read -r line; do
  fold=${line%%"$tab"*}
  line=${line#*"$tab"}
  path=${line#*"$tab"}
  # ":oldmode newmode oldoid newoid STATUS": digits, hex and one letter.
  # shellcheck disable=SC2086
  set -- ${line%%"$tab"*}
  base_mode=${1#:}
  base_oid=$3
  mode=$2
  staged_oid=$4
  status=$5
  oid=$staged_oid
  case $status in
    A) message="Add $path" ;;
    D) message="Delete $path" ;;
    *) message="Update $path" ;;
  esac
  if [ "$status" = D ]; then
    GIT_INDEX_FILE=$split_index git update-index --force-remove -- "$path"
  else
    if [ "$fold" = F ]; then
      IFS= read -r mark <&3
      if [ "$mark" = H ]; then
        IFS= read -r oid <&4
      fi
    fi
    GIT_INDEX_FILE=$split_index git update-index --add --cacheinfo "$mode" "$oid" "$path"
  fi
  final="$mode $oid"

  tree=$(GIT_INDEX_FILE=$split_index git write-tree)
  if [ "$tree" = "$parent_tree" ]; then
    # A formatter put this file back exactly as the commit before has it: an
    # empty commit would say nothing, so leave it out.
    printf '  - %s (left out: nothing changed after formatting)\n' "$path"
    final="$base_mode $base_oid"
    skipped=$((skipped + 1))
  else
    # git commit trims trailing blanks from a -m message; commit-tree keeps
    # them (a path ending in a space).
    while :; do
      case $message in
        *' ') message=${message% } ;;
        *) break ;;
      esac
    done
    if [ -n "$parent" ]; then
      parent=$(git commit-tree "$sign" -p "$parent" -m "$message" "$tree")
    else
      parent=$(git commit-tree "$sign" -m "$message" "$tree")
    fi
    parent_tree=$tree
    commits=$((commits + 1))
    printf '  → %s\n' "$message"
  fi
  printf '%s %s %s %s %s\t%s\n' "$base_mode" "$base_oid" "$mode" "$staged_oid" "$final" "$path" >>"$entries"
done <"$split_dir/plan" 3<"$split_dir/fold-marks" 4<"$split_dir/fold-oids"

if [ "$commits" = 0 ]; then
  published=1
  reconcile
  echo "auto-commit: nothing left to commit after formatting; the original commit is cancelled"
  exit 1
fi

# Publish. HEAD must still point to the branch the split started on, and that
# branch must still be at the commit it started from: anything else means
# another commit, checkout or reset landed meanwhile, which the new commits
# would silently revert. update-ref checks the second atomically.
if [ "$(git symbolic-ref -q HEAD || echo HEAD)" != "$head_ref" ]; then
  reported=1
  echo "auto-commit: HEAD left $head_ref during the split; nothing was committed and everything is still staged" >&2
  exit 3
fi
if ! git update-ref ${no_deref:+"$no_deref"} -m "auto-commit: split into $commits commits" \
  "$head_ref" "$parent" "$start_head"; then
  reported=1
  echo "auto-commit: could not move $head_ref (another commit, checkout or reset moved it during the split, or a hook refused); nothing was committed and everything is still staged" >&2
  exit 3
fi
published=1
reconcile

# git commit runs this after each commit, and the umbrella commit that would
# have run it is cancelled: without it, a repository committed to only through
# auto-commit would never pack its loose objects. --detach keeps it out of the
# hook's way.
git maintenance run --auto --quiet --detach >/dev/null 2>&1 || true

if [ "$skipped" = 0 ]; then
  printf 'auto-commit: %s commits made. The original commit is cancelled on purpose, so git commit reports a failure.\n' "$commits"
else
  printf 'auto-commit: %s commits made, %s files left out (unchanged after formatting). The original commit is cancelled on purpose, so git commit reports a failure.\n' "$commits" "$skipped"
fi
exit 1
