# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A Nix flake that renders [lefthook](https://github.com/evilmartians/lefthook)
pre-commit hooks into a single committed config. See `README.md` for the
consumer-facing story; this file covers what you need to work *on* the flake.

## `git commit` exits 1 here — that is success

This repo dogfoods its own `auto-commit` hook, which splits one commit into one
commit per staged file and then cancels the umbrella commit. So a successful
commit reports failure and discards your commit message. Check `git log` (or the
hook's last line, `auto-commit: N commits made…`), not the exit code; if that
line says `nothing was committed and everything is still staged` (exit status 3
in lefthook's summary), nothing landed and `git commit` again retries.
`LEFTHOOK_EXCLUDE=auto-commit git commit -m "…"` gives a single normal commit
instead.

Committing also runs this repo's formatters and linters on the staged files and
**blocks the commit** if they fail (`nixfmt`, `deadnix`, `statix` for Nix;
`shfmt --language-dialect auto`, `shellcheck` for `scripts/*.sh`). Run them
before committing rather than discovering it mid-hook.
`auto` reads the shebang, so these `#!/bin/sh` scripts are still held to POSIX —
it exists so a *consumer's* `#!/bin/bash` script is not rejected outright.

## Commands

```sh
nix flake check                                    # eval + every check below
nix build .#checks.x86_64-linux.lefthook-config    # just that check
nix build -L .#checks.x86_64-linux.behaviour-auto-commit   # tests/auto-commit.sh
nix build -L .#checks.x86_64-linux.behaviour-pathspec-guard   # tests/pathspec-guard.sh
nix build -L .#checks.x86_64-linux.behaviour-staged-tree   # tests/staged-tree.sh
nix build -L .#checks.x86_64-linux.behaviour-security-gitleaks   # tests/security-gitleaks.sh
nix build -L .#checks.x86_64-linux.behaviour-wire-repo   # tests/wire-repo.sh
nix build -L .#checks.x86_64-linux.lefthook-hooks-own-config   # tests/hooks-check.nix
nix build .#devShells.x86_64-linux.default.lefthookConfig  # render the config
nix develop                                        # installs hooks; creates lefthook-generated.yml only if MISSING, else warns on drift
lefthook-regen                                     # (inside the shell) rewrite lefthook-generated.yml after hooks.nix/mk-shell.nix changes

# Regenerate the committed config WITHOUT entering the shell (which installs
# hooks):
install -m 644 "$(nix build --no-link --print-out-paths \
  .#devShells.x86_64-linux.default.lefthookConfig)" lefthook-generated.yml

# The scaffolder. Never against this checkout: it would rewrite and `git add`
# the committed config with whatever lanes you passed. Use a throwaway repo.
d=$(mktemp -d) && git -C "$d" init -q && (cd "$d" && nix run /home/charles/lefthook#init -- --lanes nix,shell)
```

`checks.lefthook-config` asserts the **committed** `lefthook-generated.yml`
matches what the flake renders, and that lefthook can load it;
`checks.lefthook-all-lanes` renders *every* lane (the dev shell only covers
four) and forces each hook's tools to instantiate, so a nixpkgs bump that
breaks a tool this repo never builds fails here rather than at a consumer.
Neither check enforces `min_version` or `assert_lefthook_installed` — `lefthook
dump` merges without applying them; both bite at `run` time.

`checks.behaviour-*` run `tests/<name>.sh` in the build sandbox: real git and
lefthook, no network, a throwaway HOME, real commits driven through the built
wrappers. Each test prints `ok`/`UNEXPECTED` against an expectation; `expect
FAIL` records a known, documented limitation, so a check goes red both when a
behaviour regresses and when a limitation is lifted without its documentation
being updated — flip the expectation and fix the prose in the same change.
Each file ends with `summary N`, N the number of results it records: a
subshell that dies early records nothing, and the check stayed green. Adding
or removing a test changes N. `tests/lib.sh` has the helpers, including
`instrument`, a git shim that runs a snippet after the Nth call of a git
subcommand (found past `-c`/`-C`): the deterministic way to stage "another
terminal acted mid-run". Count every call of that subcommand the wrapper
makes, `--prepare` pass included, and assert `fired`, or a test whose
injection point moved passes on nothing. A behavioural change to a wrapper
lands with a test here.

Anything a sandbox cannot show (the git shim, a real terminal ^C, network
tools) is still verified by driving real commits in throwaway repos under the
scratchpad — never in this checkout, which has live hooks.

## Architecture

Data flows in one direction:

```
hooks.nix  ──►  mk-shell.nix  ──►  lefthook-generated.yml (committed)
(ordered      (module + renderer)
 data)
```

- **`hooks.nix`** — every hook as data. Each entry declares exactly one of
  `lane` + `order` / `standalone` / `guard` / `finalize`, the `tools` it needs
  on `PATH`, and `jobs` written as **verbatim lefthook job attrsets** (`name`,
  `run`, `glob`, `stage_fixed`, `skip`, …) emitted into the YAML as-is. Adding
  a hook should touch only this file.
- **`wrappers.nix`** — every script with real shell logic, built with
  `writeShellApplication` (strict bash, pinned `runtimeInputs`, shellcheck at
  build time): the `auto-commit`, `pathspec-guard`, `lint-*` and
  `security-opentofu` hooks, plus the non-hook `wire-repo`.
  `scripts/staged-tree.sh` is not a wrapper: it is prepended to `lint-go`,
  `lint-opentofu` and `security-opentofu` (see the invariants below), which
  share its runtime inputs (`stagedTreeInputs`: git, flock, findutils, gawk,
  coreutils). Imported by `hooks.nix`, `flake.nix`, `mk-shell.nix` and
  `init.nix`. `runtimeInputs` must list *every* command the script calls — the
  ambient `PATH` stays in place, so an omission resolves silently from whatever
  the commit environment happens to have. Note `cmp` is in **diffutils**, not
  coreutils. The one deliberate exception is `go` for `lint-go`: golangci-lint
  loads packages through the project's own toolchain, whose version decides what
  compiles.
- **`scripts/wire-repo.sh`** — the shared "point this repo at a rendered
  config" step: writes `lefthook-generated.yml`, seeds `lefthook.yml`, keeps
  `lefthook-local.yml` out of the index, then `lefthook install`. Both the dev
  shell's `shellHook` and `lefthook-init` call it, so changing either path means
  changing this file. The shellHook passes `--warn-drift`: an existing
  generated config is never rewritten on entry, only created when missing —
  drift gets a warning naming `lefthook-regen` (the same script in write mode,
  on the shell `PATH`). `lefthook-init` and `lefthook-regen` use write mode.
  Whatever it writes it names ("wrote … commit it"), in either mode. It seeds
  `lefthook.yml` only where the repository has no main config under any name
  lefthook loads, and warns when the one it has does not extend the generated
  file. `lefthook-init` reads that same config to say whether the generated
  hooks are active.
- **`mk-shell.nix`** — an `evalModules` module plus the renderer. Exposes
  `mkShell` (dev shell), `toolchain` (the packages, for global installs) and
  `toolchainEnv` (the same packages as one `buildEnv`, for `nix profile
  install`); all take the same arguments, and `toolchainEnv` also `only`, the
  programs to keep, matched against each package's `meta.mainProgram` (a name
  none provides throws). The shell's passthru carries `lefthookConfig` (the
  render) and `mkConfigCheck` (the drift check, consumed by this flake's own
  `checks.lefthook-config` and exportable to consumers), plus `mkHooksCheck`
  (the enabled hooks over every tracked file of `src` in the build sandbox,
  minus auto-commit, pathspec-guard (it commits nothing) and the network-bound
  lint-go, lint-opentofu and security-opentofu; dogfooded as
  `checks.lefthook-hooks`). Both checks read the repository from
  `src.sourceInfo` when `src` has one, because a flake in a subdirectory gets a
  `self` rooted there while wire-repo writes at the repository's top level.
  `mkHooksCheck` wires its copy of `src` with wire-repo (`--no-install`), so it
  runs `src`'s own main config, as its commits load it, and gets the stub
  `lefthook.yml` only where `src` has none under any name. Written regardless,
  the stub dropped a consumer's excludes and jobs and shadowed a
  `.lefthook.yml`. `checks.lefthook-hooks-own-config` (tests/hooks-check.nix)
  pins it.
