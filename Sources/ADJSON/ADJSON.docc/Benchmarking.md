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

Apple M2 Pro (macOS 27), release build, strict mode. Median of 60 iterations. Your numbers will
vary with hardware, OS, and payload; treat these as ratios, not absolutes.

**Against Foundation** (synthetic 2000-user payload ≈ 500 KB; corpus files as noted):

| Workload | ADJSON | Foundation | Ratio |
|---|---|---|---|
| Tape parse — `twitter.json` | 1019 MB/s | 172 MB/s | **5.9×** |
| Tape parse — `citm_catalog.json` | 1246 MB/s | 318 MB/s | **3.9×** |
| Tape parse — `canada.json` | 847 MB/s | 125 MB/s | **6.8×** |
| Codable decode — generic | 78 MB/s | 41 MB/s | **1.9×** |
| Codable decode — `@JSONCodable` | 173 MB/s | 41 MB/s | **4.2×** |
| Codable encode — generic | 86 MB/s | 47 MB/s | **1.8×** |
| Codable encode — `@JSONCodable` | 377 MB/s | 47 MB/s | **8.0×** |
| `[Double]` decode | 166 MB/s | 76 MB/s | **2.2×** |
| `JSONValue` materialize — `twitter.json` | 231 MB/s | 172 MB/s | **1.3×** |

**ADJSON-only** (features Foundation has no equivalent for):

| Feature | Throughput |
|---|---|
| JSONPath wildcard — `$[*].profile.bio` | 2289 MB/s |
| JSONPath filter — `$[?(@.followers > N)]` | 970 MB/s |
| JSON Schema validate (pre-parsed, full structural) | 16 MB/s |
| JSON Patch apply (3 ops over a 2000-element tree) | 46 µs |
| Concurrent decode | 223 MB/s (**2.4×** serial) |

Tape parsing runs at roughly **1 GB/s**; partial/lazy access is faster still, since it skips
subtrees it never reads. Full `JSONValue` materialization lands on par with `JSONSerialization`
(it builds a comparable Swift tree), so the win there is small — ADJSON's leverage is the lazy
tape and typed decode.

## Interpreting the numbers

- **Parse vs decode are different questions.** Untyped parse builds only the tape; Codable
  decode also constructs your Swift values. Compare like with like.
- **Laziness shows up as a gap** between "parse" and "parse + full walk." If your workload
  reads a few fields, the relevant row is the lazy one.
- **The `@JSONCodable` gap** over generic Codable is the cost of the container protocols
  (existentials, per-field `String` keys, dynamic dispatch); the macro fast path bypasses them.
- **Number-heavy payloads** stress number materialization more than structure; `canada.json`
  is the stress test.
- **Untyped materialization is roughly a wash.** Building a full `JSONValue` tree costs about
  what `JSONSerialization` does; ADJSON's advantage is *not* materializing — the lazy tape and
  typed decode are where it pulls ahead.
- **Schema validation walks every node** (type and constraint checks), so it is heavier than a
  bare parse; compile the schema once and reuse it across documents.

See <doc:Architecture> for *why* these paths perform as they do.
