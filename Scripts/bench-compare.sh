#!/usr/bin/env bash
#
# bench-compare.sh — build + run the ADJSON benchmark suite standalone and render the
# ADJSON-vs-Foundation comparison table (Markdown) to stdout.
#
#   Scripts/bench-compare.sh                  # build release, run the suite, print the table
#   Scripts/bench-compare.sh capture.txt      # re-render a previously captured raw run
#   BENCH_FILTER='(decode|encode)/.*' Scripts/…  # restrict to workloads (anchored runner regexp)
#   BENCH_NO_BUILD=1 Scripts/bench-compare.sh  # reuse an already-built .build/release binary (CI)
#
# The suite target (ADJSONSuite) is gated behind ADJSON_DEV=1, which we set for the build.
# jemalloc backs the malloc-count metric; when it isn't resolvable via pkg-config we build with
# BENCHMARK_DISABLE_JEMALLOC=1 (per the suite's own docs) so the build still succeeds — the table
# then shows "—" for malloc. An explicit BENCHMARK_DISABLE_JEMALLOC in the environment always wins.
#
# Build/run diagnostics go to stderr; only the Markdown table reaches stdout, so it pipes cleanly
# into a CI job summary:  Scripts/bench-compare.sh >> "$GITHUB_STEP_SUMMARY"
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
awk_script="$root/Scripts/bench-compare.awk"

# Re-render an existing capture without running anything.
if [[ $# -ge 1 && -f "$1" ]]; then
    exec awk -f "$awk_script" "$1"
fi

export ADJSON_DEV=1

if [[ "${BENCH_NO_BUILD:-}" == "1" ]]; then
    # CI reuses the binary the `swift package benchmark` step already built — no second build.
    bin="$root/.build/release/ADJSONSuite"
    [[ -x "$bin" ]] || { echo "bench-compare: no prebuilt binary at $bin (build the suite first, or unset BENCH_NO_BUILD)" >&2; exit 1; }
else
    # Disable jemalloc only when it can't be resolved for the build (keeps malloc metrics on in CI,
    # where jemalloc + pkg-config are installed), unless the caller already pinned the variable.
    if [[ -z "${BENCHMARK_DISABLE_JEMALLOC:-}" ]] \
        && ! { command -v pkg-config >/dev/null 2>&1 && pkg-config --exists jemalloc 2>/dev/null; }; then
        export BENCHMARK_DISABLE_JEMALLOC=1
        echo "==> jemalloc not resolvable via pkg-config; building with BENCHMARK_DISABLE_JEMALLOC=1 (malloc metrics off)" >&2
    fi
    # Build the executable *product* (not --target): with jemalloc in the graph, `swift build
    # --target ADJSONSuite` compiles the module but skips linking the executable, leaving no binary.
    echo "==> Building ADJSONSuite (release)…" >&2
    swift build -c release --product ADJSONSuite >&2
    bin="$(swift build -c release --show-bin-path)/ADJSONSuite"
    [[ -x "$bin" ]] || { echo "bench-compare: build produced no executable at $bin" >&2; exit 1; }
fi

filter=()
[[ -n "${BENCH_FILTER:-}" ]] && filter=(--filter "$BENCH_FILTER")

echo "==> Running benchmarks…" >&2
"$bin" --quiet true "${filter[@]}" | awk -f "$awk_script"
