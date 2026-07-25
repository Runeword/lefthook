{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f {
            inherit system;
            inherit (nixpkgs) lib;
            pkgs = nixpkgs.legacyPackages.${system};
          }
        );
    in
    {
      lib = forAllSystems (
        { pkgs, lib, ... }:
        import ./mk-shell.nix {
          inherit pkgs lib;
          hooks = import ./hooks.nix { inherit pkgs lib; };
        }
      );

      devShells = forAllSystems (
        { system, ... }:
        {
          default = self.lib.${system}.mkShell {
            hooks = {
              format-nix.enable = true;
              lint-nix.enable = true;
              format-shell.enable = true;
              lint-shell.enable = true;
              format-toml.enable = true;
              format-yaml.enable = true;
              auto-commit.enable = true;
            };
          };
        }
      );
    };
}