- **`init.nix` / `scripts/init.sh`** — the `lefthook-init` scaffolder, for
  repos with no dev shell. gitleaks is on by default, auto-commit is opt-in
  (`--auto-commit`; `--no-auto-commit` is still accepted). It ends by checking
  that every command the config's `run:` lines call is on `PATH`, plus `go`
  when lint-go is in. For what is missing it prints a `toolchainEnv { …;
  only = [ … ]; }` install command, with lefthook added when the runner was the
  fallback. The command reads the flake that ran (`path:$SELF`), never
  `github:`. Only the missing programs: a package the profile already holds
  (lefthook, usually) collides with its copy and fails the whole install. `go`
  is only named, since it comes from the project.

Ordering is data, never attrset order: `guard` jobs come first, then any
`prepareJobs`, lanes run in parallel under a `main` job, jobs inside a lane
are piped by `order` (format → lint → security), `finalize` jobs follow
`main`, and `pre-commit` is itself piped so a failing lane blocks
`auto-commit`. With more than one hook in the `guard` or `finalize` role, each
must declare an `order` (validated). A guard is on by default wherever another
enabled hook has a job with `stage_fixed`; guards are left out of that test,
so a guard's default never depends on itself.

## Invariants that break things when violated

- **`run` uses bare tool names**, never store paths. That is what makes the
  generated config machine-independent and therefore committable. Tools resolve
  from the dev-shell `PATH` (or a global install).
