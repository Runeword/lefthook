{ pkgs, self }:
pkgs.mkShell {
  buildInputs = [ pkgs.taplo ];
  shellHook = ''
    mkdir -p .lefthook.d
    ln -sfn ${self}/precommit-format-toml.yml .lefthook.d/format-toml.yml
  '';
}
