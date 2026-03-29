{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.taplo ];
    configFiles = [ "${self}/precommit-format-toml.yml" ];
  };
}
