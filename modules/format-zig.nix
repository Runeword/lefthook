{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.zig
      (pkgs.writeShellScriptBin "format-zig" (builtins.readFile "${self}/scripts/format-zig.sh"))
    ];
    configFiles = [ "${self}/precommit-format-zig.yml" ];
  };
}
