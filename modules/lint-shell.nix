{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.shellcheck ];
    configFiles = [ "${self}/precommit-lint-shell.yml" ];
  };
}
