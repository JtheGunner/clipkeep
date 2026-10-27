#!/usr/bin/env bash
# Runs the evaluation harness (search quality, time to result, session grouping) and compares
# it with eval/baseline.json. Exit code 1 means a regression. See eval/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
exec swift run -c release clipkeep-eval "$@"
