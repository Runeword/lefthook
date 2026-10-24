#!/bin/sh
# Refuse a commit whose staged file names lefthook would hand to git as
# patterns that reach other files, after keeping a copy of the backup lefthook
# makes of the unstaged changes, which lefthook drops.
#
# lefthook hands staged file names to git as pathspecs: "git add --force"
# re-stages a formatter's fix (stage_fixed), "git checkout --force" sets
# unstaged hunks aside. There a name starting with ':' reads as pathspec magic,
# and one holding '*', '?', '[' or '\' as a pattern, which can match other
# files, ignored ones included (--force), and the commit then takes them in:
# staging g*.txt also committed an ignored gsecret.txt. lefthook also trims
# blanks off the ends of each name and unquotes one wrapped in backquotes or
# single quotes (Go's strings.TrimSpace and strconv.Unquote), so for a staged
# "gsecret.txt " it formatted and staged gsecret.txt.
#
# The render makes this the first pre-commit job wherever an enabled job sets
# stage_fixed, ahead of every formatter, with no skip for merges or rebases:
# the formatters run there too. It comes too late for the set-aside, which
# lefthook does before any job runs. auto-commit's "--prepare" pass runs it as
# well, for configs rendered with that pass (from 2026-08-15) but before this
# job existed. Configs older than that run neither.
#
# A pattern is refused only when it matches some other path: a route file such
# as app/[id]/page.tsx nearly always matches only itself. git answers, with
# ls-files over the index and the working tree and no ignore rules, which is
# what "git add --force" matches: one call for all the names, then, only if
# they match some other path, calls on halves of them down to the single names
# that do, to say what each matches. The other names checked here do not
# count, since they are staged already. Whatever cannot be checked is refused.
# Names are read NUL-terminated: git quotes one holding a tab or a newline,
# and the quoting hid a leading ':'. awk reads git's output through pipes, so
# a run that lefthook kills leaves nothing behind.
#
# GIT_LITERAL_PATHSPECS and its siblings stay set, unlike in the wrappers
# that pass git patterns of their own: lefthook's own git calls inherit them,
# and the names are checked as git will read them there.
#
# The copy of lefthook's backup is the one thing this writes. When lefthook
# sets the unstaged hunks of partially staged files aside, it first stashes
# every tracked change ("lefthook auto backup"). It drops that stash after the
# hook or, when putting the hunks back fails, right away or at the next commit
# with a partially staged file. When a formatter's fix conflicts with a hunk
# set aside, lefthook 2.1.7 to 2.1.15 reset every tracked file, and with
# auto-commit 2.1.16 to 2.2.2 still leave the other files' unstaged edits out
# of the working tree: the stash was their only copy. refs/lefthook/backup and
# its reflog keep each one for as long as git keeps reflog entries; README.md
# says how to get the edits back.

# Pathspecs resolve from the current directory, and lefthook runs git from the
# top.
if ! top=$(git rev-parse --show-toplevel) || ! cd -- "$top"; then
  echo "pathspec-guard: the staged file names could not be listed, so they could not be checked" >&2
  exit 1
fi
# The newest stash entry is this run's, when lefthook made one: it stashes
# right before the jobs start. Another job may have kept it already (this runs
# twice where auto-commit's prepare pass follows the guard job). With no stash,
# the list is empty.
if ! pg_top=$(git stash list -1 --format='%H %gs'); then
  echo "pathspec-guard: the stash could not be read, so lefthook's backup of the unstaged changes could not be kept" >&2
  exit 1
fi
case $pg_top in
  *' lefthook auto backup')
    pg_stash=${pg_top%% *}
    if [ "$(git rev-parse -q --verify refs/lefthook/backup)" != "$pg_stash" ] &&
      ! git update-ref --create-reflog -m "lefthook auto backup" refs/lefthook/backup "$pg_stash"; then
      echo "pathspec-guard: lefthook's backup of the unstaged changes could not be kept in refs/lefthook/backup" >&2
      exit 1
    fi
    ;;
esac
LC_ALL=C awk '
  function show(s) { gsub(/[[:cntrl:]]/, "?", s); return "\047" s "\047" }
  function quote(s) { gsub(/\047/, "\047\\\047\047", s); return "\047" s "\047" }
  function refuse(why) { refused[++nrefused] = why }
  # probe(lo, hi): whether names lo to hi, read together as patterns, match a
  # path that is not one of the names. If so, each half is asked again, down
  # to the single names, whose matches the refusal lists: a few calls for a
  # few such names among many, not one per name.
  function probe(lo, hi,    cmd, path, k, list, i, mid) {
    cmd = "git ls-files -z --cached --others --"
    for (i = lo; i <= hi; i++) cmd = cmd " " quoted[i]
    k = 0
    list = ""
    while ((cmd | getline path) > 0)
      if (!(path in pattern) && ++k <= 3) list = list (k > 1 ? ", " : "") show(path)
    if (close(cmd) != 0) {
      for (i = lo; i <= hi; i++) refuse(show(names[i]) " could not be checked")
    } else if (k && lo == hi) {
      refuse(show(names[lo]) ", read as a pattern, also matches " list (k > 3 ? " and " (k - 3) " more" : ""))
    } else if (k) {
      mid = int((lo + hi) / 2)
      probe(lo, mid)
      probe(mid + 1, hi)
    }
  }
  BEGIN {
    RS = "\0"
    # The blanks TrimSpace takes off: the ASCII ones and, as UTF-8, the other
    # characters Unicode calls white space, which git leaves unquoted under
    # core.quotePath=false.
    blank = "([ \t\n\v\f\r]|\302[\205\240]|\341\232\200|\342\200[\200-\212\250\251\257]|\342\201\237|\343\200\200)"
    cmd = "git diff --cached --name-only -z --diff-filter=ACMRT"
    while ((cmd | getline name) > 0)
      if (name ~ /^:/) refuse(show(name) " starts with \047:\047, which git reads as pathspec magic")
      else if (name ~ ("^" blank) || name ~ (blank "$")) refuse(show(name) " starts or ends with a blank, which lefthook trims off")
      else if (length(name) > 1 && (name ~ /^`.*`$/ || name ~ /^\047.*\047$/)) refuse(show(name) " is wrapped in quotes, which lefthook takes off")
      else if (name ~ /[*?[\\]/) { pattern[name] = 1; names[++n] = name }
    if (close(cmd) != 0) { refuse("the staged file names could not be listed"); n = 0 }
    for (i = 1; i <= n; i++) quoted[i] = quote(names[i])
    # In chunks, so that no command comes near the length the kernel takes in
    # a single argument (sh -c gets it as one).
    for (lo = 1; lo <= n; lo = hi + 1) {
      hi = lo
      len = length(quoted[lo])
      while (hi < n && len + length(quoted[hi + 1]) < 65536) len += length(quoted[++hi]) + 1
      probe(lo, hi)
    }
    if (!nrefused) exit 0
    print "pathspec-guard: lefthook hands staged file names to git as patterns, and these are not safe to hand over:"
    for (i = 1; i <= nrefused; i++) print "  " refused[i]
    print "pathspec-guard: rename them, or move the files they match; git commit --no-verify runs no hook at all, the secret scan included"
    exit 1
  }' >&2
