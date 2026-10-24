# mkHooksCheck over repositories shaped like consumers'. Each passes only
# because the check runs the repository's own lefthook config, as its commits
# do; with a stub lefthook.yml written in its place, each failed:
#   - exclude: lefthook.yml excludes vendor/**, where a script fails
#     shellcheck;
#   - dotted: the same config as .lefthook.yml, which a lefthook.yml shadows;
#   - yamlfmt: a .yamlfmt with indentless arrays that excludes the generated
#     file, and a lefthook.yml in its style. The stub, in yamlfmt's default
#     style, was rewritten by format-yaml, so no committed state passed both
#     this check and the drift check.
{ pkgs, mkShell }:
let
  shell = mkShell {
    lanes = [
      "shell"
      "yaml"
    ];
  };
  fixtures = pkgs.runCommand "lefthook-hooks-fixtures" { } ''
    own='extends:\n  - lefthook-generated.yml\npre-commit:\n  exclude:\n    - vendor/**\n'
    for d in exclude dotted; do
      mkdir -p "$out/$d/vendor"
      printf '#!/bin/sh\necho ok\n' >"$out/$d/ok.sh"
      printf '#!/bin/sh\necho $1\n' >"$out/$d/vendor/unquoted.sh"
    done
    printf "$own" >"$out/exclude/lefthook.yml"
    printf "$own" >"$out/dotted/.lefthook.yml"
    mkdir -p "$out/yamlfmt"
    printf 'exclude:\n  - lefthook-generated.yml\nformatter:\n  type: basic\n  indentless_arrays: true\n' >"$out/yamlfmt/.yamlfmt"
    printf 'extends:\n- lefthook-generated.yml\n' >"$out/yamlfmt/lefthook.yml"
    printf 'list:\n- a\n- b\n' >"$out/yamlfmt/data.yml"
  '';
in
pkgs.linkFarm "check-lefthook-hooks-own-config" (
  map
    (name: {
      inherit name;
      path = shell.mkHooksCheck "${fixtures}/${name}";
    })
    [
      "exclude"
      "dotted"
      "yamlfmt"
    ]
)
