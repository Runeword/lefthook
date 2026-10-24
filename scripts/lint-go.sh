#!/bin/sh
# shellcheck disable=SC2154 # staged_* are set by enter_staged_tree (scripts/staged-tree.sh)
# golangci-lint analyzes packages, not files: lint the directories of the
# staged files, so pre-existing debt elsewhere in the repository cannot block
# a commit that never touched it, plus the directories that lost a .go file,
# whose remaining files may still use what it defined. Lint them as staged, in
# the copy enter_staged_tree (scripts/staged-tree.sh) builds, not as they sit
# in the working tree, where the package's other files may be mid-edit.
#
# lefthook leaves deleted files out of {staged_files} and skips a job left
# with none, so a commit whose only Go change is a deletion (or a rename to a
# name without .go) runs this as "lint-go --deletions", from a job with no file
# template and no glob, which lefthook runs for every commit. That run lints
# the directories that lost a .go file, and only when no .go file is added or
# modified: otherwise the job with the files runs and lints them as well.
#
# Run golangci-lint from *inside* each directory rather than passing "./$dir"
# from the repo root: golangci-lint needs a module context (a go.mod at or above
# its working directory). A repo whose Go code lives in nested modules (e.g.
# packages/custom/<tool>/ each with its own go.mod) has no go.mod at the root,
# so "golangci-lint run ./packages/custom/tool" fails with "no go files to
# analyze". cd'ing in first lets it find the module that owns the staged file.
#
# What golangci-lint and go find by location is looked up as the working tree
# would look it up, from the package's directory there, then pointed into the
# copy:
#   - the config golangci-lint would find there (.golangci.* in the directory or
#     a parent, else in $HOME): the copy's version when the file is staged,
#     else the working-tree file (an untracked one, one in a parent directory,
#     or where a symlink leads) placed at its own path under $staged_root, so
#     that it lies relative to the copy where it lies relative to the working
#     tree. golangci-lint matches a config's path rules against paths relative
#     to the config's directory: read where it was, the config met the copy's
#     files by their cache path, so an exclusion stopped applying and a
#     path-except started hiding findings. --no-config when there is none, so
#     nothing above the copy can supply one;
#   - the go.work `go env GOWORK` names: the copy's version, carried over when
#     git does not track it, or a rewritten one for a workspace outside the
#     repository; GOWORK=off when there is none;
#   - relative `replace` and `use` paths that leave the repository or name a
#     directory missing from the copy: rewritten to the working tree's path.
# Git-ignored build inputs of the linted packages and their in-repository
# dependencies, as `go list` reports them (generated code, cgo headers, the
# files //go:embed takes), are copied in from the working tree; that `go list`
# runs there, so it may neither write nor download. Untracked files git does
# not ignore stay out: those are work in progress. So do go's module and build
# caches, which go reads by absolute path, even where they lie in the
# repository.
#
# golangci-lint runs with GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE naming the
# repository, the copy and the copy's own index, so new-from-rev and
# new-from-merge-base can diff; the real index is never named. The go command
# it runs gets none of them: go fetches a module missing from the module cache
# with git, in a repository of its own. golangci-lint's cache is this hook's
# own: it records absolute paths, and the user's shared cache would carry the
# copy's paths into editor and manual runs.
#
# `go` itself comes from the project's toolchain on PATH, not from
# runtimeInputs: golangci-lint loads packages through it, and the project's
# Go version, not this flake's, decides what compiles.
#
# --fix=false: with `issues.fix: true` in its config, golangci-lint would fix
# the copy, which is thrown away, and stop reporting what it fixed.
[ "$#" -gt 0 ] || exit 0
# Read from the real index, before enter_staged_tree leaves the repository.
lg_deleted=$(git diff --cached --name-only --relative --no-renames --diff-filter=D -z -- '*.go' |
  xargs -0 -r dirname --)
