# Lefthook remote configs

A collection of reusable [Lefthook](https://github.com/evilmartians/lefthook) hooks distributed as a Nix flake.

The flake exposes:

- `packages.<system>.<hook>` — wrapper binaries (e.g. `format-nix`, `lint-go`, `auto-commit`)
- `precommit-<hook>.yml` files in the flake source — lefthook YAML fragments (the filename matches each wrapper's name)
- `lib.<system>.mkShell { hooks }` — module-style factory. `hooks` is an attrset where each known hook can be enabled with `<name>.enable = true`. Returns a `pkgs.mkShell` derivation with the enabled binaries plus `pkgs.lefthook` on PATH and a `shellHook` that generates `lefthook.local.yml`, ensures `lefthook.yml` exists, and runs `lefthook install`. Drop it into your own shell's `inputsFrom`. Unknown hook names error at evaluation with a "Did you mean…?" suggestion (NixOS-module style, à la [cachix/git-hooks.nix](https://github.com/cachix/git-hooks.nix) and [numtide/treefmt-nix](https://github.com/numtide/treefmt-nix)).

## Installation

Add as a flake input:

```nix
inputs.lefthook.url = "github:Runeword/lefthook";
```

Then in your devShell:

```nix
{ lefthook, pkgs, ... }:
pkgs.mkShell {
  inputsFrom = [
    (lefthook.lib.${pkgs.system}.mkShell {
      hooks = {
        # per-language: format → lint → security
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

Each `<name>.enable = true` selects a hook from `lefthook.packages.<system>` (binary + matching YAML fragment, bundled via `passthru.lefthookFragment`). `mkShell` puts the enabled binaries on PATH, generates `lefthook.local.yml` extending the matching fragments, and runs `lefthook install`. `pkgs.lefthook` is injected automatically.

## Ordering

Lefthook merges `extends:` fragments by job name. List hooks as `format-<lang> → lint-<lang> → security-<lang>` within each language, and put `auto-commit` last. Lefthook auto-parallelizes language lanes; piped jobs within a lane stop on first failure.

## Available hooks

Each hook ships a wrapper binary and a YAML fragment with the same name.

| Hook                 | YAML file                            |
| -------------------- | ------------------------------------ |
| `auto-commit`        | `precommit-auto-commit.yml`          |
| `format-go`          | `precommit-format-go.yml`            |
| `format-lua`         | `precommit-format-lua.yml`           |
| `format-nix`         | `precommit-format-nix.yml`           |
| `format-opentofu`    | `precommit-format-opentofu.yml`      |
| `format-rust`        | `precommit-format-rust.yml`          |
| `format-shell`       | `precommit-format-shell.yml`         |
| `format-toml`        | `precommit-format-toml.yml`          |
| `format-yaml`        | `precommit-format-yaml.yml`          |
| `format-zig`         | `precommit-format-zig.yml`           |
| `lint-go`            | `precommit-lint-go.yml`              |
| `lint-nix`           | `precommit-lint-nix.yml`             |
| `lint-opentofu`      | `precommit-lint-opentofu.yml`        |
| `lint-shell`         | `precommit-lint-shell.yml`           |
| `security-gitleaks`  | `precommit-security-gitleaks.yml`    |
| `security-opentofu`  | `precommit-security-opentofu.yml`    |

## Remote configs (without Nix)

Alternatively, reference the YAML files directly via lefthook's own `remotes:`. Tools must be on PATH already in this mode.

```yaml
remotes:
  - git_url: https://github.com/Runeword/lefthook
    configs:
      - precommit-format-nix.yml
      - precommit-lint-nix.yml
      - precommit-auto-commit.yml
```
