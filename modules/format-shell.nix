{ pkgs, self }:
pkgs.mkShell {
  buildInputs = [
    pkgs.shfmt
    pkgs.shellharden
  ];
  shellHook = ''
    mkdir -p .lefthook.d
    ln -sfn ${self}/precommit-format-shell.yml .lefthook.d/format-shell.yml
  '';
}