if [ "$1" = --deletions ]; then
  # Run for every commit, Go or not: with no .go file deleted there is nothing
  # to lint, and no go is needed.
  [ -n "$lg_deleted" ] || exit 0
  # Whether lefthook runs the job with the files for this commit: its file
  # list, ACMR from the top, through the job's glob, which lefthook matches
  # ignoring case. A pattern still, under `git --literal-pathspecs commit`:
  # staged-tree.sh, which comes first, unsets GIT_LITERAL_PATHSPECS.
  lg_changed=$(git diff --cached --name-only --diff-filter=ACMR -- ':(top,icase)*.go')
  [ -z "$lg_changed" ] || exit 0
  set --
fi
lg_tab=$(printf '\t')
# Field separator for records with empty fields: read collapses empty
# tab-separated fields, it does not collapse this one.
lg_us=$(printf '\037')
lg_nl='
'
for lg_f in "$@"; do
  case $lg_f in
    *"$lg_nl"*)
      echo "lint-go: newline in a staged path is unsupported; refusing to lint" >&2
      exit 1
      ;;
  esac
done
if ! command -v go >/dev/null 2>&1; then
  echo "lint-go: go is not on PATH; golangci-lint loads packages through the project's Go toolchain" >&2
  exit 1
fi

enter_staged_tree "$@"
lg_wt_real=$(cd -- "$staged_worktree" && pwd -P)

# lg_abs DIR PATH: PATH, absolute or relative to DIR, as a physical absolute
# path; fails when it does not exist.
lg_abs() { (cd -- "$1" && cd -P -- "$2" && pwd -P) 2>/dev/null; }

