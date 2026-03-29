{ self }:
{
  buildInputs = pkgs: [
    pkgs.shfmt
    pkgs.shellharden
  ];
  configFile = "${self}/precommit-format-shell.yml";
}
