{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.shfmt
      pkgs.shellharden
      (pkgs.writeShellScriptBin "format-shell" (builtins.readFile "${self}/scripts/format-shell.sh"))
    ];
    configFiles = [ "${self}/precommit-format-shell.yml" ];
  };
}
