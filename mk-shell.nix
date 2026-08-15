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

  # Shared with scripts/init.sh, which gates the runner on it and stamps it as
  # the config's `min_version`. See feature-floor.nix for why 1.13.0.
  featureFloor = import ./feature-floor.nix;

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
  # Option name -> the hook it enables, in one place so the validator below and
  # the `byFlag` test in the module cannot disagree about either half.
  shorthandHooks = {
    gitleaks = "security-gitleaks";
    autoCommit = "auto-commit";
  };
  validShorthands =
    let
      missing = filter (n: !(hooks ? ${n})) (attrValues shorthandHooks);
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
      # Jobs an enabled hook contributes to the HEAD of the piped pre-commit,
      # before `main`, so they observe the worktree before any formatter touches
      # it (auto-commit's `--prepare` snapshot). A single source today, so
      # attribute order is deterministic without an ordering validator like the
      # finalize one; add that guard here if a second hook ever contributes.
      prepareJobs = concatMap (h: h.prepareJobs or [ ]) enabled;
    in
    {
      piped = true;
      # `main` is omitted when empty (e.g. only auto-commit enabled): lefthook
      # errors out on a group with no jobs. Prepare jobs lead it and finalize
      # jobs follow, all sequenced by the top-level `piped`.
      jobs =
        prepareJobs
        ++ optional (mainJobs != [ ]) {
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
            byFlag = builtins.any (flag: shorthandHooks.${flag} == name && config.${flag}) (
              attrNames shorthandHooks
            );
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
            # Warned here as well as on `toolchain`: building only
            # `.lefthookConfig` (the documented way to regenerate the committed
            # file) forces neither `packages` nor the shell, so without this the
            # regeneration path could write a checks-nothing config in silence.
            configFile =
              lib.warnIf (enabledNames == [ ])
                "lefthook: no hooks enabled — set `lanes`, `gitleaks`, `autoCommit` or `hooks.<name>.enable`, or this checks nothing"
                pkgs.runCommand
                "lefthook-generated.yml"
                { nativeBuildInputs = [ pkgs.yamlfmt ]; }
                ''
                  install -m 644 ${rawConfig} "$out"
                  yamlfmt "$out"
                '';
            # The explicit "rewrite the committed config" step named by the
            # shellHook's drift warning. Bound to this exact render, so it can
            # never regenerate from a different hook set than the shell it came
            # from. Carries its own lefthook (same pin as `toolchain`), so it
            # also works from outside the shell.
            regen = pkgs.writeShellApplication {
              name = "lefthook-regen";
              runtimeInputs = [
                wrappers.wire-repo
                pkgs.lefthook
              ];
              text = ''
                exec wire-repo ${configFile} lefthook "$@"
              '';
            };
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
            packages = config.toolchain ++ [ regen ];
            passthru = {
              # Exposed so the rendered config can be built and inspected directly:
              #   nix build .#devShells.<system>.default.lefthookConfig
              lefthookConfig = configFile;
              # Drift enforcement for consumers — the same check this flake runs
              # on itself. Takes the repository source (usually `self`) and
              # asserts its committed lefthook-generated.yml byte-matches this
              # shell's render, then that lefthook can load the result. Built
              # from the same `configFile` as the shellHook and `lefthook-regen`,
              # so the check and the shell cannot disagree about what "in sync"
              # means. `inputsFrom` does not carry passthru, so keep a handle on
              # the inner shell:
              #   let lh = lefthook.lib.${system}.mkShell { … };
              #   in {
              #     devShells.default = pkgs.mkShell { inputsFrom = [ lh ]; };
              #     checks.lefthook-config = lh.mkConfigCheck self;
              #   }
              # `lefthook dump` merges but enforces neither `min_version` nor
              # `assert_lefthook_installed`; both bite at `run` time, not here.
              mkConfigCheck =
                src:
                pkgs.runCommand "check-lefthook-config"
                  {
                    nativeBuildInputs = [
                      pkgs.git
                      pkgs.lefthook
                    ];
                  }
                  ''
                    # The committed copy must match what the flake renders.
                    if ! cmp ${src}/lefthook-generated.yml ${configFile}; then
                      echo "lefthook: committed lefthook-generated.yml does not match the flake's render;" >&2
                      echo "lefthook: run 'lefthook-regen' in the dev shell and commit the result" >&2
                      exit 1
                    fi

                    # lefthook must be able to load the rendered config.
                    export HOME="$TMPDIR"
                    cd "$TMPDIR"
                    git init -q
                    cp ${configFile} lefthook.yml
                    lefthook dump >/dev/null
                    touch "$out"
                  '';
            };
            # Reconciles unversioned state — installs the hooks, seeds
            # lefthook.yml, keeps lefthook-local.yml out of the index, warns on
            # core.hooksPath — and creates lefthook-generated.yml only when it
            # is missing. When the committed file has merely drifted from the
            # render, `--warn-drift` prints the warning naming `lefthook-regen`
            # (on this shell's PATH) instead of rewriting a tracked file on
            # directory entry. Same script `lefthook-init` runs (in write mode),
            # so the two wiring paths cannot drift. It carries its own git, so
            # nothing here needs one on PATH (a bare git would shadow a user's
            # wrapped git and break commit identity) and no subshell is needed
            # to contain it.
            #
            # The shim's "can't find lefthook" branch exits 1 rather than 0
            # because the rendered config carries `assert_lefthook_installed`,
            # honoured since lefthook 1.4.8 and read through `extends`.
            shellHook = ''
              ${wrappers.wire-repo}/bin/wire-repo ${configFile} lefthook --warn-drift
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
