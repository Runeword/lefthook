{ pkgs, self }:
pkgs.mkShell {
  buildInputs = [ pkgs.shellcheck ];
  shellHook = ''
    mkdir -p .lefthook.d
    ln -sfn ${self}/precommit-lint-shell.yml .lefthook.d/lint-shell.yml
  '';
}
