{ self, pkgs, ... }:
{
  config = {
    buildInputs = [
      pkgs.gitleaks
      (pkgs.writeShellScriptBin "security-gitleaks" (
        builtins.readFile "${self}/scripts/security-gitleaks.sh"
      ))
    ];
    configFiles = [ "${self}/precommit-security-gitleaks.yml" ];
  };
}
