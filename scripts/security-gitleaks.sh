#!/bin/sh
gitleaks git --pre-commit --redact --staged --verbose --no-banner --log-level=warn
