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
`shfmt --language-dialect posix`, `shellharden`, `shellcheck` for
`scripts/*.sh`). Run them before committing rather than discovering it mid-hook.

## Commands

```sh
nix flake check                                    # eval + the config check below
nix build .#checks.x86_64-linux.lefthook-config    # just that check
nix build .#devShells.x86_64-linux.default.lefthookConfig  # render the config
nix develop                                        # regenerates lefthook-generated.yml, installs hooks
nix run .#init -- --lanes nix,shell                # the scaffolder, against this checkout
```

There is no unit-test suite. `checks.lefthook-config` asserts the **committed**
`lefthook-generated.yml` matches what the flake renders, and that lefthook can
load it. Behavioural changes (auto-commit, the scaffolder, hook semantics) are
verified empirically by driving real `git commit`s in throwaway repos under the
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
- **`wrappers.nix`** — the four hooks with real shell logic, built with
  `writeShellApplication` (strict bash, pinned `runtimeInputs`, shellcheck at
  build time). Imported by both `hooks.nix` and `flake.nix`.
- **`mk-shell.nix`** — an `evalModules` module plus the renderer. Exposes
  `mkShell` (dev shell) and `toolchain` (the packages, for global installs);
  both take the same arguments.
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
  renders.** After changing `hooks.nix` or `mk-shell.nix`, regenerate it
  (`nix develop` / `direnv reload`) or `nix flake check` fails on the `cmp`.
- **`min_version` must describe the lefthook that will *run* the hook**, not
  the one that rendered the config. It defaults to `pkgs.lefthook.version`;
  `lefthook-init` overrides it with the runner found on `PATH`. A config
  demanding a newer lefthook than the runner fails hard at commit time — this
  has bitten repeatedly when a consumer's nixpkgs is older than this flake's.
- **`lanes` is all-or-nothing per lane**; opt a hook out with
  `hooks.<name>.enable = false`, which wins over what a lane implies.
- **`scripts/*.sh` need `#!/bin/sh`** even though `writeShellApplication`
  supplies its own shebang and the line is inert — without it shellcheck
  fails with SC2148. Keep them POSIX-clean so the repo's own `shfmt --language-dialect posix`
  and `shellcheck` pass.
- **`auto-commit` must pass through** when git is not operating on the real
  index (`GIT_INDEX_FILE` ending in `.lock`, i.e. `git commit -a` and pathspec
  commits) or when a merge/cherry-pick/revert/rebase is in progress. Removing
  either guard silently corrupts history; both are covered in
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
  shellHook uses an absolute store path inside a subshell instead.
