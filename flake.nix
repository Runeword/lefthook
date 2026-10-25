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

      # mkBehaviourCheck PKGS NAME EXTRA-INPUTS ENV: tests/NAME.sh, with
      # EXTRA-INPUTS on PATH and ENV, the wrappers and renders it uses, in its
      # environment. Only those: a change to another wrapper does not run it
      # again.
      mkBehaviourCheck =
        pkgs: name: extraInputs: env:
        pkgs.runCommand "check-behaviour-${name}"
          (
            {
              nativeBuildInputs = [
                pkgs.coreutils
                pkgs.diffutils
                pkgs.findutils
                pkgs.gawk
                pkgs.git
                pkgs.gnugrep
                pkgs.gnused
                pkgs.lefthook
                pkgs.procps
              ]
              ++ extraInputs;
              REAL_GIT = "${pkgs.git}/bin/git";
              TEST_LIB = ./tests/lib.sh;
            }
            // env
          )
          ''
            export HOME=$TMPDIR/home
            mkdir -p "$HOME"
            git config --global user.name test
            git config --global user.email test@example.com
            git config --global init.defaultBranch main
            git config --global advice.detachedHead false
            bash ${./tests + "/${name}.sh"}
            touch "$out"
          '';
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
        let
          hooks = import ./hooks.nix { inherit pkgs; };
          wrappers = import ./wrappers.nix { inherit pkgs; };
          bin = w: "${wrappers.${w}}/bin/${w}";
          render = args: (self.lib.${system}.mkShell args).lefthookConfig;
        in
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
                lanes = lib.attrNames (lib.groupBy (h: h.lane) (lib.filter (h: h ? lane) (lib.attrValues hooks)));
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
              # lefthook-init's install command passes `only` the missing
              # programs by the first word of their `run:` (past any
              # VAR=value), plus lefthook. toolchainEnv throws when no package
              # has such a name as its main program: forced here, that happens
              # in this repository instead of at a consumer.
              onlyResolves =
                let
                  runs = lib.concatMap (h: map (j: j.run) (h.jobs ++ (h.prepareJobs or [ ]))) (lib.attrValues hooks);
                  program = run: lib.elemAt (builtins.match "([A-Za-z_][A-Za-z0-9_]*=[^ ]* )*([^ ]+).*" run) 1;
                  env = self.lib.${system}.toolchainEnv (
                    args // { only = lib.unique (map program runs) ++ [ "lefthook" ]; }
                  );
                in
                builtins.seq env.drvPath true;
            in
            pkgs.runCommand "check-lefthook-all-lanes"
              {
                nativeBuildInputs = [
                  pkgs.git
                  pkgs.lefthook
                ];
                inherit toolsInstantiated onlyResolves;
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

          # This repository's own hooks over its own tree, through the same
          # exported `mkHooksCheck` consumers use.
          lefthook-hooks = self.devShells.${system}.default.mkHooksCheck self;

          # The same check over consumer-shaped repositories: it runs their
          # own lefthook config, not a stub in its place.
          lefthook-hooks-own-config = import ./tests/hooks-check.nix {
            inherit pkgs;
            inherit (self.lib.${system}) mkShell;
          };

          # Behavioural checks: tests/<name>.sh drives the wrappers through
          # real commits in the build sandbox (real git and lefthook, no
          # network, a throwaway HOME). A known limitation is recorded as an
          # expected failure, so these go red on a regression AND when a
          # limitation is lifted without its documentation being updated.
          # The renders a suite commits through make it go red when the render
          # changes what it pins.
          behaviour-auto-commit = mkBehaviourCheck pkgs "auto-commit" [ ] {
            AUTO_COMMIT = bin "auto-commit";
          };
          # yamlfmt for the formatter of GUARD_CONFIG. The renders: a
          # formatter's (the guard first), one where nothing stages a fix (no
          # guard), a formatter's with auto-commit and the guard turned off, and
          # that one as configs rendered before the guard existed start: no
          # guard job, and a prepare pass without --no-guard.
          behaviour-pathspec-guard =
            let
              guardOff = render {
                lanes = [ "yaml" ];
                autoCommit = true;
                hooks.pathspec-guard.enable = false;
              };
            in
            mkBehaviourCheck pkgs "pathspec-guard" [ pkgs.yamlfmt ] {
              AUTO_COMMIT = bin "auto-commit";
              PATHSPEC_GUARD = bin "pathspec-guard";
              GUARD_CONFIG = render { hooks.format-yaml.enable = true; };
              NO_STAGING_CONFIG = render {
                gitleaks = true;
                autoCommit = true;
              };
              GUARD_OFF_CONFIG = guardOff;
              PREPARE_ONLY_CONFIG = pkgs.runCommand "lefthook-prepare-only.yml" { } ''
                sed 's/ --no-guard$//' ${guardOff} >"$out"
                if grep -q -e --no-guard "$out"; then
                  echo "PREPARE_ONLY_CONFIG: --no-guard is still in the render" >&2
                  exit 1
                fi
              '';
            };
          behaviour-security-gitleaks = mkBehaviourCheck pkgs "security-gitleaks" [ ] {
            SECURITY_GITLEAKS = bin "security-gitleaks";
          };
          behaviour-wire-repo = mkBehaviourCheck pkgs "wire-repo" [ ] {
            WIRE_REPO = bin "wire-repo";
          };
          # golangci-lint loads packages through the go command; the wrapper
          # takes it from the project's own toolchain, so supply one here. And
          # git-lfs, for a repository whose LFS objects were never downloaded.
          # The render: lint-go's jobs as the go lane renders them.
          behaviour-staged-tree =
            mkBehaviourCheck pkgs "staged-tree"
              [
                pkgs.go
                pkgs.git-lfs
              ]
              {
                LINT_GO = bin "lint-go";
                LINT_OPENTOFU = bin "lint-opentofu";
                SECURITY_OPENTOFU = bin "security-opentofu";
                LINT_GO_CONFIG = render { hooks.lint-go.enable = true; };
              };
        }
      );
    };
}
