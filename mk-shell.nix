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
    concatStringsSep
    count
    elem
    filter
    head
    mapAttrs
    mkDefault
    mkEnableOption
    mkOption
    optional
    sort
    types
    unique
    ;

  # The shared repo-wiring step, also used by `lefthook-init`.
  wrappers = import ./wrappers.nix { inherit pkgs; };

  # The oldest lefthook the generated config supports. `jobs:` landed in 1.10.0,
  # but the real floor is 1.13.0: before it the parallel lanes' post-format
  # `git add` calls race `.git/index.lock`, `stage_fixed` fails with only a
  # warning, and the commit lands the UN-formatted blobs (exit 0). `min_version`
  # must never be stamped below this; the scaffolder enforces the same value on
  # the runner it finds.
  featureFloor = "1.13.0";

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

  # Two hooks sharing an `order` within a lane render without complaint and
  # then sequence by attribute name — reintroducing exactly the "ordering
  # follows attrset order" failure this design exists to prevent.
  validLaneOrders =
    let
      laned = filter (h: h ? lane) (attrValues hooks);
      nameOf = h: head (filter (n: hooks.${n} == h) (attrNames hooks));
      clash =
        laneName:
        let
          inLane = filter (h: h.lane == laneName) laned;
          orders = map (h: h.order) inLane;
          dupes = unique (filter (o: count (x: x == o) orders > 1) orders);
        in
        map (o: {
          lane = laneName;
          order = o;
          names = map nameOf (filter (h: h.order == o) inLane);
        }) dupes;
      clashes = concatMap clash laneNames;
    in
    if clashes == [ ] then
      true
    else
      throw (
        "hooks.nix: duplicate order within a lane — "
        + concatStringsSep "; " (
          map (c: "lane '${c.lane}' order ${toString c.order}: ${concatStringsSep ", " c.names}") clashes
        )
      );

  # `finalize` jobs are piped after `main`, so with more than one of them the
  # sequence would fall back to attribute name — the same failure
  # `validLaneOrders` exists to reject for lanes. Latent while auto-commit is
  # the only finalize hook; guarded before it stops being.
  validFinalizeOrders =
    let
      finalize = filter (h: h.finalize or false) (attrValues hooks);
      nameOf = h: head (filter (n: hooks.${n} == h) (attrNames hooks));
      names = concatStringsSep ", " (map nameOf finalize);
      orders = map (h: h.order or null) finalize;
    in
    if builtins.length finalize <= 1 then
      true
    else if elem null orders then
      throw "hooks.nix: with more than one finalize hook each must declare an order (${names})"
    else if unique orders != orders then
      throw "hooks.nix: duplicate order among finalize hooks (${names})"
    else
      true;

  # The `gitleaks` and `autoCommit` shorthands select their hooks by matching
  # names as strings, so renaming one in hooks.nix would silently stop enabling
  # it — the secret scan included — while `lanes` and `hooks.<name>` keep
  # validating. Fail on the rename instead.
  shorthandHooks = [
    "security-gitleaks"
    "auto-commit"
  ];
  validShorthands =
    let
      missing = filter (n: !(hooks ? ${n})) shorthandHooks;
    in
    if missing == [ ] then
      true
    else
      throw "mk-shell.nix: shorthand flags reference hooks missing from hooks.nix: ${concatStringsSep ", " missing}";

  # Asserted on every export, not just the dev shell, so `toolchain` consumers
  # cannot evaluate malformed hook data without hearing about it.
  hooksValid =
    builtins.all (name: validHook name hooks.${name}) (attrNames hooks)
    && validLaneOrders
    && validFinalizeOrders
    && validShorthands;

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
      # Sorted by `order`, not attribute name — validFinalizeOrders requires one
      # as soon as there is more than a single finalize hook to sequence.
      finalizeJobs = concatMap (h: h.jobs) (sort (a: b: (a.order or 0) < (b.order or 0)) finalize);
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

        # The generated config refuses to run on a lefthook older than this, so
        # it must not exceed the runner that will execute the hook. Defaults to
        # the feature floor — a true lower bound every supported runner meets —
        # rather than this flake's own lefthook, which would ratchet the demand
        # up on each `nix flake update` for no gain and reject older-but-adequate
        # runners. The scaffolder overrides it with the runner found on PATH,
        # which it has already gated at the same floor. Asserted `>= featureFloor`
        # on render so an explicit too-low value fails loudly, not silently.
        minVersion = mkOption {
          type = types.str;
          default = featureFloor;
          description = "Value stamped as the config's `min_version` (must be >= ${featureFloor}).";
        };

        autoCommit = mkOption {
          type = types.bool;
          default = false;
          description = "Shorthand for `hooks.auto-commit.enable`.";
        };

        # The shim lefthook writes ends its search for a binary with a bare
        # `echo` and exits 0, so once that binary is unreachable every hook is
        # skipped silently — secret scan included. Stamping this makes that
        # branch `exit 1` instead. `lefthook-init` gets the same protection the
        # same way — the setting travels in the rendered config it writes, so any
        # `lefthook install` bakes it into the shim. Defaults on for the same
        # reason: a hook that checks nothing should say so, not pass. `LEFTHOOK=0`
        # and `git commit --no-verify` remain the escape hatches.
        assertLefthookInstalled = mkOption {
          type = types.bool;
          default = true;
          description = "Value stamped as the config's `assert_lefthook_installed`.";
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
        # The empty-config warning lives here rather than on `devShell` because
        # the dev shell's `packages` forces this, so both entry points get it
        # once — and a global-install consumer whose config is empty or misspelt
        # hears about it too.
        toolchain =
          assert hooksValid;
          lib.warnIf (enabledNames == [ ])
            "lefthook: no hooks enabled — set `lanes`, `gitleaks`, `autoCommit` or `hooks.<name>.enable`, or this checks nothing"
            (hookTools ++ [ pkgs.lefthook ]);

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
              assert_lefthook_installed = config.assertLefthookInstalled;
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
          assert hooksValid;
          assert lib.assertMsg (!lib.versionOlder config.minVersion featureFloor) (
            "lefthook: minVersion '${config.minVersion}' is below the ${featureFloor} floor — "
            + "an older lefthook silently ignores the jobs syntax and loses stage_fixed fixes to an index.lock race"
          );
          # `mkShell { }` otherwise renders a valid do-nothing config, writes it
          # into the repo and installs hooks that check nothing, silently — the
          # warning for that comes from `toolchain`, which `packages` forces.
          pkgs.mkShell {
            # No bare git here: it would land on the interactive PATH and shadow a
            # user's wrapped git (one exporting GIT_CONFIG_GLOBAL for identity),
            # breaking `git commit` from inside the shell. The shellHook needs no
            # git of its own — wire-repo brings one inside its own process.
            packages = config.toolchain;
            # Exposed so the rendered config can be built and inspected directly:
            #   nix build .#devShells.<system>.default.lefthookConfig
            passthru.lefthookConfig = configFile;
            # Writes the config, seeds lefthook.yml, keeps lefthook-local.yml out
            # of the index, warns on core.hooksPath, and installs the hooks —
            # the same script `lefthook-init` runs, so the two paths cannot
            # drift. It carries its own git, so nothing here needs one on PATH
            # (a bare git would shadow a user's wrapped git and break commit
            # identity) and no subshell is needed to contain it.
            #
            # The shim's "can't find lefthook" branch exits 1 rather than 0
            # because the rendered config carries `assert_lefthook_installed`,
            # honoured since lefthook 1.4.8 and read through `extends`.
            shellHook = ''
              ${wrappers.wire-repo}/bin/wire-repo ${configFile} lefthook
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
