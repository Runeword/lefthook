{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.nixfmt ];
    configFiles = [ "${self}/precommit-format-nix.yml" ];
  };
}
