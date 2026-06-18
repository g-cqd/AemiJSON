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

The headline **ADJSON-vs-Foundation speedup table** is rendered by the `bench-compare` command plugin,
which reuses the already-built suite binary (no rebuild) and pairs each Foundation baseline with the
ADJSON variants in its workload:

```sh
ADJSON_DEV=1 swift build -c release --product ADJSONSuite   # build the suite once
swift package bench-compare                                  # render the speedup table (Markdown)
swift package bench-compare --filter "decode/.*"             # restrict the workloads
```

## Methodology

The suite is statistically rigorous and honest:

- **Percentiles, not an average.** `Benchmark` auto-tunes the iteration count and reports the full
  wall-clock distribution (p50 / p90 / p99 / p100), so tail latency and jitter are visible — not
  hidden behind a single mean.
- **Metrics.** Wall-clock time, throughput (operations/second), total CPU time, total `malloc`
  count, and **peak resident memory** per iteration — so a CPU or memory regression (e.g. an untyped
  object-tree balloon) surfaces, not just wall-clock. Allocations are often the real cost in a JSON
  pipeline.
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
- **Typed encode** `[User] → Data`: Foundation `JSONEncoder` vs ADJSON generic vs `@JSONCodable`,
  plus **compact / pretty / sorted** modes, and untyped `JSONValue → bytes` vs `JSONSerialization`.
- **Number-heavy** `[Double]` decode — the hard case for any parser.
- **Exact `Decimal`** (a win via the `UInt128` significand fast path) and **ISO-8601 `Date`** (≈parity,
  the Sendable formatter) decode — ADJSON vs Foundation on the strategy paths.
- **Query** — JSONPath (RFC 9535) filter and wildcard over a pre-parsed document.
- **Validate** — JSON Schema (Draft 2020-12 subset) compiled once (here from `@Schemable`), run
  over a pre-parsed document, plus parse + validate end to end.
- **Mutate** — JSON Patch (RFC 6902) applied to a materialized `JSONValue`.
- **Concurrent decode** — serial vs `ADJSON.decodeArrayConcurrently` on a pre-parsed document.
- **Standard corpus** — real-world files run end to end (parse, untyped materialize, re-encode,
  JSONPath query, JSON Patch), each beside its Foundation baseline where one exists:
  `twitter.json`, `citm_catalog.json`, `canada.json`, plus the broader simdjson-data set
  (`github_events`, `gsoc-2018`, `marine_ik`, `twitterescaped`, `numbers`) for a spread of shapes —
  GitHub API, string/unicode-heavy, number-heavy, escaped strings, and a pure number array.

Every comparison pits the real public API against Foundation; where Foundation has no equivalent —
JSONPath, JSON Schema, JSON Patch/Merge Patch, SAX streaming, and `decodeArrayConcurrently` — the
row reports ADJSON's standalone throughput, not a ratio.

## Reference results

Apple M3 (macOS 26.5), Swift 6.3.2, release build, strict mode. Each cell is the **p50** of an
auto-tuned run; run-to-run spread was within ~±8% except concurrent decode (~±12%, thermal). Your
numbers will vary with hardware, OS, and payload; treat these as ratios, not absolutes.

**Untyped parse — standard corpus** (throughput = file bytes ÷ wall clock; both columns measured
the same way):

| File | ADJSON tape | Foundation `JSONSerialization` | Ratio |
|---|---|---|---|
| `twitter.json` (0.6 MB) | ≈1.5 GB/s | ≈250 MB/s | **6.1×** |
| `citm_catalog.json` (1.6 MB) | ≈1.6 GB/s | ≈400 MB/s | **4.1×** |
| `canada.json` (2.1 MB, number-heavy) | ≈0.95 GB/s | ≈145 MB/s | **6.6×** |

**Typed Codable + numbers** (synthetic 2 000-user payload; ratio of throughput):

| Workload | vs Foundation |
|---|---|
| Codable decode — generic (`Data` → struct) | **1.8×** `JSONDecoder` |
| Codable decode — `@JSONCodable` fast path | **5.2×** `JSONDecoder` |
| Codable encode — `@JSONCodable` fast path | **7.6×** `JSONEncoder` |
| `[Double]` decode — number-heavy | **2.7×** `JSONDecoder` |
| `JSONValue` materialize (corpus) | **1.1–1.3×** `JSONSerialization` |
| Codable encode — pretty (declaration order) | **≈1.2×** `JSONEncoder` (single streaming pass) |

**Exact `Decimal` decode** (base-10, read from the raw source lexeme via a `UInt128` significand fast
path — preserving values `Double` would round):

| Workload | vs Foundation |
|---|---|
| `Decimal` decode — short values | **≈2.3×** `JSONDecoder` |
| `Decimal` decode — long (31-digit) values | **≈1.2×** `JSONDecoder` |

**Peak resident memory** (parse benchmark, 2 000-user payload; per-iteration peak RSS): ADJSON's flat
tape holds ≈**36 MB** whether it parses the tape, reads two fields lazily, walks every node, or
materializes a full `JSONValue` tree. Foundation's `JSONSerialization` object graph
(`NSDictionary`/`NSArray`) peaks at ≈**110–340 MB** (p25–p99) on the same input — roughly **5× more at
the median and ~9× at the tail**. The flat tape is the structural reason untyped parsing wins on both
time and memory.

**Where ADJSON matches rather than beats Foundation** — included so the picture isn't cherry-picked:

| Workload | vs Foundation |
|---|---|
| Untyped re-serialize — `JSONValue → bytes` | ≈0.85× `JSONSerialization` |
| Sorted-key Codable encode | ≈0.95× (sorted output re-serializes through the tape — the streaming writer can't reorder members) |
| ISO-8601 `Date` decode | ≈0.94× `JSONDecoder` (the Sendable, value-type `Date.ISO8601FormatStyle`, not Foundation's non-`Sendable` cached formatter — the 6% is the price of off-actor safety) |

These paths are correct and Foundation-faithful; they are simply not where the tape model pays off.

**Capabilities with no Foundation equivalent** (absolute, not a ratio):

| Feature | Measured |
|---|---|
| JSONPath wildcard — `$[*].profile.bio` | ≈4 300 queries/s |
| JSONPath filter — `$[?(@.followers > N)]` | ≈2 300 queries/s |
| JSON Schema validate (full structural, pre-parsed) | ≈144 validations/s |
| JSON Patch apply (3 ops, 2 000-element tree) | ≈53 µs |
| Concurrent array decode | ≈2.9× a serial decode (8-core M3) |

Tape parsing runs at roughly **1–1.5 GB/s** across the corpus; partial/lazy access is faster still,
since it skips subtrees it never reads. Full `JSONValue` materialization edges just past
`JSONSerialization` — a comparable Swift tree in a single pass — but ADJSON's real leverage is the
lazy tape and the typed/macro decode paths.

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
