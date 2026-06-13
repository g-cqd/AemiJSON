#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift format --in-place --recursive Sources Tests
echo "formatted Sources and Tests"
