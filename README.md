# ADJSON

**Fast, safe, standards-first JSON for Swift 6.** A drop-in alternative to Foundation's
`JSONDecoder` / `JSONEncoder` / `JSONSerialization` — with JSON Schema, JSONPath, JSON
Pointer, and JSON Patch in the box. Built on a single-pass **tape** with lazy, on-demand
materialization, so reading two fields out of a megabyte never decodes the rest.

```swift
import ADJSON

// Parse once. Read only what you touch — nil-safe, even mid-chain.
let doc  = try ADJSON.parse(data)
let name = doc.root.user.name.string          // String?

// Or map straight to your types — like Foundation, only faster.
let users = try ADJSON.JSONDecoder().decode([User].self, from: data)
```

That's the whole learning curve for the common case. Everything else is opt-in.

## Why ADJSON

- **Quick** — ~1 GB/s tape parsing; lazy access skips what you don't read. ([Performance](#performance))
- **Safe** — value-typed, `Sendable`, Swift 6 strict concurrency; parses off the main actor.
- **Correct** — strict RFC 8259 by default; passes the full nst/JSONTestSuite (318/318).
- **Complete** — Schema (validate, infer, or generate from a type with `@Schemable`), JSONPath,
  Pointer, Patch, and Merge Patch — all in one package.
