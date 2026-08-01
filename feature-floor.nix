# The oldest lefthook the generated config supports, in one place because two
# things enforce it: `mk-shell.nix` asserts `minVersion >= this` when rendering,
# and `scripts/init.sh` both gates the runner it finds and stamps this value as
# the config's `min_version`.
#
# `jobs:` landed in 1.10.0, but the real floor is 1.13.0: below it the parallel
# lanes' post-format `git add` calls race `.git/index.lock`, `stage_fixed` fails
# with only a warning, and the commit lands the UN-formatted blobs (exit 0). An
# even older runner ignores every job and exits 0. Both leave a repository
# looking hooked while checking nothing.
"1.13.0"
