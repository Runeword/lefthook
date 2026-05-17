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
    in
    {
      lib = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          inherit (nixpkgs) lib;

          module =
            { config, ... }:
            let
              available = self.packages.${system};
              enabledHooks = map (name: available.${name}) (
                lib.attrNames (lib.filterAttrs (_: cfg: cfg.enable) config.hooks)
              );
            in
            {
              options = {
                hooks = lib.mkOption {
                  type = lib.types.submodule {
                    options = lib.mapAttrs (
                      name: _:
                      lib.mkOption {
                        type = lib.types.submodule {
                          options.enable = lib.mkEnableOption "the ${name} lefthook hook";
                        };
                        default = { };
                        description = "Configuration for the ${name} hook.";
                      }
                    ) available;
                  };
                  default = { };
                  description = "Per-hook configuration. Set `<hook>.enable = true` to activate.";
                };

                devShell = lib.mkOption {
                  type = lib.types.package;
                  readOnly = true;
                  internal = true;
                };
              };

              config.devShell = pkgs.mkShell {
                buildInputs = enabledHooks ++ [ pkgs.lefthook ];
                shellHook = ''
                  rm -f lefthook.local.yml
                  cat > lefthook.local.yml <<'EOF'
                  extends:
                  ${lib.concatMapStringsSep "\n" (p: "  - ${p.passthru.lefthookFragment}") enabledHooks}
                  EOF
                  [ -f lefthook.yml ] || printf 'extends:\n  - lefthook.local.yml\n' > lefthook.yml
                  lefthook install
                '';
              };
            };
        in
        {
          mkShell =
            userConfig:
            (lib.evalModules {
              modules = [
                module
                userConfig
              ];
            }).config.devShell;
        }
      );

      packages = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          mkBin =
            name: runtimeInputs:
            pkgs.writeShellApplication {
              inherit name runtimeInputs;
              bashOptions = [ ];
              text = builtins.readFile (./scripts + "/${name}.sh");
              passthru.lefthookFragment = ./. + "/precommit-${name}.yml";
            };
        in
        {
          auto-commit = mkBin "auto-commit" [ pkgs.git ];
          format-go = mkBin "format-go" [ pkgs.gofumpt ];
          format-lua = mkBin "format-lua" [ pkgs.stylua ];
          format-nix = mkBin "format-nix" [ pkgs.nixfmt ];
          format-opentofu = mkBin "format-opentofu" [ pkgs.opentofu ];
          format-rust = mkBin "format-rust" [ pkgs.rustfmt ];
          format-shell = mkBin "format-shell" [
            pkgs.shfmt
            pkgs.shellharden
          ];
          format-toml = mkBin "format-toml" [ pkgs.taplo ];
          format-yaml = mkBin "format-yaml" [ pkgs.yamlfmt ];
          format-zig = mkBin "format-zig" [ pkgs.zig ];
          lint-go = mkBin "lint-go" [ pkgs.golangci-lint ];
          lint-nix = mkBin "lint-nix" [
            pkgs.deadnix
            pkgs.statix
          ];
          lint-opentofu = mkBin "lint-opentofu" [ pkgs.tflint ];
          lint-shell = mkBin "lint-shell" [ pkgs.shellcheck ];
          security-gitleaks = mkBin "security-gitleaks" [ pkgs.gitleaks ];
          security-opentofu = mkBin "security-opentofu" [ pkgs.trivy ];
        }
      );

      devShells = nixpkgs.lib.genAttrs systems (system: {
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
      });
    };
}
