{ self }:
{
  buildInputs = pkgs: [ pkgs.yamlfmt ];
  configFile = "${self}/precommit-format-yaml.yml";
}
