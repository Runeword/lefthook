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
    concatMap
    count
    filter
    mapAttrs
    mkEnableOption
    mkOption
    optional
    sort
    types
    unique
    ;

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
      laneNames = sort (a: b: a < b) (unique (map (h: h.lane) laned));
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

      mainJobs = map laneGroup laneNames ++ concatMap (h: h.jobs) standalone;
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

        devShell = mkOption {
          type = types.package;
          readOnly = true;
          internal = true;
        };
      };

      config.devShell =
        let
          enabledNames = filter (name: config.hooks.${name}.enable) (attrNames hooks);
          enabledHooks = map (name: hooks.${name}) enabledNames;
          tools = concatMap (h: h.tools) enabledHooks;
          rawConfig = (pkgs.formats.yaml { }).generate "lefthook-generated-raw.yml" {
            min_version = pkgs.lefthook.version;
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
          packages = tools ++ [ pkgs.lefthook ];
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
