{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.stylua
      (pkgs.writeShellScriptBin "format-lua" (builtins.readFile "${self}/scripts/format-lua.sh"))
    ];
    configFiles = [ "${self}/precommit-format-lua.yml" ];
  };
}
