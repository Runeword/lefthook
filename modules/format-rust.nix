{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.rustfmt
      (pkgs.writeShellScriptBin "format-rust" (builtins.readFile "${self}/scripts/format-rust.sh"))
    ];
    configFiles = [ "${self}/precommit-format-rust.yml" ];
  };
}
