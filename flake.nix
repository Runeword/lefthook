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
      mkModule = path: import path { inherit self; };
      lib = {
        mkShell =
          pkgs: modules:
          let
            configFile = (pkgs.formats.yaml { }).generate "lefthook-local" {
              extends = map (m: m.configFile) modules;
            };
          in
          pkgs.mkShell {
            buildInputs = nixpkgs.lib.concatMap (m: m.buildInputs pkgs) modules ++ [ pkgs.lefthook ];
            shellHook = ''
              ln -sfn ${configFile} lefthook.local.yml
              lefthook install
            '';
          };
        auto-msg = mkModule ./modules/auto-msg.nix;
        format-nix = mkModule ./modules/format-nix.nix;
        format-shell = mkModule ./modules/format-shell.nix;
        format-toml = mkModule ./modules/format-toml.nix;
        format-yaml = mkModule ./modules/format-yaml.nix;
        lint-shell = mkModule ./modules/lint-shell.nix;
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
          default = lib.mkShell pkgs (
            with lib; [
              auto-msg
              format-nix
              format-shell
              format-toml
              format-yaml
              lint-shell
            ]
          );
        }
      );
    };
}
