#!/bin/sh
trivy config --quiet --exit-code 1 "$@"
