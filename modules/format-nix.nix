{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.nixfmt
      (pkgs.writeShellScriptBin "format-nix" (builtins.readFile "${self}/scripts/format-nix.sh"))
    ];
    configFiles = [ "${self}/precommit-format-nix.yml" ];
  };
}
