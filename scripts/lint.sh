#!/usr/bin/env bash
# Runs the formatter check used in CI. Pass --fix to rewrite files in place.
# SwiftLint is not used: it needs sourcekitd, which ships with Xcode only.
set -euo pipefail

if [[ "${1:-}" == "--fix" ]]; then
  swift-format format --in-place --recursive Sources Tests Package.swift
else
  swift-format lint --strict --recursive Sources Tests Package.swift
fi
