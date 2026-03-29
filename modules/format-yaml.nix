{ pkgs, self }:
pkgs.mkShell {
  buildInputs = [ pkgs.yamlfmt ];
  shellHook = ''
    mkdir -p .lefthook.d
    ln -sfn ${self}/precommit-format-yaml.yml .lefthook.d/format-yaml.yml
  '';
}
