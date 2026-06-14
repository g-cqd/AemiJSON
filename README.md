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

## Install

```swift
// Package.swift
.package(url: "https://github.com/g-cqd/ADJSON.git", from: "0.1.0")
```

```swift
.target(name: "MyApp", dependencies: ["ADJSON"])
```

Reference the namespaced types as `ADJSON.JSONDecoder` etc. where Foundation is also imported.

**Requirements:** Swift 6.3+ toolchain (developed and tested on 6.4); macOS 15+ / iOS 26 /
tvOS 26 / watchOS 26 / visionOS 26.

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

Apple M2 Pro (macOS 27), release build, strict mode. Median of 60 iterations; treat these as
ratios, not absolutes. Reproduce with `swift run -c release ADJSONBenchmarks`.

| Workload | ADJSON vs Foundation |
|---|---|
| Untyped tape parse — `twitter.json` | **5.9×** `JSONSerialization` |
| Untyped tape parse — `citm_catalog.json` | **3.9×** |
| Untyped tape parse — `canada.json` (number-heavy) | **6.8×** |
| Codable decode — generic (`Data` → struct) | **1.9×** `JSONDecoder` |
| Codable decode — `@JSONCodable` fast path | **4.4×** `JSONDecoder` |
| Codable encode — `@JSONCodable` fast path | **8.0×** `JSONEncoder` |
| `[Double]` decode — number-heavy | **2.2×** `JSONDecoder` |

Tape parsing runs at roughly **1 GB/s** (0.85–1.25 GB/s across the corpus); lazy access is faster
still since it skips subtrees it never reads. Full untyped materialization into `JSONValue` now
edges past `JSONSerialization` on the corpus, and compiled JSON Schema validation runs at roughly
**100 MB/s**. Query and patch throughput, methodology, and the full table: see the **Benchmarking**
guide in the documentation.

## Standards

Strict by default. The grammar follows **RFC 8259** / **ECMA-404** / **ISO/IEC 21778:2017**
with **RFC 3629** UTF-8 well-formedness (overlongs, surrogates, and code points above U+10FFFF
rejected). Optional **RFC 7493 (I-JSON)** profile rejects duplicate keys. Query and mutation
follow **RFC 6901** (Pointer), **RFC 9535** (JSONPath, ~88% of the compliance suite), **RFC
6902** (Patch), **RFC 7396** (Merge Patch), and Relative JSON Pointer. Schema targets **JSON
Schema Draft 2020-12** (subset).

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
swift run -c release ADJSONBenchmarks                  # benchmarks (release)
swift package lint                                     # formatting gate + shipped-library discipline
swift package --allow-writing-to-package-directory format   # apply formatting
```

Without the fixtures, `swift test` still passes (corpus/conformance cases skip). See
[CONTRIBUTING.md](CONTRIBUTING.md) for the full developer workflow — git hooks, the `ADJSON_DEV`
flag, and build-time lint enforcement.

## License

MIT — see [LICENSE](LICENSE). Fetched fixtures (JSONTestSuite, JSONPath CTS, simdjson /
nativejson-benchmark corpus) remain under their respective upstream licenses and are not
redistributed in this repository.
