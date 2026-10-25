# Hook definitions as ordered data.
#
# Each hook declares:
#   lane       language lane it belongs to. Lanes run in parallel; jobs within
#              a lane are piped in `order` (format = 0 -> lint = 1 -> security = 2).
#   standalone repo-wide job with no lane (e.g. gitleaks), run under `main`.
#   guard      runs before everything else (pathspec-guard). On by default
#              wherever another enabled hook has a job with `stage_fixed`: what
#              it guards is lefthook's staging of a formatter's fix.
#   finalize   runs after `main` succeeds (auto-commit).
#   tools      packages placed on the dev-shell PATH. `run` commands call them
#              by bare name, so the generated config is machine-independent and
#              meant to be committed. Outside the dev shell the names resolve
#              from whatever PATH holds: command not found where nothing
#              provides them, a global install's tools, at its own revision,
#              where one does.
#   jobs       one or more verbatim lefthook job attrsets (name, run, glob,
#              stage_fixed, skip, ...), rendered into the config as-is.
#
# `run` puts `--` before {staged_files} so a file named like a flag stays a
# file. Two deliberate exceptions: `zig fmt` rejects `--`, and the wrapper
# scripts below (lint-*, security-opentofu) would see it as their own first
# argument — they add `--` when they call the real tool instead. Note also that {staged_files} must stay
# UNQUOTED: lefthook shell-escapes each path, and wrapping it in quotes of your
# own undoes that and reopens command injection.
{ pkgs }:
let
  # Hooks with real logic keep a wrapper script (strict bash, pinned runtime
  # deps, shellcheck at build time). Defined in wrappers.nix so flake.nix can
  # also expose them as packages. Passthrough one-liners are inlined below.
  wrappers = import ./wrappers.nix { inherit pkgs; };
