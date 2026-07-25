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
- renders one lefthook config (via `pkgs.formats.yaml`) and copies it into the
  project root as `lefthook-generated.yml` — commit that file: hooks then work
  from `git checkout` onward (fresh clones, new worktrees, after garbage
  collection) with no dependency on any machine's Nix store;
- creates `lefthook.yml` if absent so it `extends` the generated file — and
  warns when an existing `lefthook.yml` doesn't reference it — then runs
  `lefthook install`.

Every hook's `run:` command calls its tool by bare name, resolved from the dev
shell `PATH`, so the generated config is machine-independent. A commit made
outside the dev shell fails loudly with `command not found` instead of
silently running stale or missing tools. Unknown hook names fail at evaluation
with a NixOS-module-style "Did you mean…?" suggestion.

`lefthook-local.yml` is left entirely to you — it is lefthook's own per-user
override file and is merged automatically. Shell entry adds it to
`.git/info/exclude` so it can't be committed by accident.

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
        # commit-message automation
        auto-commit.enable       = true;
      };
    })
  ];
}
```

On first shell entry the flake writes `lefthook-generated.yml` (and a
`lefthook.yml` extending it, if you had none) into the repo — commit both.

If you already have a `lefthook.yml` (for `pre-push` jobs, say), add the
generated file to its `extends:` list yourself:

```yaml
extends:
  - lefthook-generated.yml
```

## Ordering (enforced, not by convention)

Hooks are grouped into per-language **lanes** that run in parallel under a
`main` job. Within a lane, jobs are **piped** in `format → lint → security`
order and stop on first failure. `auto-commit` runs afterwards (declared
`finalize`), and `pre-commit` itself is piped — so a failing formatter or
linter blocks `auto-commit` entirely. Formatters carry `stage_fixed`, so fixes
are re-staged before anything is committed.

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

## Overrides & escape hatches

- `LEFTHOOK=0 git commit …` skips every hook for one commit.
- `LEFTHOOK_EXCLUDE=auto-commit git commit …` skips one job by name (works for
  nested jobs) — the practical way to get a single commit with your own
  message.
- `git commit --amend --no-verify` is the way to amend: a pre-commit hook
  cannot detect `--amend`, so without `--no-verify` the fixup would land as a
  new commit on top and the amend would silently not happen.
- `lefthook-local.yml` with `pre-commit: { skip: true }` turns the hooks off
  for one clone. Per-job `skip` entries in the local file append to the config
  rather than merging into nested jobs — use `LEFTHOOK_EXCLUDE` for that.

Two caveats:

- `lefthook run pre-commit` is not a dry run — the `auto-commit` job creates
  real commits from whatever is staged.
- If an unstaged edit touches the same line a formatter rewrites, lefthook's
  restore of unstaged changes can fail: the commit succeeds and the unstaged
  edit disappears from the worktree, with only a console warning. The content
  survives in the `lefthook auto backup` stash and
  `.git/info/lefthook-unstaged.patch`.

## auto-commit

Splits one `git commit` into one commit per staged file, each with a generated
`Add/Update/Delete <file>` message, then aborts the umbrella commit.

Consequences worth knowing:

- **`git commit` always exits non-zero, even on success** — its files have
  already been committed individually, so the original commit is cancelled
  (and the umbrella commit message is discarded).
- Each file is committed from its **staged** blob, so partial staging
  (`git add -p`) is preserved: unstaged hunks stay in the working tree.
- Situations where splitting would corrupt history pass through untouched as
  one normal commit: concluding a merge, cherry-pick, revert, or rebase, and
  `git commit -a` / pathspec commits (git runs those against a temporary
  index).

## Adding a hook

Add an entry to `hooks.nix`: exactly one of `lane` + `order`, `standalone`, or
`finalize` (validated at evaluation), the `tools` it needs on `PATH`, and one
or more `jobs` written as verbatim lefthook job attrsets whose `run` calls the
tool by bare name. Formatters set `stage_fixed = true`. That is the only file
to touch — `mk-shell.nix` renders it and the module exposes the
`<name>.enable` option automatically.
