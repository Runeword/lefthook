{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.golangci-lint
      (pkgs.writeShellScriptBin "lint-go" (builtins.readFile "${self}/scripts/lint-go.sh"))
    ];
    configFiles = [ "${self}/precommit-lint-go.yml" ];
  };
}
