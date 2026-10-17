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
nix build -L .#checks.x86_64-linux.behaviour-staged-tree   # tests/staged-tree.sh
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
`tests/lib.sh` has the helpers, including `instrument`, a git shim that runs a
snippet after the Nth call of a git subcommand: the deterministic way to stage
"another terminal acted mid-run". A behavioural change to a wrapper lands with
a test here.

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
  `lane` + `order` / `standalone` / `finalize`, the `tools` it needs on `PATH`,
  and `jobs` written as **verbatim lefthook job attrsets** (`name`, `run`,
  `glob`, `stage_fixed`, `skip`, …) emitted into the YAML as-is. Adding a hook
  should touch only this file.
- **`wrappers.nix`** — every script with real shell logic, built with
  `writeShellApplication` (strict bash, pinned `runtimeInputs`, shellcheck at
  build time): the `auto-commit`, `lint-*` and `security-opentofu` hooks, plus
  the non-hook `wire-repo`. `scripts/staged-tree.sh` is not a wrapper: it is
  prepended to `lint-go`, `lint-opentofu` and `security-opentofu` (see the
  invariants below), which share its runtime inputs (`stagedTreeInputs`: git,
  flock, findutils, gawk, coreutils). Imported by `hooks.nix`, `flake.nix`,
  `mk-shell.nix` and `init.nix`. `runtimeInputs` must list *every* command the
  script calls — the ambient `PATH` stays in place, so an omission resolves
  silently from whatever the commit environment happens to have. Note `cmp` is
  in **diffutils**, not coreutils. The one deliberate exception is `go` for
  `lint-go`: golangci-lint loads packages through the project's own toolchain,
  whose version decides what compiles.
- **`scripts/wire-repo.sh`** — the shared "point this repo at a rendered
  config" step: writes `lefthook-generated.yml`, seeds `lefthook.yml`, keeps
  `lefthook-local.yml` out of the index, then `lefthook install`. Both the dev
  shell's `shellHook` and `lefthook-init` call it, so changing either path means
  changing this file. The shellHook passes `--warn-drift`: an existing
  generated config is never rewritten on entry, only created when missing —
  drift gets a warning naming `lefthook-regen` (the same script in write mode,
  on the shell `PATH`). `lefthook-init` and `lefthook-regen` use write mode.
  Whatever it writes it names ("wrote … commit it"), in either mode.
