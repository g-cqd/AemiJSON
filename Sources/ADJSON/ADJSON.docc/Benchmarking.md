# Benchmarking

How ADJSON is measured, how to reproduce the numbers, and how to read them.

## Running the benchmarks

The suite runs on [ordo-one's `Benchmark`](https://github.com/ordo-one/benchmark) framework
(`Benchmarks/ADJSONSuite`), driven by the `benchmark` plugin. It is gated behind `ADJSON_DEV` so
consumers never resolve the framework. The standard corpus is third-party and fetched on demand
(not redistributed):

```sh
swift package --allow-network-connections all --allow-writing-to-package-directory fetch-fixtures
ADJSON_DEV=1 swift package benchmark            # all benchmarks
ADJSON_DEV=1 swift package benchmark list       # just list them
ADJSON_DEV=1 swift package benchmark run --filter "decode/.*"   # a subset
```

`Benchmark` measures malloc counts via **jemalloc** — `brew install jemalloc` (macOS) /
`apt-get install -y libjemalloc-dev` (Linux). Without it, set `BENCHMARK_DISABLE_JEMALLOC=1` to run
the time/throughput metrics only. Benchmarks always run in **release**. Without the corpus the
in-memory benchmarks still run; the `corpus/*` benchmarks are simply not registered.

## Methodology

The suite is statistically rigorous and honest:

- **Percentiles, not an average.** `Benchmark` auto-tunes the iteration count and reports the full
  wall-clock distribution (p50 / p90 / p99 / p100), so tail latency and jitter are visible — not
  hidden behind a single mean.
- **Metrics.** Wall-clock time, throughput (operations/second), and total `malloc` count per
  iteration (allocations are often the real cost in a JSON pipeline).
- **No dead-code elimination.** Every result is passed through the framework's `blackHole(_:)` so
  the optimizer can't delete the work being measured.
- **Side-by-side baselines.** Foundation's `JSONDecoder` / `JSONEncoder` / `JSONSerialization`
  appear as their own `…/Foundation` benchmarks next to the ADJSON variants, so their percentiles
  are directly comparable. Coders are created once and reused.
- **CI-gateable.** `swift package benchmark baseline` can record a baseline and fail on a
  threshold regression; CI publishes the percentile table to the run summary.

## What is measured

- **Untyped parse** `Data → tree`: Foundation `JSONSerialization` vs ADJSON tape parse, plus
  "parse + read two fields" (lazy), "parse + full walk" (touch every node), and full `JSONValue`
  materialization (an editable tree, the closest analogue to `JSONSerialization`).
- **Typed decode** `Data → [User]`: Foundation `JSONDecoder` vs ADJSON `JSONDecoder` on the
  generic `Codable` path vs the `@JSONCodable` fast path.
- **Typed encode** `[User] → Data` across the same three contenders.
- **Number-heavy** `[Double]` decode — the hard case for any parser.
- **Query** — JSONPath (RFC 9535) filter and wildcard over a pre-parsed document.
- **Validate** — JSON Schema (Draft 2020-12 subset) compiled once (here from `@Schemable`), run
  over a pre-parsed document, plus parse + validate end to end.
- **Mutate** — JSON Patch (RFC 6902) applied to a materialized `JSONValue`.
- **Concurrent decode** — serial vs `ADJSON.decodeArrayConcurrently` on a pre-parsed document.
- **Standard corpus** — `twitter.json`, `citm_catalog.json`, `canada.json`.

Every comparison pits the real public API against Foundation; where Foundation has no equivalent
(query, schema, patch) the row reports ADJSON's standalone throughput.

## Reference results

Apple M2 Pro (macOS 27), release build, strict mode. Each cell is the **median across 15 full
runs** (each run is itself the median of 60 iterations); run-to-run spread was within **±8%** for
every row except concurrent decode (±12%), with thermal throttling under sustained load the main
source. Your numbers will vary with hardware, OS, and payload; treat these as ratios, not absolutes.

**Against Foundation** (synthetic 2000-user payload ≈ 500 KB; corpus files as noted):

| Workload | ADJSON | Foundation | Ratio |
|---|---|---|---|
| Tape parse — `twitter.json` | 818 MB/s | 168 MB/s | **4.9×** |
| Tape parse — `citm_catalog.json` | 1146 MB/s | 302 MB/s | **3.8×** |
| Tape parse — `canada.json` | 743 MB/s | 114 MB/s | **6.5×** |
| Codable decode — generic | 66 MB/s | 40 MB/s | **1.6×** |
| Codable decode — `@JSONCodable` | 182 MB/s | 40 MB/s | **4.5×** |
| Codable encode — generic | 60 MB/s | 45 MB/s | **1.3×** |
| Codable encode — `@JSONCodable` | 358 MB/s | 45 MB/s | **8.0×** |
| `[Double]` decode | 161 MB/s | 72 MB/s | **2.2×** |
| `JSONValue` materialize — `twitter.json` | 199 MB/s | 168 MB/s | **1.2×** |
| `JSONValue` materialize — `citm_catalog.json` | 324 MB/s | 302 MB/s | **1.07×** |
| `JSONValue` materialize — `canada.json` | 131 MB/s | 114 MB/s | **1.1×** |

**ADJSON-only** (features Foundation has no equivalent for):

| Feature | Throughput |
|---|---|
| JSONPath wildcard — `$[*].profile.bio` | 2608 MB/s |
| JSONPath filter — `$[?(@.followers > N)]` | 917 MB/s |
| JSON Schema validate (pre-parsed, full structural) | 123 MB/s |
| JSON Patch apply (3 ops over a 2000-element tree) | 48 µs |
| Concurrent decode | 165 MB/s (**2.2×** serial) |

Tape parsing runs at roughly **1 GB/s**; partial/lazy access is faster still, since it skips
subtrees it never reads. Full `JSONValue` materialization now edges past `JSONSerialization`
across the corpus — it builds a comparable Swift tree in a single pass — though ADJSON's real
leverage remains the lazy tape and typed decode.

## Interpreting the numbers

- **Parse vs decode are different questions.** Untyped parse builds only the tape; Codable
  decode also constructs your Swift values. Compare like with like.
- **Laziness shows up as a gap** between "parse" and "parse + full walk." If your workload
  reads a few fields, the relevant row is the lazy one.
- **The `@JSONCodable` gap** over generic Codable is the cost of the container protocols
  (existentials, per-field `String` keys, dynamic dispatch); the macro fast path bypasses them.
- **Number-heavy payloads** stress number materialization more than structure; `canada.json`
  is the stress test.
- **Untyped materialization edges ahead.** Building a full `JSONValue` tree in one pass now
  matches or slightly beats `JSONSerialization` across the corpus; even so, ADJSON's advantage
  is *not* materializing — the lazy tape and typed decode are where it pulls ahead.
- **Schema validation walks every node** (type and constraint checks), so it is heavier than a
  bare parse; compile the schema once and reuse it across documents.

See <doc:Architecture> for *why* these paths perform as they do.
