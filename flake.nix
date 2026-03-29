{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      lib = {
        mkShell =
          pkgs: modules:
          pkgs.mkShell {
            inputsFrom = modules;
            buildInputs = [ pkgs.lefthook ];
            shellHook = "lefthook install";
          };
      };
    in
    {
      inherit lib;
      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mkModule = path: import path { inherit pkgs self; };
          modules = {
            auto-msg = mkModule ./modules/auto-msg.nix;
            format-nix = mkModule ./modules/format-nix.nix;
            format-shell = mkModule ./modules/format-shell.nix;
            format-toml = mkModule ./modules/format-toml.nix;
            format-yaml = mkModule ./modules/format-yaml.nix;
            lint-shell = mkModule ./modules/lint-shell.nix;
          };
        in
        modules
        // {
          default = lib.mkShell pkgs (builtins.attrValues modules);
        }
      );
    };
}
