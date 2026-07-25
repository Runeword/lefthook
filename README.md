# Lefthook Nix flake

Reusable [Lefthook](https://github.com/evilmartians/lefthook) pre-commit hooks
for a Nix dev shell. Enable the hooks you want; the flake renders them into a
single generated lefthook config with the ordering baked in.

## How it works

`lib.<system>.mkShell { hooks = { … }; }` is the only public entry point.
`hooks` is an attrset where each known hook is toggled with `<name>.enable =
true`. It returns a `pkgs.mkShell` derivation to drop into your own shell's
`inputsFrom`. On shell entry it:

- puts the enabled tools plus `pkgs.lefthook` on `PATH`;
- renders one lefthook config (via `pkgs.formats.yaml`) and symlinks it into the
  project root as `.lefthook-generated.yml` (git-ignored);
- creates `lefthook.yml` if absent so it `extends` the generated file, then runs
  `lefthook install`.

Every hook's `run:` command is an absolute `/nix/store` path, so hooks keep
working when you commit from outside the dev shell (GUI clients, bare
terminals). Unknown hook names fail at evaluation with a NixOS-module-style
"Did you mean…?" suggestion.

`lefthook.local.yml` is left entirely to you — it is lefthook's own per-user
override file and is merged automatically.

## Installation

Add as a flake input:

```nix
inputs.lefthook.url = "github:Runeword/lefthook";
```

Then in your dev shell:

```nix
{ lefthook, pkgs, ... }:
pkgs.mkShell {
  inputsFrom = [
    (lefthook.lib.${pkgs.system}.mkShell {
      hooks = {
        # per language: format → lint → security
        format-nix.enable        = true;
        lint-nix.enable          = true;
        format-shell.enable      = true;
        lint-shell.enable        = true;
        security-gitleaks.enable = true;
        # commit-message automation (keep last)
        auto-commit.enable       = true;
      };
    })
  ];
}
```

If you already have a `lefthook.yml` (for `pre-push` jobs, say), add the
generated file to its `extends:` list yourself:

```yaml
extends:
  - .lefthook-generated.yml
```

## Ordering (enforced, not by convention)

Hooks are grouped into per-language **lanes** that run in parallel under a
`main` job. Within a lane, jobs are **piped** in `format → lint → security`
order and stop on first failure. `auto-commit` runs afterwards in a `finalize`
job, and `pre-commit` itself is piped — so a failing formatter or linter blocks
`auto-commit` entirely. Formatters carry `stage_fixed`, so fixes are re-staged
before anything is committed.

All of this is derived from data in `hooks.nix`, so the order is fixed and
cannot drift with how the attrset happens to be enumerated.

## Available hooks

| Lane       | Hooks                                                     |
| ---------- | -------------------------------------------------------- |
| `go`       | `format-go`, `lint-go`                                    |
| `lua`      | `format-lua`                                              |
| `nix`      | `format-nix`, `lint-nix`                                  |
| `opentofu` | `format-opentofu`, `lint-opentofu`, `security-opentofu`  |
| `rust`     | `format-rust`                                             |
| `shell`    | `format-shell` (shfmt + shellharden), `lint-shell`       |
| `toml`     | `format-toml`                                             |
| `yaml`     | `format-yaml`                                             |
| `zig`      | `format-zig`                                              |
| —          | `security-gitleaks` (repo-wide), `auto-commit` (finalize) |

## auto-commit

Splits one `git commit` into one commit per staged file, each with a generated
`Add/Update/Delete <file>` message, then aborts the umbrella commit.

Two consequences worth knowing:

- **`git commit` always exits non-zero, even on success** — its files have
  already been committed individually, so the original commit is cancelled.
- Each file is committed from its **staged** blob, so partial staging
  (`git add -p`) is preserved: unstaged hunks stay in the working tree.

Enable it last.

## Adding a hook

Add an entry to `hooks.nix`: give it a `lane` + `order` (or `standalone` /
`finalize`), the `tools` it needs on `PATH`, and one or more `jobs` whose `run`
is built from `lib.getExe'`. Formatters should set `stageFixed = true`. That is
the only file to touch — `mk-shell.nix` renders it and the module exposes the
`<name>.enable` option automatically.
