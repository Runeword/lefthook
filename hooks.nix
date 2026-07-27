# Hook definitions as ordered data.
#
# Each hook declares:
#   lane       language lane it belongs to. Lanes run in parallel; jobs within
#              a lane are piped in `order` (format = 0 -> lint = 1 -> security = 2).
#   standalone repo-wide job with no lane (e.g. gitleaks), run under `main`.
#   finalize   runs after `main` succeeds (auto-commit).
#   tools      packages placed on the dev-shell PATH. `run` commands call them
#              by bare name, so the generated config is machine-independent and
#              meant to be committed; a commit made outside the dev shell fails
#              loudly (command not found) instead of running stale tools.
#   jobs       one or more verbatim lefthook job attrsets (name, run, glob,
#              stage_fixed, skip, ...), rendered into the config as-is.
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
        run = "gofumpt -w {staged_files}";
      }
    ];
  };

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
        run = "stylua {staged_files}";
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
        run = "nixfmt {staged_files}";
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
        run = "tofu fmt {staged_files}";
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
    tools = [ pkgs.trivy ];
    jobs = [
      {
        name = "security-opentofu";
        glob = "*.{tf,tofu,tfvars}";
        run = "trivy config --quiet --exit-code 1 {staged_files}";
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
        run = "rustfmt {staged_files}";
      }
    ];
  };

  # The shell lane pipes two formatters (shfmt, then shellharden) before lint.
  # `--diff` is intentionally dropped from shfmt: it makes shfmt exit non-zero
  # whenever it reformats, which would abort the piped lane before shellharden.
  format-shell = {
    lane = "shell";
    order = 0;
    tools = [
      pkgs.shfmt
      pkgs.shellharden
    ];
    jobs = [
      {
        name = "shfmt";
        glob = "*.sh";
        stage_fixed = true;
        run = "shfmt --write --indent 2 --case-indent --language-dialect posix --simplify {staged_files}";
      }
      {
        name = "shellharden";
        glob = "*.sh";
        stage_fixed = true;
        run = "shellharden --replace {staged_files}";
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
        glob = "*.sh";
        run = "shellcheck {staged_files}";
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
        run = "RUST_LOG=warn taplo format {staged_files}";
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
        run = "yamlfmt {staged_files}";
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

  security-gitleaks = {
    standalone = true;
    tools = [ pkgs.gitleaks ];
    jobs = [
      {
        name = "security-gitleaks";
        run = "gitleaks git --pre-commit --redact --staged --verbose --no-banner --log-level=warn";
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
