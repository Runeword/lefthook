#!/bin/sh
ec=0
deadnix --fail "$@" || ec=$?
for f in "$@"; do statix check "$f" || ec=$?; done
exit "$ec"