# lg_rel ABS: ABS relative to the working tree's top; fails when outside it.
lg_rel() {
  case $1 in
    "$staged_worktree"/*) printf '%s\n' "${1#"$staged_worktree"/}" ;;
    "$lg_wt_real"/*) printf '%s\n' "${1#"$lg_wt_real"/}" ;;
    *) return 1 ;;
  esac
}

# lg_in_copy ABS: the copy's counterpart of working-tree path ABS when the
# copy has it, else ABS.
lg_in_copy() {
  if [ "$1" = "$staged_worktree" ] || [ "$1" = "$lg_wt_real" ]; then
    printf '%s\n' "$staged_copy"
  elif lg_r=$(lg_rel "$1") && [ -e "$staged_copy/$lg_r" ]; then
    printf '%s\n' "$staged_copy/$lg_r"
  else
    printf '%s\n' "$1"
  fi
}

# lg_beyond REL: whether a directory above REL, a path relative to the top, is
# a symbolic link or the top of another repository (a submodule). git takes no
# such path for one of its own, and check-ignore aborts on it, leaving the rest
# of its input unread.
lg_beyond() {
  lg_a=$1
  while :; do
    case $lg_a in
      */*) lg_a=${lg_a%/*} ;;
      *) return 1 ;;
    esac
    if [ -L "$staged_worktree/$lg_a" ] || [ -e "$staged_worktree/$lg_a/.git" ]; then
      return 0
    fi
  done
}

# lg_relink FILE WTDIR: in FILE, a go.mod or go.work in the copy whose
# working-tree directory is WTDIR, point every relative replace (and use) path
# that leaves the repository, or names a directory the copy lacks, at the
# working tree's directory.
lg_relink() {
  case $1 in
    */go.work) lg_kind=work ;;
    *) lg_kind=mod ;;
  esac
  go "$lg_kind" edit -json "$1" | jq -r '
    (.Use[]? | ["use", .DiskPath, ""]),
    (.Replace[]? | ["replace", .New.Path,
      (.Old.Path + (if .Old.Version then "@" + .Old.Version else "" end))])
    | select(.[1] | test("^\\.\\.?/")) | @tsv' |
    while IFS="$lg_tab" read -r lg_what lg_path lg_old; do
      lg_target=$(lg_abs "$2" "$lg_path") || continue
      case $lg_target in
        "$lg_wt_real" | "$lg_wt_real"/*) [ ! -e "${1%/*}/$lg_path" ] || continue ;;
      esac
      case $lg_what in
        use) go work edit -dropuse="$lg_path" -use="$lg_target" "$1" ;;
        replace) go "$lg_kind" edit -replace="$lg_old=$lg_target" "$1" ;;
      esac
    done || true
}

# lg_workspace SRC OUT: OUT, a go.work equal to SRC (a workspace outside the
# repository) except that the modules the copy holds come from the copy.
lg_workspace() {
  go work edit -json "$1" >"$staged_scratch/gowork.json" || return 1
  printf 'go %s\n' "$(jq -r '.Go // "1.22"' "$staged_scratch/gowork.json")" >"$2"
  jq -r '
    (if .Toolchain then ["toolchain", .Toolchain, "", ""] else empty end),
    (.Godebug[]? | ["godebug", .Key + "=" + .Value, "", ""]),
    (.Use[]? | ["use", .DiskPath, "", ""]),
    (.Replace[]? | ["replace", .New.Path,
      (.Old.Path + (if .Old.Version then "@" + .Old.Version else "" end)),
      (.New.Version // "")])
    | join("\u001f")' "$staged_scratch/gowork.json" |
    while IFS="$lg_us" read -r lg_what lg_path lg_old lg_ver; do
      case $lg_what in
        toolchain) go work edit -toolchain="$lg_path" "$2" ;;
        godebug) go work edit -godebug="$lg_path" "$2" ;;
        *)
          if [ -z "$lg_ver" ] && lg_target=$(lg_abs "${1%/*}" "$lg_path"); then
            lg_path=$(lg_in_copy "$lg_target")
          fi
          if [ "$lg_what" = use ]; then
            go work edit -use="$lg_path" "$2"
          else
            go work edit -replace="$lg_old=$lg_path${lg_ver:+@$lg_ver}" "$2"
          fi
          ;;
      esac
    done
  if [ -f "$1.sum" ]; then cp -- "$1.sum" "$2.sum"; fi
}

# lg_golist DIR: in DIR, the files go builds or embeds for the packages in the
# NUL-separated directories on stdin and for their dependencies, one
# "dir<TAB>file" line each: file is relative to the package's dir, except for
# the test main go generates in its build cache, which is absolute. DIR is in
# the working tree, where nothing may change: with -mod=mod from GOFLAGS, go list
# added requirements to go.mod and go.sum there (which a commit staging go.mod
# then recorded), downloading modules to find them. So $lg_mod (below) in place
# of that -mod, and no downloads at all: GOPROXY=off, and GONOPROXY=none, or a
# private module (GOPRIVATE) would still be looked up over https.
# $d is a Go template variable, not a shell one.
# shellcheck disable=SC2016
lg_tmpl='{{if not .Standard}}{{$d := .Dir}}'
for lg_field in GoFiles CgoFiles CFiles CXXFiles MFiles HFiles FFiles SFiles SwigFiles SwigCXXFiles SysoFiles \
  TestGoFiles XTestGoFiles EmbedFiles TestEmbedFiles XTestEmbedFiles; do
  lg_tmpl="$lg_tmpl{{range .$lg_field}}{{\$d}}$lg_tab{{.}}$lg_nl{{end}}"
done
lg_tmpl="$lg_tmpl{{end}}"
lg_golist() { (cd -- "$1" && GOPROXY=off GONOPROXY=none xargs -0 go list ${lg_mod:+"$lg_mod"} -e -deps -test -f "$lg_tmpl") 2>/dev/null || true; }

# lg_config_for DIR: the config golangci-lint finds when run in working-tree
# DIR: .golangci.{yml,yaml,toml,json} there or in a parent, up to /, else in
# $HOME. Looked up here rather than through `golangci-lint config path`,
# which costs a golangci-lint start per directory.
lg_config_for() {
  lg_d=$1
  while :; do
    for lg_n in .golangci.yml .golangci.yaml .golangci.toml .golangci.json; do
      if [ -f "$lg_d/$lg_n" ]; then
        printf '%s\n' "$lg_d/$lg_n"
        return
      fi
    done
    case $lg_d in
      / | '') break ;;
    esac
    lg_d=${lg_d%/*}
    [ -n "$lg_d" ] || lg_d=/
  done
  for lg_n in .golangci.yml .golangci.yaml .golangci.toml .golangci.json; do
    if [ -n "${HOME:-}" ] && [ -f "$HOME/$lg_n" ]; then
      printf '%s\n' "$HOME/$lg_n"
      return
    fi
  done
}

# lg_config_in_copy CONFIG: the file to give golangci-lint for CONFIG, a config
# lg_config_for found: the copy's version when the copy has one, else what
# CONFIG resolves to (golangci-lint resolves symlinks in the config's path),
# copied to that same path under $staged_root unless the copy holds it.
lg_config_in_copy() {
  if lg_r=$(lg_rel "$1") && [ -f "$staged_copy/$lg_r" ]; then
    printf '%s\n' "$staged_copy/$lg_r"
    return
  fi
  lg_real=$(readlink -f -- "$1") || return
  if [ ! -e "$staged_root$lg_real" ]; then
    mkdir -p -- "$staged_root${lg_real%/*}" && cp -- "$lg_real" "$staged_root$lg_real" || return
  fi
  printf '%s\n' "$staged_root$lg_real"
}

{
  for lg_f in "$@"; do dirname -- "$lg_f"; done
  if [ -n "$lg_deleted" ]; then printf '%s\n' "$lg_deleted"; fi
} | sort -u >"$staged_scratch/dirs"

# One record per package directory: dir, then what the working tree resolves
# there: GOMOD, GOWORK and the golangci-lint config (empty when none).
: >"$staged_scratch/plan"
while IFS= read -r lg_dir; do
  lg_has_go=false
  for lg_g in "$lg_dir"/*.go; do
    if [ -e "$lg_g" ]; then lg_has_go=true; fi
    break
  done
  [ "$lg_has_go" = true ] || continue
  lg_wt=$staged_worktree/$staged_prefix$lg_dir
  [ -d "$lg_wt" ] || lg_wt=$staged_worktree
  # The trailing "x" keeps an empty last line from being trimmed away.
  lg_env=$(cd -- "$lg_wt" && go env GOMOD GOWORK && echo x) || lg_env=$lg_nl${lg_nl}x
  lg_gomod=${lg_env%%"$lg_nl"*}
  lg_rest=${lg_env#*"$lg_nl"}
  lg_gowork=${lg_rest%%"$lg_nl"*}
  lg_config=$(lg_config_for "$(cd -- "$lg_wt" && pwd)")
  printf '%s\037%s\037%s\037%s\037%s\n' "$lg_dir" "$lg_wt" "$lg_gomod" "$lg_gowork" "$lg_config" >>"$staged_scratch/plan"
done <"$staged_scratch/dirs"

# Git-ignored build inputs: files go builds for these packages and their
# dependencies that lie in the repository but are missing from the copy. One
# `go list` per module, run where that module is - and none at all unless git
# ignores something that could be one: a Go, C or assembly source, a go.work,
# or a directory inside one of these modules (it may hold a generated package).
cut -d "$lg_us" -f2,3 "$staged_scratch/plan" | awk -F "$lg_us" '{ print $2 FS $1 }' | sort -u >"$staged_scratch/groups"
cut -d "$lg_us" -f2,3 "$staged_scratch/plan" | while IFS="$lg_us" read -r lg_wt lg_gomod; do
  case $lg_gomod in
    '' | /dev/null) lg_rel "$lg_wt" || printf '\n' ;;
    *) lg_rel "${lg_gomod%/*}" || printf '\n' ;; # the top itself
  esac
done | sort -u >"$staged_scratch/roots"
GIT_DIR=$staged_git_dir GIT_WORK_TREE=$staged_worktree git -C "$staged_worktree" \
  ls-files -z --others --ignored --exclude-standard --directory >"$staged_scratch/ignored"
lg_suspect=$(LC_ALL=C awk '
  FILENAME == ARGV[1] { roots[n++] = $0; next }
  /\.(go|c|cc|cpp|cxx|h|hh|hpp|hxx|m|s|S|sx|f|F|for|f90|swig|swigcxx|syso)$|(^|\/)go\.work(\.sum)?$/ { hit = 1; exit }
  /\/$/ {
    for (i = 0; i < n; i++)
      if (roots[i] == "" || index($0, roots[i] "/") == 1) { hit = 1; exit }
  }
  END { print hit ? "yes" : "no" }' "$staged_scratch/roots" RS='\0' "$staged_scratch/ignored")
[ "$lg_suspect" = yes ] || : >"$staged_scratch/groups"
# -mod=readonly when GOFLAGS asks for -mod=mod (the last -mod= wins, as in go).
# Any other mode only reads: vendor, readonly, or go's default, which picks one
# of the two. GOFLAGS as `go env` sees it, so a `go env -w` setting counts; a
# flag, unlike an empty GOFLAGS, overrides that setting. Read from /, since
# GOFLAGS does not depend on the directory, and neither do go's caches (below).
lg_mod=""
lg_caches=""
if [ -s "$staged_scratch/groups" ]; then
  lg_mod=$( (cd / && go env GOFLAGS) | awk '
    { for (i = 1; i <= NF; i++) if ($i ~ /^--?mod=/) m = $i }
    END { if (m ~ /=mod$/) print "-mod=readonly" }') || lg_mod=-mod=readonly
  lg_caches=$(cd / && go env GOMODCACHE GOCACHE) || lg_caches=""
fi
# Into missing: each file go lists that lies in the repository, as a path
# relative to the top, where the copy lacks it and git takes it for a path of
# its own (lg_beyond). Never one in go's module or build cache, which go reads
# by absolute path even where it lies in the repository (direnv's `layout go`
# puts GOPATH there): a module cache is thousands of read-only files, and the
# test main of a package with tests is in the build cache.
{
  lg_root=""
  while IFS="$lg_us" read -r lg_gomod lg_wt; do
    case $lg_gomod in
      '' | /dev/null)
        printf '%s\0' "$lg_wt" | lg_golist "$lg_wt"
        continue
        ;;
    esac
    if [ "${lg_gomod%/*}" != "$lg_root" ]; then
      if [ -n "$lg_root" ]; then lg_golist "$lg_root" <"$staged_scratch/group"; fi
      lg_root=${lg_gomod%/*}
      : >"$staged_scratch/group"
    fi
    printf '%s\0' "$lg_wt" >>"$staged_scratch/group"
  done <"$staged_scratch/groups"
  if [ -n "$lg_root" ]; then lg_golist "$lg_root" <"$staged_scratch/group"; fi
} | lg_caches=$lg_caches lg_top=$staged_worktree lg_top_real=$lg_wt_real LC_ALL=C awk '
  BEGIN {
    n = split(ENVIRON["lg_caches"], cache, "\n")
    top = ENVIRON["lg_top"] "/"
    real = ENVIRON["lg_top_real"] "/"
  }
  {
    t = index($0, "\t")
    file = substr($0, t + 1)
    path = (file ~ /^\//) ? file : substr($0, 1, t - 1) "/" file
    for (i = 1; i <= n; i++)
      if (cache[i] ~ /^\// && index(path, cache[i] "/") == 1) next
    if (index(path, top) == 1) print substr(path, length(top) + 1)
    else if (index(path, real) == 1) print substr(path, length(real) + 1)
  }' | sort -u | while IFS= read -r lg_r; do
  if [ -f "$staged_worktree/$lg_r" ] && [ ! -e "$staged_copy/$lg_r" ] && ! lg_beyond "$lg_r"; then
    printf '%s\0' "$lg_r"
  fi
done >"$staged_scratch/missing"
: >"$staged_scratch/carry"
if [ -s "$staged_scratch/missing" ]; then
  # Only what git ignores: an untracked file it does not ignore is unfinished
  # work. check-ignore exits 1 when it ignores none of them, and above that
  # when it fails, which it does at the first path it refuses.
  lg_rc=0
  GIT_DIR=$staged_git_dir GIT_WORK_TREE=$staged_worktree git -C "$staged_worktree" \
    check-ignore --stdin -z <"$staged_scratch/missing" >"$staged_scratch/carry" || lg_rc=$?
  if [ "$lg_rc" -gt 1 ]; then
    echo "lint-go: git check-ignore failed, so git-ignored files the build needs may be missing from the copy" >&2
  fi
fi
# Plus an in-repository go.work and its go.work.sum the copy lacks, ignored or
# not: Go's advice is not to commit them, so they are rarely tracked.
cut -d "$lg_us" -f4 "$staged_scratch/plan" | sort -u | while IFS= read -r lg_gowork; do
  if lg_r=$(lg_rel "$lg_gowork") && [ -f "$lg_gowork" ] && [ ! -e "$staged_copy/$lg_r" ]; then
    printf '%s\0' "$lg_r"
    if [ -f "$lg_gowork.sum" ]; then printf '%s\0' "$lg_r.sum"; fi
  fi
done >>"$staged_scratch/carry"
if [ -s "$staged_scratch/carry" ]; then
  (cd -- "$staged_worktree" && xargs -0 cp --parents --no-dereference --preserve=mode -t "$staged_copy" --) <"$staged_scratch/carry"
  lg_n=$(tr -cd '\0' <"$staged_scratch/carry" | wc -c)
  # awk reads to the end; `| head` exits early, and under pipefail the writer it
  # leaves without a reader fails the hook.
  lg_names=$(LC_ALL=C awk 'BEGIN { RS = "\0" } NR <= 3 { printf "%s ", $0 }' "$staged_scratch/carry")
  echo "lint-go: using $lg_n untracked file(s) from the working tree: $lg_names" >&2
fi

# Point what leaves the copy back at the working tree, once per go.mod/go.work.
cut -d "$lg_us" -f3,4 "$staged_scratch/plan" | tr "$lg_us" '\n' | sort -u | while IFS= read -r lg_file; do
  case $lg_file in
    '' | off | /dev/null) continue ;;
  esac
  if lg_r=$(lg_rel "$lg_file") && [ -f "$staged_copy/$lg_r" ]; then
    lg_relink "$staged_copy/$lg_r" "$(dirname -- "$lg_file")"
  fi
done

# golangci-lint finds go through a shim that drops GIT_DIR, GIT_WORK_TREE and
# GIT_INDEX_FILE, which golangci-lint itself gets (below). go fetches a module
# missing from the module cache with git, in a bare repository it creates with
# `git init --bare`: with them set, that git refused to run, and with GIT_DIR
# alone it would have turned this repository bare.
lg_go=$(command -v go | awk '{ gsub(/\047/, "\047\\\047\047"); printf "\047%s\047", $0 }')
mkdir -m 700 -- "$staged_scratch/bin"
# shellcheck disable=SC2016
printf '#!/bin/sh\nunset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE\nexec %s "$@"\n' "$lg_go" >"$staged_scratch/bin/go"
chmod 700 -- "$staged_scratch/bin/go"

lg_failed=0
lg_n=0
while IFS="$lg_us" read -r lg_dir lg_wt lg_gomod lg_gowork lg_config; do
  case $lg_gowork in
    '' | off) lg_gowork=off ;;
    *)
      if lg_r=$(lg_rel "$lg_gowork"); then
        lg_gowork=$staged_copy/$lg_r
      else
        lg_n=$((lg_n + 1))
        lg_ws=$staged_scratch/workspace.$lg_n/go.work
        mkdir -p -- "${lg_ws%/*}"
        lg_workspace "$lg_gowork" "$lg_ws"
        lg_gowork=$lg_ws
      fi
      ;;
  esac
  if [ -z "$lg_config" ]; then
    lg_config=--no-config
  elif lg_placed=$(lg_config_in_copy "$lg_config"); then
    lg_config=--config=$lg_placed
  else
    echo "lint-go: could not place $lg_config beside the copy of the staged tree" >&2
    lg_failed=1
    continue
  fi
  if ! (
    cd -- "$lg_dir" &&
      PATH=$staged_scratch/bin:$PATH GOWORK=$lg_gowork GOLANGCI_LINT_CACHE=$staged_cache/golangci-lint \
        GIT_DIR=$staged_git_dir GIT_WORK_TREE=$staged_copy GIT_INDEX_FILE=$staged_index \
        golangci-lint run --fix=false "$lg_config" .
  ); then
    lg_failed=1
  fi
done <"$staged_scratch/plan"
exit "$lg_failed"