- **`lefthook-generated.yml` is committed and must match what the flake
  renders.** After changing `hooks.nix` or `mk-shell.nix`, regenerate it with
  `lefthook-regen` (shell entry only *warns* on drift, it does not rewrite) or
  `nix flake check` fails on the `cmp`.
- **`min_version` must not exceed the lefthook that will *run* the hook.** A
  config demanding a newer lefthook than the runner fails hard at commit time —
  this has bitten repeatedly when a consumer's nixpkgs is older than this
  flake's. It defaults to `featureFloor` (a true lower bound every supported
  runner meets), **not** `pkgs.lefthook.version`, which would ratchet the demand
  up on every `nix flake update`. `lefthook-init` stamps that same floor —
  having first gated the runner it found against it — rather than the local
  version, which would ratchet the demand up for everyone else on the team.
  `mk-shell.nix` asserts `>= featureFloor` on render, so an explicit too-low
  value throws. The value itself lives in `feature-floor.nix`, imported by both
  sides so they cannot drift. The floor is **1.13.0**: `jobs:` needs 1.10.0,
  but below 1.13.0 the parallel lanes' post-format `git add` calls race
  `.git/index.lock` and `stage_fixed` silently drops the reformatted blobs (a
  warning, exit 0); older still, the runner ignores every job and exits 0. Both
  leave the repo looking hooked while checking nothing. `scripts/init.sh`
  enforces the same floor on the runner.
- **`{staged_files}` stays unquoted in `run`.** lefthook shell-escapes each
  path before substituting; wrapping it in quotes of your own strips that
  escaping and turns a filename like `$(…).nix` into command injection. Put
  `--` before it instead, so a file named like a flag stays a file — except
  for `zig fmt`, which rejects `--`, and the wrapper scripts (`lint-*`,
  `security-opentofu`), which would receive it as their own first argument and
  add it themselves when calling the real tool.
- **`lanes` is all-or-nothing per lane**; opt a hook out with
  `hooks.<name>.enable = false`, which wins over what a lane implies.
- **`scripts/*.sh` need `#!/bin/sh`** even though `writeShellApplication`
  supplies its own shebang and the line is inert — without it shellcheck
  fails with SC2148. Keep them POSIX-clean: the shebang is what makes
  `shfmt --language-dialect auto` hold them to POSIX, so the repo's own hook and
  `shellcheck` pass.
- **They are written for `sh` but *run* under bash with `set -euo pipefail`.**
  That gap is where the bugs live, not in syntax. Two that bit:
  `cmd | grep -q pat` reads as *false* on a large input, because grep exits at
  the first match, the writer dies of SIGPIPE and `pipefail` propagates it —
  use `grep pat >/dev/null`, which reads to EOF. And a bare `dirname "$f"`
  failing on an odd filename aborts the whole pipeline rather than that one
  iteration.
- **No auto-fixer may outrank its own linter — why `shellharden` is gone.** It
  was removed from the shell lane on 2026-08-05 and must not be re-added. It
  rewrites `for x in $list` into `for x in "${list[@]}"`; on a plain string in a
  `#!/bin/bash` file that goes from N iterations to **one**, and the damage is
  invisible to every guard in the lane — `shellcheck` exits 0 on the result
  (it is a bash array, perfectly legal), so `stage_fixed: true` `git add`s the
  rewrite and the commit succeeds with silently changed behaviour. Reproduce
  with a three-word `list=` and a `for x in $list` loop. Note the construct it
  breaks is one `shellcheck` deliberately *permits* (intentional word
  splitting), so this was its only unique contribution to the lane.
  `shellcheck` remains the detector for what actually matters (SC2086 → exit 1,
  commit blocked), so nothing was lost. `--check` is not a substitute: it prints
  **no output**, only exit 2. The general rule this encodes: a tool that mutates
  source *and* auto-stages the result must be strictly more trustworthy than the
  linter that follows it, because anything it breaks past that linter's notice
  lands in history unreviewed. `shfmt` clears that bar; `shellharden` did not.
  It is still a fine thing to run **by hand** — it just cannot hold the pen on a
  commit. Its heredoc rewrite (inserting literal quotes into heredoc bodies) and
  the `${v%% *}` / `${v#* }` iteration idiom in `scripts/init.sh` are unaffected;
  that idiom is still correct POSIX and worth keeping.
