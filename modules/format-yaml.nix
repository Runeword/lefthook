{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.yamlfmt ];
    configFiles = [ "${self}/precommit-format-yaml.yml" ];
  };
}
