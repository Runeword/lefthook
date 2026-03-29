{ self }:
{
  buildInputs = pkgs: [ pkgs.shellcheck ];
  configFile = "${self}/precommit-lint-shell.yml";
}
