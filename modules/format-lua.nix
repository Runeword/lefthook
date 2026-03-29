{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.stylua ];
    configFiles = [ "${self}/precommit-format-lua.yml" ];
  };
}
