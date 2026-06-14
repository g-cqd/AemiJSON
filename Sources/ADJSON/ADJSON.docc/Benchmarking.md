# Benchmarking

How ADJSON is measured, how to reproduce the numbers, and how to read them.

## Running the benchmarks

The benchmark harness is an executable target. The standard corpus is third-party and fetched
on demand (not redistributed):

```sh
swift package --allow-network-connections all --allow-writing-to-package-directory fetch-fixtures
swift run -c release ADJSONBenchmarks
```

Always benchmark a **release** build. Without the corpus the in-memory benchmarks still run;
the corpus section prints a skip line per missing file.

## Methodology

The harness (`Sources/ADJSONBenchmarks`) is deliberately simple and honest:

- **Clock.** `ContinuousClock`; each case reports the **median** of 60 iterations after 12
  warmup iterations (50/10 for the async case). Median resists outliers from scheduling.
- **Throughput.** `MB/s = payloadBytes / median_time`. The min time is also printed for
  reference.
- **No dead-code elimination.** Every result is passed through a `@_optimize(none)` "black
  hole" so the optimizer can't delete the work being measured.
- **Correctness gates first.** Before timing, each path is checked to produce results equal to
  Foundation's (and to round-trip). There is no point benchmarking a parser that skips work.
- **Fair baselines.** Foundation's `JSONDecoder`/`JSONEncoder`/`JSONSerialization` instances
  are created once and reused across iterations.
- **Regression gate.** On the standard corpus, the run fails loudly if ADJSON's tape parse is
  slower than `JSONSerialization` on any file.

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
| Tape parse — `twitter.json` | 959 MB/s | 176 MB/s | **5.4×** |
| Tape parse — `citm_catalog.json` | 1274 MB/s | 318 MB/s | **4.0×** |
| Tape parse — `canada.json` | 842 MB/s | 128 MB/s | **6.6×** |
| Codable decode — generic | 79 MB/s | 43 MB/s | **1.8×** |
| Codable decode — `@JSONCodable` | 183 MB/s | 43 MB/s | **4.2×** |
| Codable encode — generic | 90 MB/s | 47 MB/s | **1.9×** |
| Codable encode — `@JSONCodable` | 387 MB/s | 47 MB/s | **8.2×** |
| `[Double]` decode | 176 MB/s | 79 MB/s | **2.2×** |
| `JSONValue` materialize — `twitter.json` | 216 MB/s | 176 MB/s | **1.2×** |
| `JSONValue` materialize — `citm_catalog.json` | 326 MB/s | 318 MB/s | **1.0×** |
| `JSONValue` materialize — `canada.json` | 134 MB/s | 128 MB/s | **1.05×** |

**ADJSON-only** (features Foundation has no equivalent for):

| Feature | Throughput |
|---|---|
| JSONPath wildcard — `$[*].profile.bio` | 2125 MB/s |
| JSONPath filter — `$[?(@.followers > N)]` | 927 MB/s |
| JSON Schema validate (pre-parsed, full structural) | 105 MB/s |
| JSON Patch apply (3 ops over a 2000-element tree) | 46 µs |
| Concurrent decode | 227 MB/s (**2.5×** serial) |

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
