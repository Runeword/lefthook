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
          hooks = import ./hooks.nix { inherit pkgs; };
        }
      );

      # The wrapper scripts, exposed so a repository that commits without
      # entering a dev shell can install them globally and resolve the
      # generated config's bare `run` names. Plus `lefthook-init`, the
      # one-command scaffolder.
      packages = forAllSystems (
        { pkgs, system, ... }:
        import ./wrappers.nix { inherit pkgs; }
        // {
          lefthook-init = import ./init.nix {
            inherit
              pkgs
              self
              system
              nixpkgs
              ;
          };
        }
      );

      # `nix run github:Runeword/lefthook` scaffolds the current repository.
      apps = forAllSystems (
        { system, ... }:
        let
          init = {
            type = "app";
            program = "${self.packages.${system}.lefthook-init}/bin/lefthook-init";
            meta.description = "Scaffold lefthook into the current git repository";
          };
        in
        {
          inherit init;
          default = init;
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
              security-gitleaks.enable = true;
              auto-commit.enable = true;
            };
          };
        }
      );

      checks = forAllSystems (
        { system, pkgs, ... }:
        {
          lefthook-config =
            let
              rendered = self.devShells.${system}.default.lefthookConfig;
            in
            pkgs.runCommand "check-lefthook-config"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.lefthook
                ];
              }
              ''
                # The committed copy must match what the flake renders.
                cmp ${./lefthook-generated.yml} ${rendered}

                # lefthook must be able to load the rendered config.
                export HOME="$TMPDIR"
                cd "$TMPDIR"
                git init -q
                cp ${rendered} lefthook.yml
                lefthook dump >/dev/null
                touch "$out"
              '';
        }
      );
    };
}
