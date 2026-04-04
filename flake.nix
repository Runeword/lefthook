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
          { pkgs, modules }:
          let
            eval = nixpkgs.lib.evalModules {
              modules = [
                ./lib/options.nix
                { _module.args = { inherit pkgs self; }; }
              ]
              ++ modules;
            };
            configFile = (pkgs.formats.yaml { }).generate "lefthook-local" {
              extends = eval.config.configFiles;
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
        format-shell = ./modules/format-shell.nix;
        format-toml = ./modules/format-toml.nix;
        format-yaml = ./modules/format-yaml.nix;
        lint-go = ./modules/lint-go.nix;
        lint-shell = ./modules/lint-shell.nix;
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
              auto-msg
              format-nix
              format-shell
              format-toml
              format-yaml
              lint-shell
            ];
          };
        }
      );
    };
}
