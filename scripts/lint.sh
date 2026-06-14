#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Formatting gate across the package (single .swift-format).
swift format lint --strict --recursive Sources Tests Package.swift

# Shipped-library discipline: no force-cast / force-try / force-unwrap in Sources/ADJSON.
# (Tests and benchmarks are exempt — `try!` is idiomatic there.)
if grep -rnE '(\bas!|\btry!|baseAddress!|\.first!)' Sources/ADJSON; then
    echo "error: force cast / force try / force unwrap found in Sources/ADJSON" >&2
    exit 1
fi

# Locale safety: bare `strtod()` honours LC_NUMERIC and would misread "1.5" as 1.0 under a
# comma-decimal locale. Number parsing must stay on the locale-independent `Double(_:)`
# (see Core/Numbers.swift). Matches the call form only, so prose mentioning strtod is fine.
if grep -rn 'strtod(' Sources/ADJSON; then
    echo "error: locale-sensitive strtod() found in Sources/ADJSON; use Double(_:) instead" >&2
    exit 1
fi

echo "lint clean"
