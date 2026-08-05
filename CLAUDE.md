# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

A Nix flake that renders [lefthook](https://github.com/evilmartians/lefthook)
pre-commit hooks into a single committed config. See `README.md` for the
consumer-facing story; this file covers what you need to work *on* the flake.

## `git commit` exits 1 here — that is success

This repo dogfoods its own `auto-commit` hook, which splits one commit into one
commit per staged file and then cancels the umbrella commit. So a successful
commit reports failure and discards your commit message. Check `git log`, not
the exit code. `LEFTHOOK_EXCLUDE=auto-commit git commit -m "…"` gives a single
normal commit instead.

Committing also runs this repo's formatters and linters on the staged files and
**blocks the commit** if they fail (`nixfmt`, `deadnix`, `statix` for Nix;
`shfmt --language-dialect auto`, `shellcheck` for `scripts/*.sh`). Run them
before committing rather than discovering it mid-hook.
`auto` reads the shebang, so these `#!/bin/sh` scripts are still held to POSIX —
it exists so a *consumer's* `#!/bin/bash` script is not rejected outright.

## Commands

```sh
nix flake check                                    # eval + the config check below
nix build .#checks.x86_64-linux.lefthook-config    # just that check
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

There is no unit-test suite. `checks.lefthook-config` asserts the **committed**
`lefthook-generated.yml` matches what the flake renders, and that lefthook can
load it; `checks.lefthook-all-lanes` renders *every* lane (the dev shell only
covers four) and forces each hook's tools to instantiate, so a nixpkgs bump that
breaks a tool this repo never builds fails here rather than at a consumer.
Neither check enforces `min_version` or `assert_lefthook_installed` — `lefthook
dump` merges without applying them; both bite at `run` time.

Behavioural changes (auto-commit, the scaffolder, hook semantics) are verified
empirically by driving real `git commit`s in throwaway repos under the
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
  the non-hook `wire-repo`. Imported by `hooks.nix`, `flake.nix`,
  `mk-shell.nix` and `init.nix`. `runtimeInputs` must list *every* command the
  script calls — the ambient `PATH` stays in place, so an omission resolves
  silently from whatever the commit environment happens to have. Note `cmp` is
  in **diffutils**, not coreutils.
- **`scripts/wire-repo.sh`** — the shared "point this repo at a rendered
  config" step: writes `lefthook-generated.yml`, seeds `lefthook.yml`, keeps
  `lefthook-local.yml` out of the index, then `lefthook install`. Both the dev
  shell's `shellHook` and `lefthook-init` call it, so changing either path means
  changing this file. The shellHook passes `--warn-drift`: an existing
  generated config is never rewritten on entry, only created when missing —
  drift gets a warning naming `lefthook-regen` (the same script in write mode,
  on the shell `PATH`). `lefthook-init` and `lefthook-regen` use write mode.
- **`mk-shell.nix`** — an `evalModules` module plus the renderer. Exposes
  `mkShell` (dev shell) and `toolchain` (the packages, for global installs);
  both take the same arguments. The shell's passthru carries `lefthookConfig`
  (the render) and `mkConfigCheck` (the drift check, consumed by this flake's
  own `checks.lefthook-config` and exportable to consumers).
- **`init.nix` / `scripts/init.sh`** — the `lefthook-init` scaffolder, for
  repos with no dev shell.

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
- **`auto-commit` cannot see `--amend` or `--fixup`.** The hook environment is
  byte-identical to a normal commit, so both get rewritten into new commits on
  top. There is no fix; `--no-verify` is the documented escape hatch.
- **`auto-commit` must restore what `read-tree` destroys.** Rebuilding the
  index drops skip-worktree bits (in a sparse checkout every excluded path then
  reads as deleted to the next `git add -A`), `--assume-unchanged` bits, and the
  stat cache. The `cleanup` trap puts them back on the success *and* failure
  paths. Two traps for the price of one: `sparse-checkout reapply` restores
  skip-worktree only, so assume-unchanged is snapshotted separately **including**
  in sparse checkouts; and bash does not run an `EXIT` trap when it dies of a
  group `SIGINT`, so `INT`/`TERM`/`HUP` are trapped explicitly.
- **`auto-commit` must pass through** when git is not operating on the real
  index (`GIT_INDEX_FILE` ending in `.lock`, i.e. `git commit -a` and pathspec
  commits) or when a merge/squash-merge/cherry-pick/revert/rebase is in
  progress. Removing either guard silently corrupts history; both are covered in
  `scripts/auto-commit.sh`.

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
