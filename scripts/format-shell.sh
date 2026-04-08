#!/bin/sh
shfmt --write --diff --indent 2 --case-indent --language-dialect posix --simplify "$@" &&
  shellharden --replace "$@"
