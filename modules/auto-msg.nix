{ self, ... }:
{
  config.configFiles = [ "${self}/precommit-auto-msg.yml" ];
}
