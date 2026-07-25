# Hook definitions as ordered data.
#
# Each hook declares:
#   lane       language lane it belongs to. Lanes run in parallel; jobs within
#              a lane are piped in `order` (format = 0 -> lint = 1 -> security = 2).
#   standalone repo-wide job with no lane (e.g. gitleaks), run under `main`.
#   finalize   runs after `main` succeeds (auto-commit).
#   tools      packages placed on the dev-shell PATH for interactive use.
#   jobs       one or more lefthook jobs. `run` uses absolute store paths
#              (lib.getExe') so the generated config works even when git is
#              invoked from outside the dev shell (GUI clients, bare terminals).
#   stageFixed re-stage files the job rewrote (formatters), via lefthook's
#              native `stage_fixed`.
{ pkgs, lib }:
let
  inherit (lib) getExe';

  # Hooks with real logic keep a wrapper script (strict bash, pinned runtime
  # deps, shellcheck at build time). Passthrough one-liners are inlined below.
  autoCommit = pkgs.writeShellApplication {
    name = "auto-commit";
    runtimeInputs = [ pkgs.git ];
    text = builtins.readFile ./scripts/auto-commit.sh;
  };
  lintNix = pkgs.writeShellApplication {
    name = "lint-nix";
    runtimeInputs = [
      pkgs.deadnix
      pkgs.statix
    ];
    text = builtins.readFile ./scripts/lint-nix.sh;
  };
  lintOpentofu = pkgs.writeShellApplication {
    name = "lint-opentofu";
    runtimeInputs = [ pkgs.tflint ];
    text = builtins.readFile ./scripts/lint-opentofu.sh;
  };
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
        stageFixed = true;
        run = "${getExe' pkgs.gofumpt "gofumpt"} -w {staged_files}";
      }
    ];
  };

  lint-go = {
    lane = "go";
    order = 1;
    tools = [ pkgs.golangci-lint ];
    jobs = [
      {
        name = "lint-go";
        glob = "*.go";
        run = "${getExe' pkgs.golangci-lint "golangci-lint"} run";
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
        stageFixed = true;
        run = "${getExe' pkgs.stylua "stylua"} {staged_files}";
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
        stageFixed = true;
        run = "${getExe' pkgs.nixfmt "nixfmt"} {staged_files}";
      }
    ];
  };

  lint-nix = {
    lane = "nix";
    order = 1;
    tools = [
      pkgs.deadnix
      pkgs.statix
    ];
    jobs = [
      {
        name = "lint-nix";
        glob = "*.nix";
        run = "${getExe' lintNix "lint-nix"} {staged_files}";
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
        stageFixed = true;
        run = "${getExe' pkgs.opentofu "tofu"} fmt {staged_files}";
      }
    ];
  };

  lint-opentofu = {
    lane = "opentofu";
    order = 1;
    tools = [ pkgs.tflint ];
    jobs = [
      {
        name = "lint-opentofu";
        glob = "*.{tf,tofu}";
        run = getExe' lintOpentofu "lint-opentofu";
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
        run = "${getExe' pkgs.trivy "trivy"} config --quiet --exit-code 1 {staged_files}";
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
        stageFixed = true;
        run = "${getExe' pkgs.rustfmt "rustfmt"} {staged_files}";
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
        stageFixed = true;
        run = "${getExe' pkgs.shfmt "shfmt"} --write --indent 2 --case-indent --language-dialect posix --simplify {staged_files}";
      }
      {
        name = "shellharden";
        glob = "*.sh";
        stageFixed = true;
        run = "${getExe' pkgs.shellharden "shellharden"} --replace {staged_files}";
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
        run = "${getExe' pkgs.shellcheck "shellcheck"} {staged_files}";
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
        stageFixed = true;
        run = "RUST_LOG=warn ${getExe' pkgs.taplo "taplo"} format {staged_files}";
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
        stageFixed = true;
        run = "${getExe' pkgs.yamlfmt "yamlfmt"} {staged_files}";
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
        stageFixed = true;
        run = "${getExe' pkgs.zig "zig"} fmt {staged_files}";
      }
    ];
  };

  security-gitleaks = {
    standalone = true;
    tools = [ pkgs.gitleaks ];
    jobs = [
      {
        name = "security-gitleaks";
        run = "${getExe' pkgs.gitleaks "gitleaks"} git --pre-commit --redact --staged --verbose --no-banner --log-level=warn";
      }
    ];
  };

  auto-commit = {
    finalize = true;
    # No interactive tool: keep the user's own `git` first on PATH so a wrapped
    # git (e.g. one exporting GIT_CONFIG_GLOBAL) isn't shadowed by a bare
    # pkgs.git. The auto-commit script bakes in its own git via runtimeInputs.
    tools = [ ];
    jobs = [
      {
        name = "auto-commit";
        run = getExe' autoCommit "auto-commit";
      }
    ];
  };
}
