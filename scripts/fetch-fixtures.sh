#!/usr/bin/env bash
# Downloads third-party test/benchmark fixtures that are not vendored in-repo:
#   - simdjson / nativejson-benchmark corpus (Benchmarks/Corpus)
#   - nst/JSONTestSuite parsing corpus (Tests/.../Resources/JSONTestSuite)
#   - RFC 9535 JSONPath compliance test suite (Tests/.../Resources/JSONPathCTS)
# Run once after cloning to enable the corpus benchmarks and conformance tests.
set -euo pipefail
cd "$(dirname "$0")/.."

corpus="Benchmarks/Corpus"
mkdir -p "$corpus"
sj="https://raw.githubusercontent.com/simdjson/simdjson/master/jsonexamples"
curl -fsSL "$sj/twitter.json" -o "$corpus/twitter.json"
curl -fsSL "$sj/citm_catalog.json" -o "$corpus/citm_catalog.json"
curl -fsSL "https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/canada.json" -o "$corpus/canada.json"
echo "corpus: $(ls "$corpus"/*.json | wc -l | tr -d ' ') files"

suite="Tests/ADJSONTests/Resources/JSONTestSuite"
mkdir -p "$suite"
tmp="$(mktemp -d)"
curl -fsSL https://github.com/nst/JSONTestSuite/archive/refs/heads/master.tar.gz | tar -xz -C "$tmp"
cp "$tmp"/JSONTestSuite-master/test_parsing/*.json "$suite/"
rm -rf "$tmp"
echo "JSONTestSuite: $(ls "$suite"/*.json | wc -l | tr -d ' ') files"

cts="Tests/ADJSONTests/Resources/JSONPathCTS"
mkdir -p "$cts"
curl -fsSL https://raw.githubusercontent.com/jsonpath-standard/jsonpath-compliance-test-suite/main/cts.json -o "$cts/cts.json"
echo "JSONPath CTS: fetched"
