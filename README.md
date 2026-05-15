# Lefthook remote configs
A collection of reusable [Lefthook](https://github.com/evilmartians/lefthook) configurations that can be shared across multiple projects.

## Installation

### As a Nix flake module (recommended)

Add this repo as a flake input and compose modules in your devShell:

```nix
inputs.lefthook.url = "github:Runeword/lefthook";

# in your devShell:
lefthook.lib.mkShell {
  inherit pkgs;
  modules = with lefthook.lib; [
    # per-language hooks: list format → lint → security
    format-nix
    lint-nix
    format-go
    lint-go
    format-shell
    lint-shell
    format-opentofu
    lint-opentofu
    security-opentofu
    # cross-language
    security-gitleaks
    # finalize: keep last
    auto-msg
  ];
};
```

Entering the shell installs the required binaries, generates `lefthook.local.yml`, and runs `lefthook install`.

#### Ordering rule

The order in your `modules = [...]` list is the execution order. Within a language, list the modules as `format → lint → security`. Put `auto-msg` last.

#### Scheduling

Each `precommit-*.yml` declares a single hook nested under
`pre-commit.jobs[main].group.jobs[<lang>].group.jobs[<tool>]` (or, for
cross-language hooks, a flat job inside `main`; for `auto-msg`, a sibling
`finalize` group).

When `mkShell` extends multiple of them together, lefthook merges nested
`jobs:` by name, so:

- All language lanes (`nix`, `go`, `shell`, …) run in parallel inside `main`.
- Within a lane, hooks run sequentially in the order their ymls were extended (piped, stops on first failure).
- Cross-language hooks (e.g. `security-gitleaks`) live as flat jobs inside `main`, alongside the lanes.
- `auto-msg` puts `auto-commit` in a sibling `finalize` group that runs strictly after `main`.

### As remote configs

Reference yml files directly via lefthook's `remotes:`:

```shell
cat <<EOF > lefthook.yml
remotes:
  - git_url: https://github.com/Runeword/lefthook
    configs:
      - precommit-format-nix.yml
      - precommit-lint-nix.yml
      - precommit-auto-msg.yml
EOF

lefthook install
```

Lefthook's own `extends:` semantics produce the same nested jobs tree as the flake path. List the configs in the order `format → lint → security → auto-msg` so the within-lane order is correct.