- **`mk-shell.nix`** — an `evalModules` module plus the renderer. Exposes
  `mkShell` (dev shell), `toolchain` (the packages, for global installs) and
  `toolchainEnv` (the same packages as one `buildEnv`, for `nix profile
  install`); all take the same arguments. The shell's passthru carries
  `lefthookConfig` (the render) and `mkConfigCheck` (the drift check, consumed
  by this flake's own `checks.lefthook-config` and exportable to consumers),
  plus `mkHooksCheck` (the enabled hooks over every tracked file of `src` in
  the build sandbox, minus auto-commit and the network-bound lint-go,
  lint-opentofu and security-opentofu; dogfooded as `checks.lefthook-hooks`). Both
  checks read the repository from `src.sourceInfo` when `src` has one, because a
  flake in a subdirectory gets a `self` rooted there while wire-repo writes at
  the repository's top level.
- **`init.nix` / `scripts/init.sh`** — the `lefthook-init` scaffolder, for
  repos with no dev shell. gitleaks is on by default, auto-commit is opt-in
  (`--auto-commit`; `--no-auto-commit` is still accepted). It ends by checking
  that every command the config's `run:` lines call is on `PATH`, and prints
  the `toolchainEnv` install command for the ones that are not.

Ordering is data, never attrset order: lanes run in parallel under a `main`
job, jobs inside a lane are piped by `order` (format → lint → security),
`finalize` jobs follow `main`, and `pre-commit` is itself piped so a failing
lane blocks `auto-commit`.

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
  - **One stable directory per repository and hook, never a fresh random one,
    never `/tmp`.** The path is
    `${XDG_CACHE_HOME:-$HOME/.cache}/lefthook/staged/<hash of the common git dir>/<hook>/`,
    every level 0700, owned by the user, and refused otherwise.
    - golangci-lint caches findings by content but records absolute paths.
      From a new path on each run, a retried commit replayed findings into the
      deleted copy: `//nolint` and generated-file exclusions stopped applying,
      the commit stayed blocked, and the poisoned entries reached the user's
      shared cache (editor runs).
    - The go build cache also missed on every run.
    - `/tmp` is shared, and go and golangci-lint read go.work and .golangci.*
      from every parent directory.
  - **A flock serializes it.** The lock is `<hook>/lock`, taken with the
    portable `flock` package. The tree is rebuilt on each run and removed on
    exit.
    - lefthook SIGKILLs a job's process group on ^C, so no trap runs then. The
      next run of that hook reclaims the copy, and every run deletes other
      copies idle for more than 60 minutes whose lock `flock -n` can take.
    - Never replace the lock with mkdir: a SIGKILL would leave it held forever.
  - **Worktree form where the worktree is clean, the staged blob where it is
    not.** One cp batch and one checkout-index, never a process per file.
    - Clean files are copied from the worktree: git-crypt plaintext, smudged
      LFS, the user's line endings.
    - Changed, missing, skip-worktree and assume-unchanged files (every file
      under core.ignoreStat) are checked out with `--attr-source=<staged tree>`.
    - The hook's own FILEs always come from the worktree when they are regular
      files on both sides. They carry the formatter's fix, which lefthook
      stages only after the hook; without it, format → lint fails on what
      gofumpt (`for i, _ := range`) or `tofu fmt` (`type = "string"`) just
      fixed.
    - Gitlinks are filled from the submodule's own objects at the recorded
      commit.
  - **The real index is never written.** The snapshot comes from a copy of the
    index, because write-tree takes index.lock. The dirty set comes from
    `GIT_OPTIONAL_LOCKS=0 git diff`.
  - **The appended script gets paths, not git env.** GIT_DIR, GIT_WORK_TREE and
    GIT_INDEX_FILE are unset; it receives `staged_worktree`, `staged_prefix`,
    `staged_copy`, `staged_index`, `staged_git_dir`, `staged_cache` and
    `staged_scratch` instead. Each lint script carries a file-wide
    `shellcheck disable=SC2154` for them, because this repo's own hook runs
    shellcheck on each file alone.
  - **lint-go resolves by location as the worktree would**, then points into
    the copy.
    - It resolves the golangci-lint config, GOWORK, and relative replace/use
      paths that leave the repository.
    - It carries in the git-ignored files that `go list -deps -test` reports.
      It skips `go list` when nothing ignored could be a build input.
    - golangci-lint gets a hook-private GOLANGCI_LINT_CACHE, so its absolute
      paths never reach the user's cache.
    - GIT_DIR, GIT_WORK_TREE and GIT_INDEX_FILE name the repo, the copy and the
      copy's index, so new-from-rev works.
    - `go` is the one command it deliberately takes from the ambient PATH: the
      project's toolchain decides what compiles.
  - **OpenTofu.**
    - `.terraform/modules` is *copied* in: trivy does not follow a symlinked
      directory.
    - A relative tflint `plugin_dir` is rewritten to the worktree path, because
      tflint ranks it above TFLINT_PLUGIN_DIR.
    - security-opentofu skips other root modules file by file
      (`--skip-files <dir>/*.tf`). Never use `--skip-dirs`: it hid the called
      modules too, so nothing passed into a module was checked.
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
    kept. A rewritten entry loses its stat data (git re-reads that one file)
    and any assume-unchanged bit; untouched entries keep both.
  - commit-tree runs no hooks and ignores `commit.gpgSign`: the split passes
    `-S` itself, and `prepare-commit-msg`/`post-commit` no longer run per file.
    It skips a path a formatter returned to its base content (no empty commit),
    and runs `git maintenance run --auto --detach` once after publishing, since
    the cancelled umbrella commit never does.
  - Fold candidates' worktree blobs are hashed in one `hash-object -w
    --stdin-paths` before the first commit; a path that is no longer a regular
    file in the worktree keeps its staged blob.
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
  2.1.7 re-stages them itself when it survives).
- **`auto-commit` must pass through** when git is not operating on the real
  index (`GIT_INDEX_FILE` ending in `.lock`, i.e. `git commit -a` and pathspec
  commits), when a merge/squash-merge/cherry-pick/revert/rebase is in
  progress, and when a `commit-msg` or `prepare-commit-msg` hook is installed
  (found through `git rev-parse --git-path`, so `core.hooksPath` counts), whose
  checks the generated messages would bypass. Removing either of the first two
  guards silently corrupts history; all three are covered in
  `tests/auto-commit.sh`.
- **`auto-commit --prepare` refuses a staged path starting with `:`.** lefthook
  hands staged file names to `git add`/`git checkout` as pathspecs, where `:`
  starts pathspec magic, so git would act on some other file (an ignored one
  included: `stage_fixed` adds with `--force`). The real fix is upstream
  (literal pathspecs); until then this guard exists only where auto-commit is
  enabled.

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
