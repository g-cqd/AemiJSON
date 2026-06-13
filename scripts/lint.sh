#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Strict gate on the shipped library: no force-unwrap / force-try / implicitly-unwrapped.
# The repo-wide .swift-format (used by editors/hooks) only enforces formatting, since
# tests and benchmarks legitimately use force-try.
swift format lint --strict --configuration .swift-format-strict --recursive Sources/ADJSON
echo "library lint clean"
