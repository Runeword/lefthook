# Module-style factory that turns a set of enabled hooks into a dev shell.
#
# Ordering is expressed as data, not inferred from attribute-set order:
#   - lanes run in parallel under a `main` job,
#   - jobs within a lane are piped in `order` (format -> lint -> security),
#   - `auto-commit` runs in a `finalize` job after `main`,
#   - `pre-commit` itself is piped, so a failing lane blocks `finalize`.
{
  pkgs,
  lib,
  hooks,
}:
let
  inherit (lib)
    attrNames
    concatMap
    filter
    mapAttrs
    mkEnableOption
    mkOption
    optional
    optionalAttrs
    sort
    types
    unique
    ;

  # A single lefthook job. Omit `glob`/`stage_fixed` when not set so the
  # generated YAML stays minimal.
  renderJob =
    job:
    {
      inherit (job) name run;
    }
    // optionalAttrs (job ? glob) { inherit (job) glob; }
    // optionalAttrs (job.stageFixed or false) { stage_fixed = true; };

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
            jobs = concatMap (h: map renderJob h.jobs) inLane;
          };
        };

      laneJobs = map laneGroup laneNames;
      standaloneJobs = concatMap (h: map renderJob h.jobs) standalone;
      finalizeJobs = concatMap (h: map renderJob h.jobs) finalize;

      mainJob = {
        name = "main";
        group = {
          parallel = true;
          jobs = laneJobs ++ standaloneJobs;
        };
      };

      finalizeJob = {
        name = "finalize";
        group = {
          parallel = true;
          jobs = finalizeJobs;
        };
      };
    in
    {
      piped = true;
      jobs = [ mainJob ] ++ optional (finalizeJobs != [ ]) finalizeJob;
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
          configFile = (pkgs.formats.yaml { }).generate "lefthook-generated.yml" {
            pre-commit = mkPreCommit enabledNames;
          };
        in
        pkgs.mkShell {
          buildInputs = tools ++ [ pkgs.lefthook ];
          # Exposed so the rendered config can be built and inspected directly:
          #   nix build .#devShells.<system>.default.lefthookConfig
          passthru.lefthookConfig = configFile;
          shellHook = ''
            if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
              project_root=$(git rev-parse --show-toplevel)

              # Link the generated config into the repo (machine-local, git-ignored).
              ln -sfn ${configFile} "$project_root/.lefthook-generated.yml"

              # Belt-and-suspenders: keep generated/local files out of the index
              # even in repos that don't list them in a tracked .gitignore.
              exclude=$(git rev-parse --git-path info/exclude)
              mkdir -p "$(dirname "$exclude")"
              for pat in .lefthook-generated.yml lefthook.local.yml; do
                grep -qxF "$pat" "$exclude" 2>/dev/null || printf '%s\n' "$pat" >>"$exclude"
              done

              # Seed a root config only if the consumer doesn't already have one.
              # lefthook.local.yml is left untouched for the user's own overrides.
              [ -f "$project_root/lefthook.yml" ] \
                || printf 'extends:\n  - .lefthook-generated.yml\n' >"$project_root/lefthook.yml"

              ( cd "$project_root" && lefthook install >/dev/null )
            else
              echo "lefthook: not inside a git work tree; skipping hook install" >&2
            fi
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
