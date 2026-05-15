{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.tflint
      (pkgs.writeShellScriptBin "lint-opentofu" (builtins.readFile "${self}/scripts/lint-opentofu.sh"))
    ];
    configFiles = [ "${self}/precommit-lint-opentofu.yml" ];
  };
}
