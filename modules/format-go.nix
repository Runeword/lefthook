{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.gofumpt ];
    configFiles = [ "${self}/precommit-format-go.yml" ];
  };
}
