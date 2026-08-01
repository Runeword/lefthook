# The `lefthook-init` scaffolder: one command that wires lefthook into any git
# repository, with no flake input, dev shell or direnv needed on that side.
#
# It renders the config by importing this flake's own hooks.nix/mk-shell.nix
# from the store, so a scaffolded repo and one wired via `lib.mkShell` produce
# byte-identical output. The store paths are baked in below.
{
  pkgs,
  self,
  nixpkgs,
  system,
}:
pkgs.writeShellApplication {
  name = "lefthook-init";
  # lefthook is deliberately NOT a runtimeInput: it would shadow the user's own
  # lefthook, and the config's `min_version` has to match the binary that will
  # really run the hook. The script resolves it from PATH, falling back here.
  # coreutils/diffutils/gnused/gnugrep are pinned rather than taken from the
  # invoking machine: this scaffolds repositories on arbitrary systems, and the
  # script leans on sed, grep, install and cmp behaving the same on all of them.
  # diffutils is listed explicitly because `cmp` is NOT in coreutils — without
  # it the "already exists and differs" check reads a missing-command 127 as
  # "differs" and refuses an otherwise idempotent re-run.
  runtimeInputs = [
    pkgs.coreutils
    pkgs.diffutils
    pkgs.git
    pkgs.gnugrep
    pkgs.gnused
    pkgs.nix
    (import ./wrappers.nix { inherit pkgs; }).wire-repo
  ];
  text = ''
    FEATURE_FLOOR=${import ./feature-floor.nix}
    LEFTHOOK_MAIN_CONFIGS="${(import ./config-names.nix).main}"
    LEFTHOOK_LOCAL_CONFIGS="${(import ./config-names.nix).local}"
    SELF=${self}
    NIXPKGS=${nixpkgs}
    SYSTEM=${system}
    LEFTHOOK_FALLBACK=${pkgs.lefthook}/bin/lefthook
  ''
  + builtins.readFile ./scripts/init.sh;
}
