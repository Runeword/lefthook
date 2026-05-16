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
      lib = {
        mkShell =
          { pkgs, modules }:
          let
            inherit (nixpkgs) lib;
            eval = lib.evalModules {
              modules = [
                ./lib/options.nix
                { _module.args = { inherit pkgs self; }; }
              ]
              ++ modules;
            };
            # evalModules concatenates list-typed contributions in reverse
            # module-list order; reverse to restore the consumer's intent.
            extends = lib.unique (lib.reverseList eval.config.configFiles);
            configFile = (pkgs.formats.yaml { }).generate "lefthook-local" {
              inherit extends;
            };
          in
          pkgs.mkShell {
            buildInputs = eval.config.buildInputs ++ [ pkgs.lefthook ];
            shellHook = ''
              if [ "$(readlink lefthook.local.yml 2>/dev/null)" != "${configFile}" ]; then
                ln -sfn ${configFile} lefthook.local.yml
                lefthook uninstall
                lefthook install
              fi
              [ -f lefthook.yml ] || printf 'extends:\n  - lefthook.local.yml\n' > lefthook.yml
            '';
          };
        auto-msg = ./modules/auto-msg.nix;
        format-go = ./modules/format-go.nix;
        format-lua = ./modules/format-lua.nix;
        format-nix = ./modules/format-nix.nix;
        format-opentofu = ./modules/format-opentofu.nix;
        format-rust = ./modules/format-rust.nix;
        format-shell = ./modules/format-shell.nix;
        format-toml = ./modules/format-toml.nix;
        format-yaml = ./modules/format-yaml.nix;
        format-zig = ./modules/format-zig.nix;
        lint-go = ./modules/lint-go.nix;
        lint-nix = ./modules/lint-nix.nix;
        lint-opentofu = ./modules/lint-opentofu.nix;
        lint-shell = ./modules/lint-shell.nix;
        security-gitleaks = ./modules/security-gitleaks.nix;
        security-opentofu = ./modules/security-opentofu.nix;
      };
    in
    {
      inherit lib;
      devShells = nixpkgs.lib.genAttrs systems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          default = lib.mkShell {
            inherit pkgs;
            modules = with lib; [
              format-nix
              format-shell
              format-toml
              format-yaml
              lint-nix
              lint-shell
              auto-msg
            ];
          };
        }
      );
    };
}