in
{
  format-go = {
    lane = "go";
    order = 0;
    tools = [ pkgs.gofumpt ];
    jobs = [
      {
        name = "format-go";
        glob = "*.go";
        stage_fixed = true;
        run = "gofumpt -w -- {staged_files}";
      }
    ];
  };

  # lefthook leaves a deleted file out of {staged_files} and skips a job left
  # with none, so the first job does not run for a commit whose only Go change
  # is a deletion. The second has no file template and no glob, so lefthook
  # runs it for every commit, after the first: it lints the packages that lost
  # a .go file, unless the first job linted them already for what is staged
  # (scripts/lint-go.sh). No glob, because lefthook lists a renamed file by its
  # new name only: x.go renamed to x.go.orig matched none.
  # tests/staged-tree.sh commits through this exact render.
  lint-go = {
    lane = "go";
    order = 1;
    tools = [
      pkgs.golangci-lint
      wrappers.lint-go
    ];
    jobs = [
      {
        name = "lint-go";
        glob = "*.go";
        run = "lint-go {staged_files}";
      }
      {
        name = "lint-go-deletions";
        run = "lint-go --deletions";
      }
    ];
  };

  format-lua = {
    lane = "lua";
    order = 0;
    tools = [ pkgs.stylua ];
    jobs = [
      {
        name = "format-lua";
        glob = "*.lua";
        stage_fixed = true;
        run = "stylua -- {staged_files}";
      }
    ];
  };

  format-nix = {
    lane = "nix";
    order = 0;
    tools = [ pkgs.nixfmt ];
    jobs = [
      {
        name = "format-nix";
        glob = "*.nix";
        stage_fixed = true;
        run = "nixfmt -- {staged_files}";
      }
    ];
  };

  lint-nix = {
    lane = "nix";
    order = 1;
    tools = [
      pkgs.deadnix
      pkgs.statix
      wrappers.lint-nix
    ];
    jobs = [
      {
        name = "lint-nix";
        glob = "*.nix";
        run = "lint-nix {staged_files}";
      }
    ];
  };

  format-opentofu = {
    lane = "opentofu";
    order = 0;
    tools = [ pkgs.opentofu ];
    jobs = [
      {
        name = "format-opentofu";
        glob = "*.{tf,tofu,tfvars}";
        stage_fixed = true;
        run = "tofu fmt -- {staged_files}";
      }
    ];
  };

  lint-opentofu = {
    lane = "opentofu";
    order = 1;
    tools = [
      pkgs.tflint
      wrappers.lint-opentofu
    ];
    jobs = [
      {
        name = "lint-opentofu";
        glob = "*.{tf,tofu}";
        run = "lint-opentofu {staged_files}";
      }
    ];
  };

  security-opentofu = {
    lane = "opentofu";
    order = 2;
    tools = [
      pkgs.trivy
      wrappers.security-opentofu
    ];
    jobs = [
      {
        name = "security-opentofu";
        glob = "*.{tf,tofu,tfvars}";
        run = "security-opentofu {staged_files}";
      }
    ];
  };

  format-rust = {
    lane = "rust";
    order = 0;
    tools = [ pkgs.rustfmt ];
    jobs = [
      {
        name = "format-rust";
        glob = "*.rs";
        stage_fixed = true;
        run = "rustfmt -- {staged_files}";
      }
    ];
  };

  # The shell lane formats with shfmt, then lints with shellcheck.
  # `--diff` is intentionally dropped from shfmt: it makes shfmt exit non-zero
  # whenever it reformats, which would abort the piped lane before lint runs.
  # `--language-dialect auto` (not `posix`): shfmt reads the shebang, so a
  # consumer's `#!/bin/bash` script is formatted as bash while this repo's own
  # `#!/bin/sh` scripts still get POSIX treatment. Hard-coding `posix` made
  # shfmt exit 1 on any bash feature (arrays, `[[ ]]`) in a `*.sh` file — the
  # standard bash extension — so a scaffolded repo could not commit those files.
  #
  # shellharden was REMOVED from this lane and must not be re-added; see the
  # "no auto-fixer may outrank its own linter" invariant in CLAUDE.md.
  format-shell = {
    lane = "shell";
    order = 0;
    tools = [ pkgs.shfmt ];
    jobs = [
      {
        name = "shfmt";
        glob = "*.{sh,bash}";
        stage_fixed = true;
        run = "shfmt --write --indent 2 --case-indent --language-dialect auto --simplify -- {staged_files}";
      }
    ];
  };

  lint-shell = {
    lane = "shell";
    order = 1;
    tools = [ pkgs.shellcheck ];
    jobs = [
      {
        name = "lint-shell";
        glob = "*.{sh,bash}";
        run = "shellcheck -- {staged_files}";
      }
    ];
  };

  format-toml = {
    lane = "toml";
    order = 0;
    tools = [ pkgs.taplo ];
    jobs = [
      {
        name = "format-toml";
        glob = "*.toml";
        stage_fixed = true;
        run = "RUST_LOG=warn taplo format -- {staged_files}";
      }
    ];
  };

  format-yaml = {
    lane = "yaml";
    order = 0;
    tools = [ pkgs.yamlfmt ];
    jobs = [
      {
        name = "format-yaml";
        glob = "*.{yml,yaml}";
        stage_fixed = true;
        run = "yamlfmt -- {staged_files}";
      }
    ];
  };

  format-zig = {
    lane = "zig";
    order = 0;
    tools = [ pkgs.zig ];
    jobs = [
      {
        name = "format-zig";
        glob = "*.{zig,zon}";
        stage_fixed = true;
        run = "zig fmt {staged_files}";
      }
    ];
  };

  # lefthook hands the staged names to git as patterns (pathspecs) when it
  # stages a formatter's fix: staging g*.txt also committed an ignored
  # gsecret.txt. This refuses such names before any formatter runs. No skip for
  # merges and rebases, where the formatters run too. It also keeps a copy of
  # lefthook's backup of the unstaged changes, which lefthook deletes, in
  # refs/lefthook/backup. scripts/pathspec-guard.sh says what it refuses and
  # why.
  pathspec-guard = {
    guard = true;
    tools = [ wrappers.pathspec-guard ];
    jobs = [
      {
        name = "pathspec-guard";
        run = "pathspec-guard";
      }
    ];
  };

  # A wrapper, not a pipeline in `run`: lefthook executes `run` through `sh -c`
  # with pipefail OFF, so `git diff … | gitleaks stdin` reported only gitleaks'
  # status and PASSED whenever the diff command failed. The wrapper also forces
  # `--text` past `.gitattributes` blinding, pins the ruleset so a repo-shipped
  # `.gitleaks.toml` cannot disable the scan, scans added lines only (so the
  # commit that REMOVES a secret is not blocked), and names the offending files.
  security-gitleaks = {
    standalone = true;
    tools = [ wrappers.security-gitleaks ];
    jobs = [
      {
        name = "security-gitleaks";
        run = "security-gitleaks";
      }
    ];
  };

  auto-commit = {
    finalize = true;
    # Only the wrapper (its `run` is the bare name `auto-commit`). NOT pkgs.git:
    # a bare git on the dev-shell PATH shadows a user's wrapped git (one
    # exporting GIT_CONFIG_GLOBAL for identity), breaking `git commit` from the
    # shell. The script bakes in its own git via runtimeInputs.
    tools = [ wrappers.auto-commit ];
    # A second job the renderer places ahead of `main`, right after the guards,
    # so it runs before any formatter. It snapshots which staged files' working
    # copies may already differ from the staged ones (unstaged changes, or a
    # file git does not compare); the finalize job below reads that to fold an
    # in-hook reformat into the split commits while preserving partial
    # staging. Needed because lefthook >= 2.1.7 defers `stage_fixed` to after
    # finalize jobs, so the index the finalize job sees would otherwise still
    # hold the pre-format blob. See scripts/auto-commit.sh. `--no-guard`:
    # without it the pass runs pathspec-guard itself, as configs rendered
    # before that job existed need; here the job has run already where it is
    # on, and where it is off, the guard stays off.
    prepareJobs = [
      {
        name = "auto-commit-prepare";
        run = "auto-commit --prepare --no-guard";
        skip = [
          "merge"
          "rebase"
        ];
      }
    ];
    jobs = [
      {
        name = "auto-commit";
        run = "auto-commit";
        # Redundant with the script's own passthrough guards, on purpose.
        skip = [
          "merge"
          "rebase"
        ];
      }
    ];
  };
}
