#!/bin/sh
if [ -f .tflint.hcl ]; then
  tflint --init || exit $?
fi
tflint --recursive
