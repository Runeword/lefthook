{ self }:
{
  buildInputs = pkgs: [ ];
  configFile = "${self}/precommit-auto-msg.yml";
}
