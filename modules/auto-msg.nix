{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      (pkgs.writeShellScriptBin "auto-commit" (builtins.readFile "${self}/scripts/auto-commit.sh"))
    ];
    configFiles = [ "${self}/precommit-auto-msg.yml" ];
  };
}
