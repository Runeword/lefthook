{ self }:
{
  buildInputs = pkgs: [ pkgs.nixfmt-rfc-style ];
  configFile = "${self}/precommit-format-nix.yml";
}
