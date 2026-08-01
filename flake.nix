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
          # Spelled with the `lanes` shorthand this flake recommends, so a hook
          # later added to one of these lanes reaches its own dev shell and
          # committed config too — naming hooks individually silently opted the
          # flagship repo out of the semantics it documents.
          default = self.lib.${system}.mkShell {
            lanes = [
              "nix"
              "shell"
              "toml"
              "yaml"
            ];
            gitleaks = true;
            autoCommit = true;
          };
        }
      );

      checks = forAllSystems (
        {
          system,
          pkgs,
          lib,
          ...
        }:
        {
          # The dev shell exercises 4 of the 9 lanes, so without this the go,
          # lua, opentofu, rust and zig hooks are never rendered, never loaded
          # by lefthook, and their tools never even evaluated — a nixpkgs bump
          # that breaks one first fails at a consumer's `nix develop`.
          #
          # This renders every hook, loads the result through the same `extends`
          # indirection consumers use, and forces each tool's derivation to
          # instantiate — instantiate, not build, so a removed attribute or an
          # insecure-marked package is caught without pulling every toolchain in
          # nixpkgs through the cache on each check.
          #
          # `lefthook dump` merges the two files but enforces neither
          # `min_version` nor `assert_lefthook_installed`; both bite at `run`
          # time, so this check does not cover them.
          lefthook-all-lanes =
            let
              args = {
                lanes = lib.attrNames (
                  lib.groupBy (h: h.lane) (
                    lib.filter (h: h ? lane) (lib.attrValues (import ./hooks.nix { inherit pkgs; }))
                  )
                );
                gitleaks = true;
                autoCommit = true;
              };
              rendered = (self.lib.${system}.mkShell args).lefthookConfig;
              # deepSeq, not a bare `builtins.length`: length forces only the
              # list spine, so the drvPath thunks would never be evaluated and
              # this check would pass on a toolchain that cannot instantiate.
              toolsInstantiated =
                let
                  paths = map (p: p.drvPath) (self.lib.${system}.toolchain args);
                in
                builtins.deepSeq paths (builtins.length paths);
            in
            pkgs.runCommand "check-lefthook-all-lanes"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.lefthook
                ];
                inherit toolsInstantiated;
              }
              ''
                export HOME="$TMPDIR"
                cd "$TMPDIR"
                git init -q
                cp ${rendered} lefthook-generated.yml
                printf 'extends:\n  - lefthook-generated.yml\n' >lefthook.yml
                lefthook dump >/dev/null
                touch "$out"
              '';

          # The committed config must match what the flake renders, and
          # lefthook must be able to load it. Built with the same
          # `mkConfigCheck` every consumer gets from `mkShell`'s passthru, so
          # the exported check is itself under test here.
          lefthook-config = self.devShells.${system}.default.mkConfigCheck self;
        }
      );
    };
}
