#!/bin/sh
# Without paths deadnix scans the whole tree, so an empty argument list has to
# mean "nothing to do" rather than "lint everything".
[ "$#" -gt 0 ] || exit 0
ec=0
deadnix --fail -- "$@" || ec=$?
for f in "$@"; do statix check -- "$f" || ec=$?; done
exit "$ec"
