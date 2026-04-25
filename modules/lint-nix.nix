{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.deadnix
      pkgs.statix
    ];
    configFiles = [ "${self}/precommit-lint-nix.yml" ];
  };
}
