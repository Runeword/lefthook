{ self }:
{
  buildInputs = pkgs: [ pkgs.taplo ];
  configFile = "${self}/precommit-format-toml.yml";
}
