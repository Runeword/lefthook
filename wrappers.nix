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
{
  auto-commit = pkgs.writeShellApplication {
    name = "auto-commit";
    runtimeInputs = [ pkgs.git ];
    text = builtins.readFile ./scripts/auto-commit.sh;
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
    text = builtins.readFile ./scripts/wire-repo.sh;
  };
  lint-go = pkgs.writeShellApplication {
    name = "lint-go";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.golangci-lint
    ];
    text = builtins.readFile ./scripts/lint-go.sh;
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
    runtimeInputs = [
      pkgs.coreutils
      pkgs.tflint
    ];
    text = builtins.readFile ./scripts/lint-opentofu.sh;
  };
  security-opentofu = pkgs.writeShellApplication {
    name = "security-opentofu";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.trivy
    ];
    text = builtins.readFile ./scripts/security-opentofu.sh;
  };
}
