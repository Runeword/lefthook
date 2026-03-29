{ pkgs, self }:
pkgs.mkShell {
  buildInputs = [ pkgs.nixfmt-rfc-style ];
  shellHook = ''
    mkdir -p .lefthook.d
    ln -sfn ${self}/precommit-format-nix.yml .lefthook.d/format-nix.yml
  '';
}
