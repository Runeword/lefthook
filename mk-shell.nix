# Module-style factory that turns a set of enabled hooks into a dev shell.
#
# Ordering is expressed as data, not inferred from attribute-set order:
#   - `guard` jobs (pathspec-guard) come first,
#   - lanes run in parallel under a `main` job,
#   - jobs within a lane are piped in `order` (format -> lint -> security),
#   - `finalize` jobs (auto-commit) come after `main`,
#   - `pre-commit` itself is piped, so a failing guard blocks everything and a
#     failing lane blocks `finalize`.
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
        (h.guard or false)
        (h.finalize or false)
      ] != 1
    then
      throw "hooks.nix: hook '${name}' must declare exactly one of lane/standalone/guard/finalize"
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

  # `guard` jobs are piped before everything else and `finalize` jobs after
  # `main`, so with more than one hook in either role the sequence would fall
  # back to attribute name — the same failure `validLaneOrders` exists to
  # reject for lanes. Latent while each role has a single hook; guarded before
  # that stops being.
  validRoleOrders =
    role:
    let
      inRole = filter (h: h.${role} or false) (attrValues hooks);
      nameOf = h: head (filter (n: hooks.${n} == h) (attrNames hooks));
      names = concatStringsSep ", " (map nameOf inRole);
      orders = map (h: h.order or null) inRole;
    in
    if builtins.length inRole <= 1 then
      true
    else if elem null orders then
      throw "hooks.nix: with more than one ${role} hook each must declare an order (${names})"
    else if unique orders != orders then
      throw "hooks.nix: duplicate order among ${role} hooks (${names})"
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
    && validRoleOrders "guard"
    && validRoleOrders "finalize"
    && validShorthands;

  # Build the `pre-commit` settings block from the enabled hook names.
  mkPreCommit =
    enabledNames:
    let
      enabled = map (name: hooks.${name}) enabledNames;

      laned = filter (h: h ? lane) enabled;
      standalone = filter (h: h.standalone or false) enabled;
      guard = filter (h: h.guard or false) enabled;
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
      # Sorted by `order`, not attribute name — validRoleOrders requires one as
      # soon as there is more than a single hook in the role to sequence.
      byOrder = sort (a: b: (a.order or 0) < (b.order or 0));
      guardJobs = concatMap (h: h.jobs) (byOrder guard);
      finalizeJobs = concatMap (h: h.jobs) (byOrder finalize);
      # Jobs an enabled hook contributes ahead of `main`, after the guards, so
      # they observe the worktree before any formatter touches it
      # (auto-commit's `--prepare` snapshot). A single source today, so
      # attribute order is deterministic without an ordering validator like
      # validRoleOrders; add one here if a second hook ever contributes.
      prepareJobs = concatMap (h: h.prepareJobs or [ ]) enabled;
    in
    {
      piped = true;
      # `main` is omitted when empty (e.g. only auto-commit enabled): lefthook
      # errors out on a group with no jobs. Guard jobs lead it, then prepare
      # jobs, and finalize jobs follow, all sequenced by the top-level `piped`.
      jobs =
        guardJobs
        ++ prepareJobs
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
      # Whether an enabled hook other than a guard has a job that stages its
      # fix: lefthook then hands the staged names to git as patterns, which is
      # what a guard checks first. Guards are left out of the test, so a
      # guard's own default never depends on itself.
      staging = builtins.any (
        name:
        !(hooks.${name}.guard or false)
        && config.hooks.${name}.enable
        && builtins.any (j: j.stage_fixed or false) hooks.${name}.jobs
      ) (attrNames hooks);
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
        # either direction — takes precedence over them. So is a guard's
        # default, on wherever an enabled job stages its fix.
        hooks = mapAttrs (
          name: h:
          let
            byLane = h ? lane && elem h.lane config.lanes;
            byFlag = builtins.any (flag: shorthandHooks.${flag} == name && config.${flag}) (
              attrNames shorthandHooks
            );
            byStaging = (h.guard or false) && staging;
          in
          {
            enable = mkDefault (byLane || byFlag || byStaging);
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
                let
                  # wire-repo writes the config at the repository's top level,
                  # but a flake in a subdirectory (nix/flake.nix) gets a `self`
                  # rooted in that subdirectory; its sourceInfo is the top.
                  root = if builtins.isAttrs src && src ? sourceInfo then src.sourceInfo else src;
                in
                pkgs.runCommand "check-lefthook-config"
                  {
                    nativeBuildInputs = [
                      pkgs.git
                      pkgs.lefthook
                    ];
                  }
                  ''
                    # A flake sees only the files git tracks: a config the
                    # shell wrote but nobody added is missing here, and
                    # regenerating it would not help.
                    if [ ! -e ${root}/lefthook-generated.yml ]; then
                      echo "lefthook: lefthook-generated.yml is not in the flake's source;" >&2
                      echo "lefthook: flakes only see tracked files: git add lefthook-generated.yml lefthook.yml" >&2
                      exit 1
                    fi

                    # The committed copy must match what the flake renders.
                    if ! cmp ${root}/lefthook-generated.yml ${configFile}; then
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
              # The hooks themselves, run over every file of `src` the way the
              # README's CI command runs them, through the repository's own
              # lefthook config: a linter failure or a file a formatter would
              # change fails the check. In a fresh repository with everything
              # staged, security-gitleaks scans the whole tree.
              # Excluded: auto-commit (it would commit), pathspec-guard (with
              # everything staged and nothing committed it has nothing to
              # guard, and a name it refuses would only fail the check), and
              # the jobs that need the network or the project's own toolchain,
              # which the build sandbox has neither of (Go modules for lint-go,
              # tflint plugins, trivy's checks bundle) — run those with the CI
              # command.
              mkHooksCheck =
                src:
                let
                  # As in mkConfigCheck: the whole repository, not the
                  # subdirectory a nested flake's `self` is rooted in.
                  root = if builtins.isAttrs src && src ? sourceInfo then src.sourceInfo else src;
                in
                pkgs.runCommand "check-lefthook-hooks"
                  {
                    nativeBuildInputs = config.toolchain ++ [ pkgs.git ];
                    # Every job of the hooks named above.
                    LEFTHOOK_EXCLUDE = concatStringsSep "," (
                      concatMap (name: map (j: j.name) (hooks.${name}.jobs ++ (hooks.${name}.prepareJobs or [ ]))) [
                        "auto-commit"
                        "pathspec-guard"
                        "lint-go"
                        "lint-opentofu"
                        "security-opentofu"
                      ]
                    );
                  }
                  ''
                    export HOME="$TMPDIR"
                    cp -r --no-preserve=mode ${root} "$TMPDIR/src"
                    cd "$TMPDIR/src"
                    git init -q
                    # Wired as lefthook-init wires a checkout, minus the hooks:
                    # this shell's own render, whatever is committed (drift is
                    # mkConfigCheck's job), and the stub lefthook.yml only where
                    # the repository has no main config under any name lefthook
                    # reads, so that its own config runs, as its commits load
                    # it. (Written regardless, the stub replaced a lefthook.yml
                    # and shadowed any other name.) Before staging, so that the
                    # files are part of the tree the hooks see like everything
                    # else, and writable, as in a checkout: a formatter that
                    # would change the render must fail the check for that, not
                    # for a read-only copy.
                    ${wrappers.wire-repo}/bin/wire-repo ${configFile} lefthook --no-install
                    # --force: the source is exactly the tracked files, some of
                    # which a .gitignore may match.
                    git add --all --force
                    lefthook run pre-commit --no-auto-install --no-tty --colors off --fail-on-changes
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

  # The same packages as one installable environment, for
  # `nix profile install` — the command `lefthook-init` prints when the tools
  # its config calls are not on PATH. Same arguments as `mkShell`, plus an
  # optional `only`: the programs to install, by the bare name a `run:` line
  # calls them. lefthook-init passes the ones missing from PATH: a package the
  # profile already has (lefthook, typically: the scaffolder just ran it)
  # collides with its copy here and fails the whole install. A name no package
  # provides fails here, rather than install less than was asked for.
  toolchainEnv =
    args:
    let
      packages = (eval (if builtins.isAttrs args then removeAttrs args [ "only" ] else args)).toolchain;
      program = p: p.meta.mainProgram or (lib.getName p);
      programs = map program packages;
      only = args.only or programs;
      unknown = lib.subtractLists programs only;
    in
    if unknown != [ ] then
      throw "lefthook: toolchainEnv: no package of this toolchain provides ${concatStringsSep ", " unknown}"
    else
      pkgs.buildEnv {
        name = "lefthook-toolchain";
        paths = filter (p: elem (program p) only) packages;
      };
}
