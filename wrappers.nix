# Wrapper scripts for hooks with real shell logic: strict bash, pinned runtime
# deps, shellcheck at build time. Imported by hooks.nix (to place them on the
# dev-shell PATH under their bare names) and by flake.nix (exposed as
# `packages.<system>.<name>`, so a repository that commits without entering a
# dev shell can install them globally and still resolve the config's bare
# names).
#
# `runtimeInputs` must list every command a script calls, not just the headline
# tool: writeShellApplication prepends these to PATH but leaves the ambient one
# in place, so anything missing here silently resolves from whatever the commit
# environment happens to have (a GUI git client's minimal PATH has bitten this).
# Note coreutils does NOT ship `cmp` — that lives in diffutils.
{ pkgs }:
let
  # gitleaks reads `.gitleaks.toml` from the working directory, so a scanned
  # repository can disable the scan by shipping one. Pinning the ruleset here
  # takes that away: `useDefault` pulls in gitleaks' own built-in rules, and
  # this file — not the repository's — is what the hook reads.
  gitleaksConfig = pkgs.writeText "gitleaks-pinned.toml" ''
    [extend]
    useDefault = true
  '';

  # The hooks that check a whole package or module, not the staged files alone,
  # run on a copy of the staged tree: scripts/staged-tree.sh defines the
  # function that builds it, and each script calls it. A function rather than
  # a wrapper of its own, because its traps, its lock and its cd belong to the
  # check's shell, and wrapping the check would change the `run` strings
  # consumers have committed.
  withStagedTree = script: builtins.readFile ./scripts/staged-tree.sh + builtins.readFile script;
  # What staged-tree.sh itself calls: git, flock (the portable one, same CLI as
  # util-linux's, so it also builds on darwin) for the per-repository lock,
  # find/xargs for the sweep and the batched copy, awk to sort entries between
  # working tree and index, and coreutils.
  stagedTreeInputs = [
    pkgs.coreutils
    pkgs.findutils
    pkgs.flock
    pkgs.gawk
    pkgs.git
  ];
in
{
  auto-commit = pkgs.writeShellApplication {
    name = "auto-commit";
    # Not just git: awk to plan the commits (the deletions-before-additions
    # reorder, which paths fold in a formatter's fix) and to reconcile the index
    # after publishing, sed for the "--prepare" pathspec guard and messages,
    # coreutils' mktemp/cp/rm/sleep for the private index and its lock retry,
    # and find to sweep the private indexes of killed splits.
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.git
      pkgs.gnused
    ];
    text = builtins.readFile ./scripts/auto-commit.sh;
  };
  security-gitleaks = pkgs.writeShellApplication {
    name = "security-gitleaks";
    runtimeInputs = [
      pkgs.git
      pkgs.gitleaks
      pkgs.gnused
    ];
    text = ''
      GITLEAKS_CONFIG_FILE=${gitleaksConfig}
    ''
    + builtins.readFile ./scripts/security-gitleaks.sh;
  };
  # Not a hook: the shared "point this repo at a rendered config" step, called
  # by both lefthook-init and the dev shell's shellHook. It carries its own git
  # so neither caller needs one on its PATH.
  wire-repo = pkgs.writeShellApplication {
    name = "wire-repo";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
    ];
    text = ''
      LEFTHOOK_MAIN_CONFIGS="${(import ./config-names.nix).main}"
    ''
    + builtins.readFile ./scripts/wire-repo.sh;
  };
  # `go` is deliberately absent: golangci-lint loads packages through the
  # project's own Go toolchain from PATH, whose version decides what compiles.
  # jq reads `go mod edit -json` and `go work edit -json`.
  lint-go = pkgs.writeShellApplication {
    name = "lint-go";
    runtimeInputs = stagedTreeInputs ++ [
      pkgs.golangci-lint
      pkgs.jq
    ];
    text = withStagedTree ./scripts/lint-go.sh;
  };
  lint-nix = pkgs.writeShellApplication {
    name = "lint-nix";
    runtimeInputs = [
      pkgs.deadnix
      pkgs.statix
    ];
    text = builtins.readFile ./scripts/lint-nix.sh;
  };
  lint-opentofu = pkgs.writeShellApplication {
    name = "lint-opentofu";
    runtimeInputs = stagedTreeInputs ++ [ pkgs.tflint ];
    text = withStagedTree ./scripts/lint-opentofu.sh;
  };
  security-opentofu = pkgs.writeShellApplication {
    name = "security-opentofu";
    runtimeInputs = stagedTreeInputs ++ [
      pkgs.gnugrep
      pkgs.gnused
      pkgs.trivy
    ];
    text = withStagedTree ./scripts/security-opentofu.sh;
  };
}
