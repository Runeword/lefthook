# Module-style factory that turns a set of enabled hooks into a dev shell.
#
# Ordering is expressed as data, not inferred from attribute-set order:
#   - lanes run in parallel under a `main` job,
#   - jobs within a lane are piped in `order` (format -> lint -> security),
#   - `finalize` jobs (auto-commit) come after `main`,
#   - `pre-commit` itself is piped, so a failing lane blocks `finalize`.
#
# The rendered config calls tools by bare name and is copied into the
# consumer's repo as `lefthook-generated.yml`, meant to be committed: hooks
# then exist from `git checkout` onward (fresh clones, new worktrees, after
# garbage collection), independent of any machine's Nix store.
{
  pkgs,
  lib,
  hooks,
}:
let
  inherit (lib)
    attrNames
    attrValues
    concatMap
    count
    elem
    filter
    mapAttrs
    mkDefault
    mkEnableOption
    mkOption
    optional
    sort
    types
    unique
    ;

  # Every lane declared in hooks.nix — the domain of the `lanes` option.
  laneNames = sort (a: b: a < b) (unique (map (h: h.lane) (filter (h: h ? lane) (attrValues hooks))));

  # Reject malformed hook declarations loudly: a hook with zero roles would
  # silently vanish from the config, one with two would be emitted twice.
  validHook =
    name: h:
    if
      count (b: b) [
        (h ? lane)
        (h.standalone or false)
        (h.finalize or false)
      ] != 1
    then
      throw "hooks.nix: hook '${name}' must declare exactly one of lane/standalone/finalize"
    else if h ? lane && !(h ? order) then
      throw "hooks.nix: laned hook '${name}' must declare an order"
    else
      true;

  # Build the `pre-commit` settings block from the enabled hook names.
  mkPreCommit =
    enabledNames:
    let
      enabled = map (name: hooks.${name}) enabledNames;

      laned = filter (h: h ? lane) enabled;
      standalone = filter (h: h.standalone or false) enabled;
      finalize = filter (h: h.finalize or false) enabled;

      # One piped group per lane, jobs ordered format -> lint -> security.
      enabledLanes = sort (a: b: a < b) (unique (map (h: h.lane) laned));
      laneGroup =
        laneName:
        let
          inLane = sort (a: b: a.order < b.order) (filter (h: h.lane == laneName) laned);
        in
        {
          name = laneName;
          group = {
            piped = true;
            jobs = concatMap (h: h.jobs) inLane;
          };
        };

      mainJobs = map laneGroup enabledLanes ++ concatMap (h: h.jobs) standalone;
      finalizeJobs = concatMap (h: h.jobs) finalize;
    in
    {
      piped = true;
      # `main` is omitted when empty (e.g. only auto-commit enabled): lefthook
      # errors out on a group with no jobs. Finalize jobs follow it directly,
      # sequenced by the top-level `piped`.
      jobs =
        optional (mainJobs != [ ]) {
          name = "main";
          group = {
            parallel = true;
            jobs = mainJobs;
          };
        }
        ++ finalizeJobs;
    };

  module =
    { config, ... }:
    let
      enabledNames = filter (name: config.hooks.${name}.enable) (attrNames hooks);
      enabledHooks = map (name: hooks.${name}) enabledNames;
      # Every package the enabled hooks call by bare name.
      hookTools = concatMap (h: h.tools) enabledHooks;
    in
    {
      options = {
        hooks = mkOption {
          type = types.submodule {
            options = mapAttrs (
              name: _:
              mkOption {
                type = types.submodule {
                  options.enable = mkEnableOption "the ${name} lefthook hook";
                };
                default = { };
                description = "Configuration for the ${name} hook.";
              }
            ) hooks;
          };
          default = { };
          description = "Per-hook configuration. Set `<hook>.enable = true` to activate.";
        };

        # Shorthand: `lanes = [ "nix" ]` enables every hook in the nix lane,
        # instead of naming format-nix/lint-nix individually. Explicit
        # `hooks.<name>.enable` always wins over what a lane implies.
        lanes = mkOption {
          type = types.listOf (types.enum laneNames);
          default = [ ];
          example = [
            "nix"
            "shell"
          ];
          description = "Language lanes to enable, as a shorthand for the hooks they contain.";
        };

        gitleaks = mkOption {
          type = types.bool;
          default = false;
          description = "Shorthand for `hooks.security-gitleaks.enable`.";
        };

        # The generated config refuses to run on an older lefthook, so this
        # must describe the binary that will actually execute the hook. In a
        # dev shell that is this shell's lefthook; the scaffolder overrides it
        # with whatever it found on PATH.
        minVersion = mkOption {
          type = types.str;
          default = pkgs.lefthook.version;
          description = "Value stamped as the config's `min_version`.";
        };

        autoCommit = mkOption {
          type = types.bool;
          default = false;
          description = "Shorthand for `hooks.auto-commit.enable`.";
        };

        devShell = mkOption {
          type = types.package;
          readOnly = true;
          internal = true;
        };

        toolchain = mkOption {
          type = types.listOf types.package;
          readOnly = true;
          internal = true;
        };
      };

      config = {
        # Everything needed to RUN these hooks — the tools plus the lefthook
        # binary itself. Derived from hooks.nix, so a consumer installing this
        # globally (home-manager `home.packages`) can never drift from the
        # generated config the way a hand-written list does.
        toolchain = hookTools ++ [ pkgs.lefthook ];

        # The shorthands are mkDefault so an explicit hooks.<name>.enable — in
        # either direction — takes precedence over them.
        hooks = mapAttrs (
          name: h:
          let
            byLane = h ? lane && elem h.lane config.lanes;
            byFlag =
              (name == "security-gitleaks" && config.gitleaks) || (name == "auto-commit" && config.autoCommit);
          in
          {
            enable = mkDefault (byLane || byFlag);
          }
        ) hooks;

        devShell =
          let
            rawConfig = (pkgs.formats.yaml { }).generate "lefthook-generated-raw.yml" {
              min_version = config.minVersion;
              pre-commit = mkPreCommit enabledNames;
            };
            # Rendered through yamlfmt so the committed file is already canonical
            # for the format-yaml hook — otherwise every commit staging it would
            # reformat it away from what this flake regenerates.
            configFile = pkgs.runCommand "lefthook-generated.yml" { nativeBuildInputs = [ pkgs.yamlfmt ]; } ''
              install -m 644 ${rawConfig} "$out"
              yamlfmt "$out"
            '';
          in
          assert builtins.all (name: validHook name hooks.${name}) (attrNames hooks);
          pkgs.mkShell {
            # No bare git here: it would land on the interactive PATH and shadow a
            # user's wrapped git (one exporting GIT_CONFIG_GLOBAL for identity),
            # breaking `git commit` from inside the shell. The shellHook gets its
            # own git via an absolute store path instead.
            packages = config.toolchain;
            # Exposed so the rendered config can be built and inspected directly:
            #   nix build .#devShells.<system>.default.lefthookConfig
            passthru.lefthookConfig = configFile;
            shellHook = ''
              # Give the hook-install steps below a guaranteed git via an absolute
              # store path, WITHOUT putting a bare git on the interactive PATH
              # (that would shadow a user's wrapped git and break `git commit`).
              # The subshell keeps this PATH change from leaking to the shell.
              (
              export PATH=${pkgs.git}/bin:$PATH
              if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
                project_root=$(git rev-parse --show-toplevel)

                # Materialize the rendered config as a plain file, meant to be
                # committed: hooks then work from `git checkout` onward, with no
                # dependency on this machine's Nix store surviving GC.
                if ! cmp -s ${configFile} "$project_root/lefthook-generated.yml"; then
                  cp -f ${configFile} "$project_root/lefthook-generated.yml"
                  chmod 644 "$project_root/lefthook-generated.yml"
                fi

                # Migration: drop the git-ignored symlink older versions left.
                if [ -L "$project_root/.lefthook-generated.yml" ]; then
                  rm -f "$project_root/.lefthook-generated.yml"
                fi

                # lefthook merges lefthook-local.yml automatically; keep the
                # per-user override out of the index even in repos that don't
                # list it in a tracked .gitignore.
                exclude=$(git rev-parse --git-path info/exclude)
                mkdir -p "$(dirname "$exclude")"
                grep -qxF lefthook-local.yml "$exclude" 2>/dev/null \
                  || printf 'lefthook-local.yml\n' >>"$exclude"

                # Seed a root config only if the consumer doesn't have one; warn
                # when an existing one silently ignores the generated config.
                if [ -f "$project_root/lefthook.yml" ]; then
                  if ! grep -Eq '(^|[^.])lefthook-generated\.yml' "$project_root/lefthook.yml"; then
                    echo "lefthook: warning: lefthook.yml does not extend lefthook-generated.yml; generated hooks are inactive" >&2
                  fi
                else
                  printf 'extends:\n  - lefthook-generated.yml\n' >"$project_root/lefthook.yml"
                fi

                ( cd "$project_root" && lefthook install >/dev/null )
              else
                echo "lefthook: not inside a git work tree; skipping hook install" >&2
              fi
              )
            '';
          };
      };
    };

  eval =
    userConfig:
    (lib.evalModules {
      modules = [
        module
        userConfig
      ];
    }).config;
in
{
  # A dev shell that renders the config and installs the hooks on entry.
  mkShell = userConfig: (eval userConfig).devShell;

  # The packages those same hooks need at commit time, for consumers that
  # install globally instead of using a dev shell (see `lefthook-init`).
  # Same argument shape as `mkShell`.
  toolchain = userConfig: (eval userConfig).toolchain;
}
