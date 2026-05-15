{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.shellcheck
      (pkgs.writeShellScriptBin "lint-shell" (builtins.readFile "${self}/scripts/lint-shell.sh"))
    ];
    configFiles = [ "${self}/precommit-lint-shell.yml" ];
  };
}
