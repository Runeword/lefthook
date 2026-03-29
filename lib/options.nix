{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options = {
    buildInputs = mkOption {
      type = types.listOf types.package;
      default = [ ];
      description = "Packages required by the enabled hooks.";
    };
    configFiles = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = "Lefthook YAML configuration files to extend.";
    };
  };
}
