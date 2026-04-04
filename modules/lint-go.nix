{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.golangci-lint ];
    configFiles = [ "${self}/precommit-lint-go.yml" ];
  };
}