- **Package-level checks read the staged tree, never the working tree.**
  `lint-go`, `lint-opentofu` and `security-opentofu` analyze a whole package or
  module, so reading it from the worktree also took in the unstaged edits and
  untracked files of the files *not* being committed: another session's
  half-written file failed a commit that did not include it. Each calls
  `enter_staged_tree` (`scripts/staged-tree.sh`), which builds a copy of the
  staged tree and `cd`s into it. What holds it together:
  - **One stable directory per working tree and hook, never a fresh random
    one, never `/tmp`.** The path is
    `${XDG_CACHE_HOME:-$HOME/.cache}/lefthook/staged/<hash of the worktree's git dir>/<hook>/`,
    every level 0700, owned by the user, and refused otherwise.
    - golangci-lint caches findings by content but records absolute paths.
      From a new path on each run, a retried commit replayed findings into the
      deleted copy: `//nolint` and generated-file exclusions stopped applying,
      the commit stayed blocked, and the poisoned entries reached the user's
      shared cache (editor runs).
    - The go build cache also missed on every run.
    - Each linked worktree gets its own (`--absolute-git-dir`, not the common
      dir). Sharing one, linked worktrees shared golangci-lint's cache while
      their copies lay at different paths, and a linked worktree linting what
      the main one had just linted was handed its findings: the replay above
      again (2026-10-21 panel). The main worktree's git dir is the common dir,
      so its directory did not move.
    - `/tmp` is shared, and go and golangci-lint read go.work and .golangci.*
      from every parent directory.
    - The copy itself is `<hook>/tree` followed by the worktree's absolute
      path (`staged_root` + `staged_worktree`), so a file found above or
      outside the repository can be put at the same place relative to the
      copy. golangci-lint matches a config's path rules against paths relative
      to the config's directory, symlinks resolved. A config read where it
      lay, outside the copy, met the copy's files by their cache path
      (`../../.cache/lefthook/…`): an exclusion stopped applying and blocked
      the commit, and a `path-except` hid findings.
  - **A flock serializes it.** The lock is `<hook>/lock`, taken with the
    portable `flock` package. The tree is rebuilt on each run and removed on
    exit.
    - lefthook SIGKILLs a job's process group on ^C, so no trap runs then. The
      next run of that hook reclaims the copy, and every run deletes other
      copies idle for more than 60 minutes whose lock `flock -n` can take.
    - Both also delete the copy's `index.lock`, which a git killed mid-write
      leaves behind; without that, every later run exited 128.
    - The copy's directories are made writable: `staged_copy_in` creates them
      before its cp batch. `cp --parents` gives a directory it creates the
      source's mode once the first file is in, so a read-only directory of the
      worktree took one file and refused the next, tracked files and lint-go's
      carry alike: the check failed. One that exists it leaves alone, given no
      `--preserve=mode`, with which cp means to give it the source's mode too.
    - Every removal goes through `_st_reclaim`, which makes the copy writable
      when a plain `rm -rf` fails: `staged_carry` copies a directory whole,
      modes included. A copy holding a read-only directory failed the exit
      trap, and with it a check that had passed, and then failed the reclaim
      of every later run. The exit trap never fails the check.
    - Never replace the lock with mkdir: a SIGKILL would leave it held forever.
  - **Worktree form where the worktree is clean, the staged blob where it is
    not.** One cp batch and one checkout-index, never a process per file.
    - Clean files are copied from the worktree: git-crypt plaintext, smudged
      LFS, the user's line endings.
    - Changed, missing, skip-worktree and assume-unchanged files (every file
      under core.ignoreStat) are checked out with `--attr-source=<staged tree>`
      and no filter driver: `_st_unfiltered` gives every `filter.<driver>` in
      the config an empty smudge and process and `required=false`. It uses
      `--config-env`, because `-c` ends the name at its first `=` and a
      driver's name may hold one. LFS fetched every object a sparse or partial
      clone never downloaded, so offline the commit failed. Such a blob stays
      as git stores it, an LFS pointer or git-crypt ciphertext: a git-crypt
      file with unstaged edits is linted encrypted (a test pins it).
    - The hook's own FILEs always come from the worktree when they are regular
      files on both sides. They carry the formatter's fix, which lefthook
      stages only after the hook; without it, format → lint fails on what
      gofumpt (`for i, _ := range`) or `tofu fmt` (`type = "string"`) just
      fixed.
    - Gitlinks are filled from the submodule's own objects at the recorded
      commit, with no filter driver either.
  - **The real index is never written.** The snapshot comes from a copy of the
    index, because write-tree takes index.lock. The dirty set comes from
    `GIT_OPTIONAL_LOCKS=0 git diff`.
  - **Resolve from the top, and fail without an index.** git hands the hook
    GIT_INDEX_FILE relative to the top (and resolves it so itself from any
    subdirectory), but lefthook runs a `root:` job in a subdirectory. Pinned to
    that directory, the index went missing, the copy came out empty and the
    check passed on nothing. So `enter_staged_tree` asks git for the top and
    `cd`s there first. Nothing changes directory again before GIT_DIR,
    GIT_WORK_TREE and GIT_INDEX_FILE are unset, so relative values resolve as
    git resolves them. A missing index exits 1. A `root:` job's files arrive
    as `./file`: the `./` is dropped before they are matched against the
    index.
  - **The appended script gets paths, not git env.** GIT_DIR, GIT_WORK_TREE and
    GIT_INDEX_FILE are unset; it receives `staged_worktree`, `staged_prefix`,
    `staged_root`, `staged_copy`, `staged_index`, `staged_git_dir`,
    `staged_cache` and `staged_scratch` instead. Each lint script carries a
    file-wide `shellcheck disable=SC2154` for them, because this repo's own
    hook runs shellcheck on each file alone.
  - **lint-go resolves by location as the worktree would**, then points into
    the copy.
    - It resolves the golangci-lint config, GOWORK, and relative replace/use
      paths that leave the repository.
    - A config the copy lacks (untracked, in a parent directory or `$HOME`, or
      reached through a symlink) is copied to `staged_root` + the path it
      resolves to (`lg_config_in_copy`), never read where it lies.
    - A commit whose only Go change is a deletion is linted by a second job,
      `lint-go-deletions` (`lint-go --deletions`). lefthook leaves deleted
      files out of `{staged_files}` and skips a job left with none; `files:`
      does not help, because lefthook drops a path the worktree lacks from
      `{files}` too. A job with no file template runs when anything staged,
      deletions included, matches its glob. It has no glob: lefthook lists a
      renamed file by its new name only, so `x.go` renamed to `x.go.orig`
      matched none. It runs for every commit, so with nothing to lint it
      exits before needing `go`. It also exits when the first job has linted
      the deleted files' packages. Run from the top, that job lints them as
      well. Once they pass, it writes HEAD and the staged entries
      (`git ls-files -s`), hashed, to `<git dir>/lefthook-lint-go-deletions`,
      and the second job skips while they match. A record, not a guess: it
      used to skip whenever a .go file was added or modified, taking that for
      a sign the first job would run. lefthook also leaves that job's files
      out for `exclude:` or a staged file the worktree lacks, and the deletion
      went unlinted. `tests/staged-tree.sh` commits through the real render
      (`LINT_GO_CONFIG`).
    - It carries in the git-ignored files that `go list -deps -test` reports,
      `//go:embed` targets (the `*EmbedFiles` fields) included. It skips
      `go list` when nothing ignored could be a build input.
    - Nothing in go's module or build cache (`go env GOMODCACHE GOCACHE`) is
      carried: go reads both by absolute path. direnv's `layout go` puts the
      module cache in the repository, where it is git-ignored. Copied in, it
      brought thousands of files, and its read-only directories with them.
    - The template prints `dir<TAB>file`, never `dir/file`. The test main of a
      package with tests is an absolute GOCACHE path, so `dir/file` named a
      path inside the repo that does not exist.
    - check-ignore aborts on the first path it refuses and reads no further,
      so it must only get paths it accepts. Paths outside the repo are dropped
      first, and so are those below a symlink or inside a submodule or another
      repository (`lg_beyond`). A failure above exit 1 is reported, not
      swallowed.
    - That `go list` runs in the worktree, so it must not write there or
      download: GOPROXY=off with GONOPROXY=none (GOPROXY=off alone still looks
      a GOPRIVATE module up over https), and `-mod=readonly` when GOFLAGS (as
      `go env` reads it, `go env -w` included) says `-mod=mod`, which let it
      add requirements to the worktree's go.mod for auto-commit to commit. A
      flag, because an empty GOFLAGS does not override a `go env -w` setting.
      Any other mode already only reads.
    - golangci-lint gets a hook-private GOLANGCI_LINT_CACHE, so its absolute
      paths never reach the user's cache.
    - GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE name the repo, the copy and the
      copy's index, so new-from-rev works.
    - The `go` that golangci-lint runs must not see them, so golangci-lint
      finds go through a shim in scratch that unsets all three. To fetch a
      module missing from the cache (a private one, by git), cmd/go creates a
      repository with `git init --bare`. That refuses a GIT_WORK_TREE, and the
      refusal blocked every commit until the module was cached. With GIT_DIR
      alone it would reinitialize the user's repository as bare. So never
      unset only some of them.
    - `go` is the one command it deliberately takes from the ambient PATH: the
      project's toolchain decides what compiles.
  - **OpenTofu.**
    - `.terraform/modules` is *copied* in: trivy does not follow a symlinked
      directory.
    - A relative tflint `plugin_dir` is rewritten to the worktree path, because
      tflint ranks it above TFLINT_PLUGIN_DIR.
    - That rewrite gives awk the `.tflint.hcl` on stdin, never as an operand:
      awk takes `env=prod/.tflint.hcl` for a variable assignment. It then read
      the loop's list of directories instead. The config came out empty or
      held the next directory's name, and that directory went unlinted.
    - security-opentofu skips other root modules file by file
      (`--skip-files <dir>/<subdir>/*.tf`). Never use `--skip-dirs`: it hid the
      called modules too, so nothing passed into a module was checked.
    - Those skip paths are named from the current directory, never from the
      scanned one: trivy resolves a relative skip path against the current
      directory first. `infra/*.tf`, meant for a root module at infra/infra,
      skipped infra's own files.
    - security-opentofu fails on "Failed to load module".
