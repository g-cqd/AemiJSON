# Benchmarking

How ADJSON is measured, how to reproduce the numbers, and how to read them.

## Running the benchmarks

The benchmark harness is an executable target. The standard corpus is third-party and fetched
on demand (not redistributed):

```sh
scripts/fetch-fixtures.sh                 # JSONTestSuite, JSONPath CTS, simdjson corpus
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

- **Typed decode** `Data → [User]`: Foundation `JSONDecoder` vs ADJSON `JSONDecoder` (generic
  Codable) vs ADJSON `@JSONCodable` vs a hand-rolled "mini" targeted decoder (the practical
  ceiling).
- **Untyped parse** `Data → tree`: Foundation `JSONSerialization` vs ADJSON tape parse, plus
  "parse + read two fields" (lazy) and "parse + full walk" (materialize everything).
- **Typed encode** `[User] → Data` across the same contenders.
- **Number-heavy** `[Double]` decode — the hard case for any parser.
- **Raw structural scan** (SWAR and SIMD16) — the ceiling for a tape-backed untyped value.
- **Concurrent decode** — serial vs `ADJSON.decodeArrayConcurrently` on
  a pre-parsed document.
- **Standard corpus** — `twitter.json`, `citm_catalog.json`, `canada.json`.

The "mini" and "scan" rows exist to show the headroom between ADJSON and a bespoke,
type-specific implementation — i.e. how much the general-purpose API costs.

## Reference results

Apple M2 Pro, release build, strict mode. Your numbers will vary with hardware, OS, and
payload; treat these as ratios, not absolutes.

| Workload | ADJSON vs Foundation |
|---|---|
| Untyped parse — `twitter.json` | **5.7×** `JSONSerialization` |
| Untyped parse — `citm_catalog.json` | **4.0×** |
| Untyped parse — `canada.json` (number-heavy) | **8.0×** |
| Codable decode (`Data` → struct) | **~2.8×** `JSONDecoder` |
| Codable decode (`@JSONCodable` fast path) | **~4.2×** `JSONDecoder` |
| Codable encode (`@JSONCodable` fast path) | **~3.4×** `JSONEncoder` |

Tape parsing runs at roughly **1 GB/s**; partial/lazy access is faster still, since it skips
subtrees it never reads.

## Interpreting the numbers

- **Parse vs decode are different questions.** Untyped parse builds only the tape; Codable
  decode also constructs your Swift values. Compare like with like.
- **Laziness shows up as a gap** between "parse" and "parse + full walk." If your workload
  reads a few fields, the relevant row is the lazy one.
- **The `@JSONCodable` gap** over generic Codable is the cost of the container protocols
  (existentials, per-field `String` keys, dynamic dispatch). The remaining gap to the
  hand-rolled "mini" ceiling is dominated by per-field key lookup.
- **Number-heavy payloads** stress number materialization more than structure; `canada.json`
  is the stress test.

See <doc:Architecture> for *why* these paths perform as they do.