- **Familiar** — `ADJSON.JSONDecoder` / `ADJSON.JSONEncoder` mirror Foundation's API.
- **Lean** — the engine ships as a separate **`ADJSONCore`** product with *no* Foundation and *no*
  swift-syntax, for dependency-strict consumers. ([Install](#install))

## Install

```swift
// Package.swift
.package(url: "https://github.com/g-cqd/ADJSON.git", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: ["ADJSON"])
```

Reference the namespaced types as `ADJSON.JSONDecoder` etc. where Foundation is also imported.

### Foundation-free core

Want only the engine — tape parsing, lazy navigation, `JSONValue`, and JSONPath/Pointer/Patch —
with **no Foundation and no swift-syntax** in your dependency graph (just `OrderedCollections`,
itself Foundation-free with no transitive deps)? Depend on the `ADJSONCore` product instead:

```swift
.target(name: "MyEngine", dependencies: [.product(name: "ADJSONCore", package: "ADJSON")])
```

`import ADJSON` re-exports `ADJSONCore`, so the full library is a strict superset: the `Data`
conveniences, Codable, Schema, and the macros live only in the umbrella module.

**Requirements:** Swift 6.3+ toolchain (developed and tested on 6.4); macOS 15+ / iOS 18+ /
tvOS 18+ / watchOS 11+ / visionOS 2+ (the floor is set by `Synchronization.Mutex`).

## A quick tour

```swift
import ADJSON

// 1. Lazy navigation — nothing is materialized until you read it.
let doc   = try ADJSON.parse(data)
let name  = doc.root.user.name.string           // String?
let first = doc.root["items"][index: 0].int      // Int?

// 2. Codable, drop-in. Add @JSONCodable for a faster path the coders use automatically.
@JSONCodable
struct User: Codable { var id: Int; var name: String; var tags: [String] }
let users = try ADJSON.JSONDecoder().decode([User].self, from: data)
let bytes = try ADJSON.JSONEncoder().encode(users)

// 3. Off the main actor, in parallel across cores.
let rows = try await ADJSON.decodeArrayConcurrently(Row.self, from: data)

// 4. Query — JSON Pointer (RFC 6901) and JSONPath (RFC 9535).
let title  = doc.root[pointer: "/store/book/0/title"].string
let titles = try doc.root.query("$.store.book[?(@.price < 10)].title")

// 5. Validate — JSON Schema (Draft 2020-12 subset)…
let schema = try JSONSchema(parsing: schemaText)
let result = schema.validate(data)               // .isValid / .errors

// …or generate one from a type at compile time with @Schemable (great for LLM tool / MCP schemas).
@Schemable(dialect: .draft7)
struct SearchInput: Decodable {
    /// Search terms.                             // doc comment → "description"
    var query: String
    @SchemaNumber(1...500) var limit: Int?        // → "minimum":1,"maximum":500
}
let toolSchema = SearchInput.jsonSchemaText      // draft-07 JSON, ready for tools/list

// 6. Mutate — JSON Patch (RFC 6902) / Merge Patch (RFC 7396).
let patched = try JSONPatch(patchData).apply(to: JSONValue(parsing: targetData))

// 7. Profiles — strict by default; opt into lenient or RFC 7493 I-JSON.
let lenient = try ADJSON.parse(data, options: .lenient)
var decoder = ADJSON.JSONDecoder(); decoder.options = .iJSON   // reject duplicate keys
```

See the [documentation](#documentation) for the full guides.

## Performance

Apple M2 Pro (macOS 27), release build, strict mode; treat these as ratios, not absolutes.
Reproduce with `ADJSON_DEV=1 swift package benchmark` (the [ordo-one/benchmark](https://github.com/ordo-one/benchmark)
suite under `Benchmarks/ADJSONSuite`).

| Workload | ADJSON vs Foundation |
|---|---|
| Untyped tape parse — `twitter.json` | **4.9×** `JSONSerialization` |
| Untyped tape parse — `citm_catalog.json` | **3.8×** |
| Untyped tape parse — `canada.json` (number-heavy) | **6.5×** |
| Codable decode — generic (`Data` → struct) | **1.6×** `JSONDecoder` |
| Codable decode — `@JSONCodable` fast path | **4.5×** `JSONDecoder` |
| Codable encode — `@JSONCodable` fast path | **8.0×** `JSONEncoder` |
| `[Double]` decode — number-heavy | **2.2×** `JSONDecoder` |

Tape parsing runs at roughly **1 GB/s** (0.7–1.1 GB/s across the corpus); lazy access is faster
still since it skips subtrees it never reads. Full untyped materialization into `JSONValue` now
edges past `JSONSerialization` on the corpus, and compiled JSON Schema validation runs at roughly
**123 MB/s**. Query and patch throughput, methodology, and the full table: see the **Benchmarking**
guide in the documentation.

## Standards

Strict by default. The grammar follows **RFC 8259** / **ECMA-404** / **ISO/IEC 21778:2017**
with **RFC 3629** UTF-8 well-formedness (overlongs, surrogates, and code points above U+10FFFF
rejected). Optional **RFC 7493 (I-JSON)** profile rejects duplicate keys. Query and mutation
follow **RFC 6901** (Pointer), **RFC 9535** (JSONPath — rejects 100% of the compliance suite's
invalid selectors and matches 99% of valid-query results; the remainder are I-Regexp `.`
line-separator edge cases), **RFC 6902** (Patch), **RFC 7396** (Merge Patch), and Relative JSON
Pointer. Schema targets **JSON Schema Draft 2020-12** (subset).

> **Numbers:** under the default `.swiftShortest`, a value typed `Double(2)` encodes as `2.0`
> through Codable, while `JSONValue` collapses it to `2` to keep integers round-tripping. Use
> the `.javaScript` profile for `JSON.stringify` parity. Details in the Encoding guide.

## Documentation

Full guides and the API reference ship as a **Swift DocC** catalog:

- **Getting Started**, **Parsing & Navigation**, **Codable Interop**, **Querying & Mutation**,
  **Schema Validation**, **Encoding & Numbers**
- **Architecture & Design Decisions** and **Benchmarking** for the how and why

The latest documentation is published to **<https://g-cqd.github.io/ADJSON/>** (built and
deployed by CI). Build it locally:

```sh
# Xcode: Product ▸ Build Documentation
# CLI (the DocC plugin is dev-only, gated behind ADJSON_DEV so consumers don't resolve it):
ADJSON_DEV=1 swift package generate-documentation --target ADJSON
```

## Testing & benchmarks

Dev tasks run as SwiftPM plugins (no shell scripts). Conformance suites and the benchmark
corpus are third-party and fetched on demand:

```sh
swift package --allow-network-connections all --allow-writing-to-package-directory fetch-fixtures
swift test                                             # full conformance + unit suite
ADJSON_DEV=1 swift package benchmark                   # benchmark suite (ordo-one/benchmark)
swift package lint                                     # formatting gate + shipped-library discipline
swift package --allow-writing-to-package-directory format   # apply formatting
```

Without the fixtures, `swift test` still passes (corpus/conformance cases skip). See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full developer workflow — git hooks, the `ADJSON_DEV`
flag, and build-time lint enforcement.

## Roadmap & open items

Work that is deliberately **not** done yet, with the rationale and the investigation each needs.
Grouped by theme; none is a known correctness bug (the conformance suites stay green) — these are
measured optimizations, native-API adoption decisions, larger refactors, and optional features.

### Performance (each gated on adding a targeted benchmark first)

The benchmark suite (`ordo-one/benchmark`) currently exercises the default parse/decode/encode/query
paths only. Each item below lives on a path the suite does **not** measure, so the discipline is:
add a focused benchmark, capture a baseline, optimize, then re-measure — no optimization lands
without a before/after number.

- [ ] **ECMA-262 number encoding allocates per value.** `JSONOutput.appendECMANumber` builds two
  intermediate `[UInt8]` arrays; move them to `withUnsafeTemporaryAllocation` (digit buffers are
  bounded, ~24 bytes, like `appendMagnitude`). Win is malloc-count (deterministic). Note
  `Double.description` itself still allocates a `String`. Only on the `.javaScript` / `.ecma262`
  profile, so add a JS-stringify encode benchmark first.
- [ ] **Pretty / sorted Codable encode does a 4-stage round-trip** (encode → parse → materialize →
  re-encode) and its number formatting diverges from the compact path. Stream sorted/pretty output
  directly (or at least re-serialize only once) and reconcile the compact-vs-pretty number
  divergence. Add a pretty/sorted encode benchmark.
- [ ] **JSONPath slice selector materializes the whole array.** `JSONPathEvaluator.appendSlice`
  calls `arrayValue` even for a small slice; iterate the slice indices without full materialization.
  Add a JSONPath slice benchmark.
- [ ] **Push-SAX `decodeString` re-scans for escapes** that `scanStringEnd` already detected; thread
  the `hasEscape` flag through to skip the second pass. Add a streaming-reader benchmark.
- [ ] **Escaped-key comparison re-allocates.** `JSONKey.matches(escaped: true)` re-unescapes and
  allocates a `String` per comparison; explore an escape-aware byte compare or a decode-once cache
  for objects with escaped keys. Add an escaped-key decode benchmark.

### Native-API modernization

- [ ] **`UnsafePointer` → `RawSpan` / `Span`** for the parser byte reads and the lazy `JSON`
  accessors (bounds-safe by construction). Strictly benchmark-gated: `Span` carries bounds checks,
  so keep raw pointers on the hot inner loops where it regresses. **Not** for `DecodeContext` —
  Codable's `Decoder` must be `Escapable`, and a `Span` cannot be stored there (keep raw pointers +
  asserts, as documented). Files: `Scanner`, `Bytes`, `JSON`, `KeyCompare`.
- [ ] **`AsyncSequence` streaming.** Wrap `JSONEventStreamReader` as an `AsyncSequence<JSONEvent>`
  that consumes `URLSession.AsyncBytes` / `FileHandle.AsyncBytes` (optionally via
  `swift-async-algorithms`). Fills the async-streaming gap and pairs with the existing push reader.
- [ ] **swift-nio `ByteBuffer` adapter.** `ByteBuffer` → `ByteSource` (zero-copy parse) and a
  writer → `ByteBuffer` sink. Server-focused; ship as a dev-gated target / small `ADJSONNIO` product
  so the core stays dependency-free.
- [ ] **Decide on `UTF8Span` / `InlineArray`** (a decision, not an auto-adopt). Both raise the
  deployment floor to the 2025 SDKs — above the current iOS 18 floor (pinned by
  `Synchronization.Mutex`). Current recommendation: **do not adopt yet**; revisit only if the floor
  rises for another reason.

### Architecture & refactoring

- [ ] **Extract a shared RFC-8259 tokenizer.** The number / string / escape / UTF-8 grammar is
  copy-pasted across three readers (the tape scanner, the pull-SAX `JSONEventReader`, and the
  push-SAX `JSONEventStreamReader`), so any grammar fix must be made in three places. Extract
  resumability-aware tokenization helpers. Biggest maintainability win, but large and carries
  conformance-suite (JSONTestSuite + JSONPath CTS) regression risk — deserves a focused PR.
- [ ] **Derive the depth caps where sensible.** The unified failure-safety policy is documented (see
  the *Depth Safety* DocC article); the individual caps could be made consistent/derived (e.g. a
  stack-size-aware decode default) rather than fixed constants.

### Optional features (to consider)

- [ ] **JSON5 / lenient parity in the event readers** — the tape parser supports JSON5; the SAX
  readers do not yet.
- [ ] **`KeyEncodingStrategy.custom` / `KeyDecodingStrategy.custom`** — the streaming encoder/decoder
  do not track the full coding path required for a custom key transform.
- [ ] **Optional HTML-safe output escaping** — escape `<`, `>`, `&`, and U+2028 / U+2029 for
  embedding JSON in HTML/JS contexts.

### Tooling / CI (low priority)

- [ ] **Make the benchmark regression gate real.** Commit a runner-generated `.benchmarkBaselines/main`,
  then promote the advisory check toward a hard gate if the hosted runner proves stable enough.
- [ ] **Coverage floor** in CI; promote the advisory Linux / fuzz jobs to required once a stable
  toolchain ships; consider a comprehensive (non-regex) force-unwrap lint.

## License

MIT — see [LICENSE](LICENSE). Fetched fixtures (JSONTestSuite, JSONPath CTS, simdjson /
nativejson-benchmark corpus) remain under their respective upstream licenses and are not
redistributed in this repository.
