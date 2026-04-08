{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.gofumpt
      (pkgs.writeShellScriptBin "format-go" (builtins.readFile "${self}/scripts/format-go.sh"))
    ];
    configFiles = [ "${self}/precommit-format-go.yml" ];
  };
}
