# Wrapper scripts for hooks with real shell logic: strict bash, pinned runtime
# deps, shellcheck at build time. Imported by hooks.nix (to place them on the
# dev-shell PATH under their bare names) and by flake.nix (exposed as
# `packages.<system>.<name>` so non-dev-shell consumers — e.g. a bare dotfiles
# repo — can install them globally and still resolve the config's bare names).
{ pkgs }:
{
  auto-commit = pkgs.writeShellApplication {
    name = "auto-commit";
    runtimeInputs = [ pkgs.git ];
    text = builtins.readFile ./scripts/auto-commit.sh;
  };
  lint-go = pkgs.writeShellApplication {
    name = "lint-go";
    runtimeInputs = [ pkgs.golangci-lint ];
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
    runtimeInputs = [ pkgs.tflint ];
    text = builtins.readFile ./scripts/lint-opentofu.sh;
  };
}
