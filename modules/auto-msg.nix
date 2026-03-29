{ pkgs, self }:
pkgs.mkShell {
  shellHook = ''
    mkdir -p .lefthook.d
    ln -sfn ${self}/precommit-auto-msg.yml .lefthook.d/auto-msg.yml
  '';
}
