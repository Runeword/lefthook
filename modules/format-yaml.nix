{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.yamlfmt
      (pkgs.writeShellScriptBin "format-yaml" (builtins.readFile "${self}/scripts/format-yaml.sh"))
    ];
    configFiles = [ "${self}/precommit-format-yaml.yml" ];
  };
}
