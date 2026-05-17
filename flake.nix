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
        in
        {
          mkShell =
            { hooks }:
            let
              extendsLines = builtins.concatStringsSep "\n" (
                map (p: "  - ${self}/precommit-${p.name}.yml") hooks
              );
            in
            pkgs.mkShell {
              buildInputs = hooks ++ [ pkgs.lefthook ];
              shellHook = ''
                rm -f lefthook.local.yml
                cat > lefthook.local.yml <<'EOF'
                extends:
                ${extendsLines}
                EOF
                [ -f lefthook.yml ] || printf 'extends:\n  - lefthook.local.yml\n' > lefthook.yml
                lefthook install
              '';
            };
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

      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          hooks = self.packages.${system};
          enabled = [
            hooks.format-nix
            hooks.lint-nix
            hooks.format-shell
            hooks.lint-shell
            hooks.format-toml
            hooks.format-yaml
            hooks.auto-commit
          ];
        in
        {
          default = self.lib.${system}.mkShell { hooks = enabled; };
        }
      );
    };
}
