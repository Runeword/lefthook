{ self }:
{
  buildInputs = pkgs: [ pkgs.nixfmt ];
  configFile = "${self}/precommit-format-nix.yml";
}