- **`auto-commit` cannot see `--amend` or `--fixup`.** The hook environment is
  byte-identical to a normal commit, so both get rewritten into new commits on
  top. There is no fix; `--no-verify` is the documented escape hatch.
- **`auto-commit` publishes all or nothing and never rewrites the real index
  mid-split.** Each per-file commit is built with `git commit-tree` from a
  private `GIT_INDEX_FILE` (`.git/lefthook-split.*/`); the branch moves once, at
  the end, with a compare-and-swap `git update-ref <ref> <new> <old>`, after
  re-checking that `HEAD` still points to that branch. Anything can hold
  `.git/index.lock` at any moment (a `git status` in another terminal, magit, a
  prompt); the old in-place split then failed partway and its restore wiped
  the staging. The snapshot is taken from a *copy* of the real index (even
  `write-tree` takes the lock). Do not reintroduce `git commit`, a `read-tree`
  or a per-path `update-index` on the real index. What holds the design
  together:
  - Nothing locks out a concurrent commit, checkout or reset, so the
    compare-and-swap is the guard: if the branch moved, or `HEAD` now points
    elsewhere, the split publishes nothing and exits 3. 1 means "split and
    committed", so a failure that would exit 1 before publishing (commit-tree
    does, when the signer refuses) exits 3 too.
  - The only write to the real index is the reconcile after publishing: one
    `update-index --index-info` bringing each path the split handled up to the
    entry `HEAD` now holds, but only where `HEAD` really holds it and the real
    entry is still the base or the snapshot entry (a folded formatter fix, or
    another process's `git reset`). Any other entry is a newer staging and is
    kept. A rewritten entry loses its stat data (git re-reads that one file);
    untouched entries keep it. No entry flagged assume-unchanged or
    skip-worktree is ever folded, so none loses its flag.
  - That write holds `index.lock` from its read to its write. Read outside the
    lock, a `git add` or a commit landing before the write was overwritten (the
    add undone, the commit reverted by the next one). It takes the lock as git
    does, an exclusive create (bash's noclobber), copies the index into it
    keeping the mtime (git's racy-entry check compares against it), runs
    `update-index` with `GIT_INDEX_FILE` on the lock file, and renames that
    over the index. A first look without the lock comes first, so when nothing
    needs writing the lock is never taken. It deletes `index.lock` only when
    it created it, never after the rename.
  - commit-tree runs no hooks and ignores `commit.gpgSign`: the split passes
    `-S` itself, and `prepare-commit-msg`/`post-commit` no longer run per file.
    It skips a path a formatter returned to its base content (no empty commit),
    and runs `git maintenance run --auto --detach` once after publishing, since
    the cancelled umbrella commit never does.
  - Fold candidates' worktree blobs are hashed in one `hash-object -w
    --stdin-paths` before the first commit; a path that is no longer a regular
    file in the worktree, or lies below a symlinked directory, keeps its staged
    blob.
  - A fold candidate is a path `--prepare` found clean, and clean means git
    compared it. `--prepare` lists the paths with unstaged changes, plus every
    entry `ls-files -v` flags (lowercase: assume-unchanged, `S`:
    skip-worktree), plus every staged path under core.ignoreStat. `git diff`
    alone never shows those, and their worktree file often holds a local-only
    edit: the fold committed it, unscanned by gitleaks. A list it cannot make
    is no list: the file goes, and nothing folds.
  - The loop must run in the main shell (reading a file, not a pipe): from a
    pipeline subshell a trap can delete the private index while git still
    reads it, and git takes a missing index for an empty one.

  Stopping before the publish (an error, ^C, TERM, SIGKILL, a refused
  signature) therefore leaves the repository exactly as it was. bash does not
  run an `EXIT` trap when it dies of a group `SIGINT`, so `INT`/`TERM`/`HUP` are
  trapped explicitly; lefthook SIGKILLs a job on ^C, so no trap runs there,
  which is why every run (the `--prepare` pass included) sweeps split dirs left
  idle for an hour. A SIGKILL in the instant between publishing and the
  reconcile leaves folded paths staged with their pre-format blobs (lefthook >=
  2.1.7 re-stages them itself when it survives); one during the reconcile's
  few milliseconds under the lock also leaves `index.lock` behind, as a killed
  git does, and git then names it for deletion.
- **`auto-commit` must pass through** when git is not operating on the real
  index (`GIT_INDEX_FILE` ending in `.lock`, i.e. `git commit -a` and pathspec
  commits), when a merge/squash-merge/cherry-pick/revert/rebase is in
  progress, and when a `commit-msg` or `prepare-commit-msg` hook is installed
  (found through `git rev-parse --git-path`, so `core.hooksPath` counts), whose
  checks the generated messages would bypass. Removing either of the first two
  guards silently corrupts history; all three are covered in
  `tests/auto-commit.sh`.
  - lefthook's own script for such a hook does not count when lefthook's merged
    config has no section for that hook. `lefthook dump`, run with the
    wrapper's own lefthook, decides; a dump that fails keeps the pass-through.
  - lefthook 1.13.0–2.0.15 install that script for prepare-commit-msg on every
    `lefthook install`, to keep the hooks in sync; 2.0.16+ install it when the
    config has no hooks. Nothing removes it, and it runs nothing. Counted as a
    message hook, it turned splitting off for good.
  - The script is recognized by its exact last line, in both forms the
    template has had: `call_lefthook run "<hook>" "$@"`, and
    `call_lefthook "run <hook> $@"` before 1.5.
- **Wrappers that pass git a pattern clear the pathspec variables;
  pathspec-guard and auto-commit keep them.** `git --literal-pathspecs commit`
  (magit's default) exports GIT_LITERAL_PATHSPECS to the hook. Under it
  lint-go's `*.go` patterns matched nothing, so a deletion went unlinted;
  check-ignore refused to run, so the git-ignored generated files a package
  needs were missing; and gitleaks' report named no file.
  `scripts/staged-tree.sh` (at its top level, so for lint-go, lint-opentofu and
  security-opentofu) and `scripts/security-gitleaks.sh` unset it, with
  GIT_GLOB_PATHSPECS, GIT_NOGLOB_PATHSPECS and GIT_ICASE_PATHSPECS.
  pathspec-guard keeps them: lefthook's own git calls inherit them, and the
  guard reads names as git will read them there. So does auto-commit, whose
  prepare pass calls the guard.
- **`pathspec-guard` refuses a staged name that would make git act on other
  files.** lefthook hands staged file names to `git add`/`git checkout` as
  pathspecs, ignored files included: `stage_fixed` adds with `--force`.
  Staging `g*.txt` also committed an ignored `gsecret.txt`. Refused:
  - A name starting with `:`, which is pathspec magic.
  - A name lefthook rewrites before calling git. It runs Go's
    `strings.TrimSpace` and `strconv.Unquote` on each line of
    `git diff --name-only --cached` (repository.go:484-489 in 2.1.5). A blank
    at either end, or backquotes or single quotes around the name, made it act
    on another file: for `gsecret.txt ` it formatted and staged the ignored
    `gsecret.txt`. Unicode white space counts too, since git leaves it unquoted
    under `core.quotePath=false`.
  - A name holding `*`, `?`, `[` or `\` (a lone `]` or braces are no pattern)
    that matches some other path. git decides, with
    `ls-files --cached --others` and no exclude options, which is what
    `add --force` matches. One call covers all such names; only when they
    match another path are halves of them asked again, down to the single
    names that do, to say what each matches. One call per name took 24 s for
    3,000 names; halving takes about 2·log₂ n calls per offending name. The
    other names checked do not count, since they are staged anyway. Route
    files such as `app/[id]/page.tsx` match only themselves; refusing every
    such name blocked each commit of them (2026-10-21 panel, 4/4 against).
  - Anything that cannot be checked; the guard inside auto-commit passed then.

  Where it runs:
  - It is the only hook in the `guard` role, rendered first wherever an
    enabled job sets `stage_fixed`: with no job that stages, lefthook hands
    names to git only for the set-aside, which no job can stop.
  - No `skip`: lefthook runs the formatters during merges and rebases too.
    auto-commit's prepare job, where the check used to live, is skipped there.
  - auto-commit's `--prepare` pass still calls it (the wrapper is in
    auto-commit's `runtimeInputs`), because a config rendered from 2026-08-15
    (1ea6ac8 added that pass) until the guard job existed starts with it. A
    config older than that has neither, and no guard until it is
    regenerated.
  - The render passes `--no-guard` to that pass, which leaves the check to
    the guard job alone: it runs once, and `hooks.pathspec-guard.enable =
    false` turns it off with auto-commit on too. A config rendered before the
    flag ran it twice (a `git diff --cached` and an awk; the backup below was
    copied once) and kept it on regardless.
  - `mkHooksCheck` excludes it: everything is staged there and nothing is
    committed, so a name it refuses would only fail the check.

  It also keeps lefthook's backup, its one write:
  - Before any job, when it sets the unstaged hunks of partially staged files
    aside, lefthook stashes every tracked change (`lefthook auto backup`, the
    same message from 1.13.4 through master). It drops the stash after the
    hook or, when putting the hunks back fails, at once or at the next commit
    that sets hunks aside (from 2.2.2 only its own).
  - When a formatter's fix lands on a line with a hunk set aside, that hunk
    is lost on every version. 2.1.7–2.1.15 first run `git checkout .`, so
    every tracked file's unstaged edit goes too; 2.1.16+ keep the other files,
    except with auto-commit (through 2.2.2), whose reconcile moved the index
    under lefthook's all-files patch. The stash was the only copy.
  - So the guard copies the newest stash entry, when it is lefthook's, to
    `refs/lefthook/backup` with `--create-reflog` (git logs no ref outside
    refs/heads, refs/remotes and refs/notes by default), unless the ref holds
    it already. A copy it cannot make blocks the commit. README.md has the
    recovery commands.
  - A file marked assume-unchanged has no copy: `git stash` leaves it out
    (`expect FAIL` K2).

  Details:
  - Names are read with `-z`: git C-quotes a name holding a tab or a newline,
    which hid a leading `:`.
  - It `cd`s to the top first, because pathspecs resolve from the current
    directory.
  - Everything after that runs in one awk, which reads git's output through
    pipes (`cmd | getline`, `close()` returning the exit status). Nothing is
    written to disk, so a run lefthook kills leaves nothing behind. Each
    ls-files command stays below 64 KiB, because `sh -c` gets it as a single
    argument and Linux caps one at 128 KiB.
  - It can stop the formatter's `git add`, not lefthook's set-aside of
    unstaged hunks, which runs before any job. There a partially staged
    pattern name still reaches other files; one run lost an assume-unchanged
    file's local edit.
  - The real fix is upstream: literal pathspecs and `-z` name lists.
    `tests/pathspec-guard.sh` commits through a formatter's render
    (`GUARD_CONFIG`), without auto-commit and during a merge; through
    `GUARD_OFF_CONFIG`, auto-commit's with the guard turned off; and through
    `PREPARE_ONLY_CONFIG`, that render as configs from before the guard job
    start (no guard job, no `--no-guard`).

## Nix gotchas seen in this repo

- Flakes only read **git-tracked** files: `git add -N` a new `.nix` file or nix
  reports it as missing.
- `nix build --expr` evaluates in pure mode, which forbids importing absolute
  store paths — `scripts/init.sh` passes `--impure` for exactly that reason.
- `statix` flags repeated top-level keys, so a second `inputs.<name>` line
  requires the nested `inputs = { … }` form; likewise `config.a`/`config.b` in a
  module must be a single `config = { … }` block.
- The dev shell deliberately does **not** put bare `git` on the interactive
  `PATH` — it would shadow a user's wrapped git and break commit identity. The
  shellHook is a single call to the `wire-repo` wrapper, which carries its own
  git via `runtimeInputs` — inside that process only, never on your `PATH`.
