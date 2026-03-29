{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.shfmt
      pkgs.shellharden
    ];
    configFiles = [ "${self}/precommit-format-shell.yml" ];
  };
}
