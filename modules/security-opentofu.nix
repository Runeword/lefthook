{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.trivy
      (pkgs.writeShellScriptBin "security-opentofu" (
        builtins.readFile "${self}/scripts/security-opentofu.sh"
      ))
    ];
    configFiles = [ "${self}/precommit-security-opentofu.yml" ];
  };
}
