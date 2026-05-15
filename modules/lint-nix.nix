{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.deadnix
      pkgs.statix
      (pkgs.writeShellScriptBin "lint-nix" (builtins.readFile "${self}/scripts/lint-nix.sh"))
    ];
    configFiles = [ "${self}/precommit-lint-nix.yml" ];
  };
}
