{ pkgs, self }:
pkgs.mkShell {
  buildInputs = [ pkgs.nixfmt ];
  shellHook = ''
    mkdir -p .lefthook.d
    ln -sfn ${self}/precommit-format-nix.yml .lefthook.d/format-nix.yml
  '';
}
