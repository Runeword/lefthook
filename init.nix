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
  runtimeInputs = [
    pkgs.git
    pkgs.nix
  ];
  text = ''
    SELF=${self}
    NIXPKGS=${nixpkgs}
    SYSTEM=${system}
    LEFTHOOK_FALLBACK=${pkgs.lefthook}/bin/lefthook
  ''
  + builtins.readFile ./scripts/init.sh;
}
