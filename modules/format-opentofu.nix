{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.opentofu
      (pkgs.writeShellScriptBin "format-opentofu" (
        builtins.readFile "${self}/scripts/format-opentofu.sh"
      ))
    ];
    configFiles = [ "${self}/precommit-format-opentofu.yml" ];
  };
}
