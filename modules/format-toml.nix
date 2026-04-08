{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.taplo
      (pkgs.writeShellScriptBin "format-toml" (builtins.readFile "${self}/scripts/format-toml.sh"))
    ];
    configFiles = [ "${self}/precommit-format-toml.yml" ];
  };
}
