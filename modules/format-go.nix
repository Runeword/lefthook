{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.gotools ];
    configFiles = [ "${self}/precommit-format-go.yml" ];
  };
}
