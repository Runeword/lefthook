{ self, pkgs, ... }:
{
  config = {
    buildInputs = [ pkgs.gitleaks ];
    configFiles = [ "${self}/precommit-security-gitleaks.yml" ];
  };
}
