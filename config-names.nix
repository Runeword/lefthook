# Every filename lefthook auto-loads, as two space-separated lists.
#
# lefthook discovers config as STEM x EXTENSION for a main and a "-local"
# family (internal/config/load.go). The two families behave differently and the
# callers rely on that:
#
#   * main configs shadow one another — `lefthook.yml` is first in the search
#     order, so writing one makes a repository's `.lefthook.yml` or
#     `.config/lefthook.yml` inert;
#   * local configs are merged UNCONDITIONALLY on top of whichever main config
#     won, so nothing shadows them.
#
# Shared by `scripts/init.sh` (which gates hook installation on any of them) and
# `scripts/wire-repo.sh` (which must not seed a `lefthook.yml` that would shadow
# a main config the repository already ships). Generated from the two axes, not
# listed by hand: a hand-written list previously omitted the whole `.config/`
# stem and the `.jsonc` extension, which silently reopened the hole the gate in
# init.sh exists to close.
let
  stems = [
    "lefthook"
    ".lefthook"
    ".config/lefthook"
  ];
  extensions = [
    "yml"
    "yaml"
    "json"
    "jsonc"
    "toml"
  ];
  names =
    suffix:
    builtins.concatStringsSep " " (
      builtins.concatMap (stem: map (ext: "${stem}${suffix}.${ext}") extensions) stems
    );
in
{
  main = names "";
  local = names "-local";
}
